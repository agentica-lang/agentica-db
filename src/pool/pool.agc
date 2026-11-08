## A generic pool of resources (the idea of Elixir's NimblePool): a fixed number of long-lived resources of any type
## `W`, made and ended by the functions of a `Spec`, lent to the body of `Pool.with` one caller at a time.
##
## One owner task makes and ends the resources and never runs the body of a caller. For each job it starts a lease
## task, which waits in line for a free resource (first come, first served), runs the body in a task of its own,
## and hands the resource back with the outcome of the body. A body that crashes or runs past `lease_ms`, and a
## caller that crashes or is cancelled, do not stop the lease task from giving the resource back: it is returned to
## the line or ended and replaced, never lost.
##
## Start the pool in a task that lives as long as the pool (`main`): the owner task ends with the task that started
## it. The body of a caller is not cancelled when the caller is; `lease_ms` bounds it.

# Sizes of the queues and the waits that are not part of a `Spec`.
JOBS_SIZE = 1_024
CONTROL_SIZE = 16_384
START_MS = 60_000
HOOK_MS = 5_000
SEND_MS = 5_000
POLL_MS = 500
CHECKOUT_SLACK_MS = 500
MAX_RESOURCES = 1_048_576
REPLY_GRACE_MS = 5_000
CLOSE_GRACE_MS = 2_000
CANCEL_GRACE_MS = 20
INIT_RETRY_MS = 1_000
MAX_WAIT_MS = 1_000

# The keys of the counters that the owner, the lease tasks and the callers share.
LIVE = "live"
WAITING = "waiting"
NEXT_ID = "next_id"
NEXT_JOB = "next_job"
CLOSED = "closed"
# A key of the counters per failed `init`: the text after the prefix is its error. Only the last one is kept.
INIT_ERROR = "init failed: "
# The key a body and its caller race for in `answer` and `await_start`: whoever puts it first decides.
DECIDED = "decided"

CLOSED_ERROR = "pool error: closed"
OWNER_ENDED_ERROR = "pool error: owner task ended"
QUEUE_FULL_ERROR = "pool error: queue full"
CHECKOUT_TIMEOUT = "pool error: checkout timed out"
LEASE_TIMEOUT = "pool error: lease timed out"

## How a body ended, as `checkin` sees it.
export enum Outcome
  Done
  Crashed
  TimedOut
end

## What a pool is made of. `init` makes a resource from `config` in the owner task, so the owner owns it (a native
## handle, a socket); `checkin` gets it back after each body (`error` ends it: it is terminated and replaced);
## `ping` checks an idle resource at each health tick (`error` ends it); `terminate` ends it. `init` and `terminate`
## run in the owner task, so they must not crash or block for long (a crash ends the pool).
##
## After a `TimedOut` body the resource is always terminated and replaced, whatever `checkin` returns: the cancelled
## body may still run for a moment, so nobody else may get the resource. After `Crashed` the body is dead, and
## `checkin` decides.
##
## `size` resources are kept. In a spike the pool makes up to `max_overflow` more (so `size + max_overflow` is the most
## that exist). When a spike is over, an overflow resource that nobody needs stays for `overflow_idle_ms` and is ended
## if it is still idle then (0 ends it as soon as it is given back), so the pool shrinks back to `size` and a steady
## load a little over `size` does not make and end a resource for every request. A `lazy` pool makes its resources when
## callers need them. `max_age_ms` and `idle_ms` need `health_ms` (the health tick is what applies them) and 0 turns
## each off; `idle_ms` needs a lazy pool, since an eager pool would make a new resource at once. `max_waiting` is how
## many callers may wait in line for a resource at once (0 or more); one more is refused with `pool error: queue full
## (max_waiting N)`, and 0 lets nobody wait: a caller that finds every resource busy is refused.
export struct Spec[A, W]
  config: A
  init: Fn[A, Result[W]]
  checkin: Fn[W, Outcome, Result[Void]]
  terminate: Fn[W, Void]
  ping: Fn[W, Result[Void]]
  size: Int = 10
  max_overflow: Int = 0
  overflow_idle_ms: Int = 1_000
  checkout_ms: Int = 5_000
  lease_ms: Int = 30_000
  max_age_ms: Int = 0
  idle_ms: Int = 0
  max_waiting: Int = 1_000
  lazy: Bool = false
  health_ms: Int = 5_000
end

## A running pool. Share it with every task that needs a resource.
export struct Pool[A, W]
  spec: Spec[A, W]
  jobs: Channel[Job[W]]
  control: Channel[Msg[W]]
  owner: Task[Void]
  counts: ATS[String, Int]
end

# A caller's work. It runs the body on a granted resource and gives the caller's result; a denial it gives the caller
# as an error.
type Job[W] = Fn[Offer[W], Result[Void]]

# What a lease task tells a caller's job: a resource to run the body on, or the error that the caller gets instead.
enum Offer[W]
  Grant(W)
  Deny(String)
end

# What a caller hears from its job: the body started, then its result (or an error without a start).
enum Event[R]
  Started
  Finished(Result[R])
end

# What the callers and the lease tasks tell the owner. They go through `control`, which jobs cannot fill: a job
# that waits for room in `jobs` never holds back the news that frees a resource.
enum Msg[W]
  Wake
  Back(Release[W])
  Drop(Slot[W])
  GaveUp(Int)
  Stop(Closing)
end

struct Slot[W]
  id: Int
  worker: W
  born_ms: Int
  idle_since_ms: Int
end

struct Release[W]
  job_id: Int
  slot: Slot[W]
  keep: Bool
end

struct Closing
  drain_ms: Int
  done: Channel[Bool]
end

# The channels that the owner task owns: they close when it ends, however it ends, so no caller waits for a dead pool.
struct Chans[W]
  jobs: Channel[Job[W]]
  control: Channel[Msg[W]]
  idle: Channel[Slot[W]]
  ready: Channel[Result[Void]]
end

# What every task of the pool shares.
struct Core[A, W]
  spec: Spec[A, W]
  counts: ATS[String, Int]
  jobs: Channel[Job[W]]
  control: Channel[Msg[W]]
  idle: Channel[Slot[W]]
  ready: Channel[Result[Void]]
end

struct Lease[A, W]
  core: Core[A, W]
  job_id: Int
  job: Job[W]
end

# The owner's state: the resources it holds, by slot id, and the jobs and lease tasks that have not ended. `failure`
# is why the last `init` failed, and `retry_at_ms` is when to try again (0: no failure waits). `trim_at_ms` is when to
# end the overflow resources that are idle and not needed (0: none waits).
struct Owned[W]
  workers: Map[Int, W]
  jobs: Map[Int, Job[W]]
  leases: Map[Int, Task[Void]]
  failure: String
  retry_at_ms: Int
  trim_at_ms: Int
  health: Optional[Task[Void]]
  next_tick_ms: Int
  closing: Optional[Closing]
  deadline_ms: Int
  done: Bool
end

## Starts a pool and waits for it to make its resources (none when `lazy`). An `init` that fails stops the start
## with its error, after ending the resources already made.
export def start[A, W](spec: Spec[A, W]) -> Result[Pool[A, W]]
  try check_spec(spec)
  jobs: Channel[Job[W]] = Channel.new(JOBS_SIZE)
  control: Channel[Msg[W]] = Channel.new(CONTROL_SIZE)
  idle: Channel[Slot[W]] = Channel.new(spec.size + spec.max_overflow)
  ready: Channel[Result[Void]] = Channel.new(1)
  chans = Chans(jobs: jobs, control: control, idle: idle, ready: ready)
  counts: ATS[String, Int] = ATS.new()
  owner = spawn_owner(chans) do |owned| own(spec, counts, owned) end
  started = chans.ready.recv(START_MS)
  if not started.ok?
    return error(abandon_start(chans, counts, owner))
  end

  try try started
  return ok(Pool(spec: spec, jobs: chans.jobs, control: chans.control, owner: owner, counts: counts))
end

## Runs the body with a resource of the pool and gives its result. The body runs in a task of the pool, so a crash
## in it is an `error` here, and the resource is checked in with the outcome. Other errors: `pool error: checkout
## timed out after N ms` (the caller waited that long for a resource, with the last error of `init` if the pool could
## not make one, even when the owner is busy in a slow `init`), `pool error: lease timed out after N ms` (the body
## ran longer than `lease_ms`), `pool error: queue full (max_waiting N)` (`max_waiting` callers wait already),
## `pool error: closed` and `pool error: owner task ended`. A caller that got an error never has its body run later.
export def with[A, W, R](pool: Pool[A, W], body: Fn[W, Result[R]]) -> Result[R]
  if pool.counts.has_key?(CLOSED)
    return error(CLOSED_ERROR)
  end

  events: Channel[Event[R]] = Channel.new(2)
  claim: ATS[String, Int] = ATS.new()
  sent = enqueue(pool) do |offer| answer(events, claim, body, offer) end
  if not sent.ok?
    return error(refusal(pool))
  end

  return await_start(pool, events, claim)
end

## Refuses new jobs, lets the running ones and the ones in line finish for up to `drain_ms`, fails the rest with
## `pool error: closed`, ends every resource and stops the pool. Closing twice does nothing. The owner task serves the
## close between two steps, so while an `init` or a `terminate` blocks it the close cannot run `terminate`: after
## `drain_ms` and two more seconds the owner is cancelled, and the VM closes the handles it owns.
export def close[A, W](pool: Pool[A, W], drain_ms: Int) -> Void
  if not pool.counts.put_new(CLOSED, 1)
    return
  end

  done: Channel[Bool] = Channel.new(1)
  closing = Closing(drain_ms: [drain_ms, 0].max.unwrap!, done: done)
  if send_stop(pool, closing)
    _ = done.recv(closing.drain_ms + CLOSE_GRACE_MS + CANCEL_GRACE_MS)
  end

  Task.cancel(pool.owner)
end

## True for the error of a checkout or a lease that ran out of time.
export def timeout?(message: String) -> Bool
  return message.start_with?(CHECKOUT_TIMEOUT) or message.start_with?(LEASE_TIMEOUT)
end

def spawn_owner[W](chans: Chans[W], body: Fn[Chans[W], Void]) -> Task[Void]
  return Task.spawn_owning(body, chans)
end

# The job reaches the owner through `jobs`, and a wake-up through `control` makes it look there at once. A full
# `jobs` makes the caller wait up to `checkout_ms`, as for a resource.
def enqueue[A, W](pool: Pool[A, W], job: Job[W]) -> Result[Void]
  try pool.jobs.send(job, pool.spec.checkout_ms)
  _ = pool.control.send(Msg.Wake, 0)
  return ok()
end

# Runs inside the job. The body and the caller's checkout timeout settle who goes first with `claim`, in one atomic
# step (`put_new`): a body that gets it has started and its caller waits for the result; a caller that gets it gave up,
# and the body does not run. The body does not run either when `Started` cannot be sent, as the caller closed `events`.
# The runner always ends with `ok`, so an error of the runner is the VM's: a crash or a cancel.
def answer[W, R](
  events: Channel[Event[R]],
  claim: ATS[String, Int],
  body: Fn[W, Result[R]],
  offer: Offer[W],
) -> Result[Void]
  case offer
    Offer.Grant(worker) ->
      if claim.put_new(DECIDED, 1) and events.send(Event.Started, 0).ok?
        _ = events.send(Event.Finished(body.call(worker)), SEND_MS)
      end

      return ok()
    Offer.Deny(message) ->
      _ = events.send(Event.Finished(error(message)), 0)
      return ok()
  end
end

# Why a job could not be queued.
def refusal[A, W](pool: Pool[A, W]) -> String
  if pool.jobs.closed?
    return closed_reason(pool)
  end

  return "#{CHECKOUT_TIMEOUT} after #{pool.spec.checkout_ms} ms"
end

def closed_reason[A, W](pool: Pool[A, W]) -> String
  if pool.counts.has_key?(CLOSED)
    return CLOSED_ERROR
  end

  return OWNER_ENDED_ERROR
end

# Waits for the body to start for as long as `checkout_ms` (and a little more, so that the lease task's own error,
# which says why, comes first when the owner is alive), in slices, so that the end of the owner (a crash, or a close)
# is noticed. A caller that gives up claims the start first, so its body never runs.
def await_start[A, W, R](pool: Pool[A, W], events: Channel[Event[R]], claim: ATS[String, Int]) -> Result[R]
  deadline = Time.monotonic_ms() + pool.spec.checkout_ms + CHECKOUT_SLACK_MS
  while Time.monotonic_ms() < deadline
    case events.recv((deadline - Time.monotonic_ms()).clamp(1, POLL_MS))
      ok(event) ->
        case event
          Event.Started -> return await_finish(pool, events)
          Event.Finished(result) -> return result
        end

      error(_) ->
        if pool.jobs.closed?
          return last_event(pool, events)
        end
    end
  end

  # The deadline came. A body that claimed the start in the last slice runs, so its result is awaited and the caller
  # does not hear "timed out" for work that happened; else the caller claims it, and the body never runs.
  if not claim.put_new(DECIDED, 1)
    return await_finish(pool, events)
  end

  events.close
  return error("#{CHECKOUT_TIMEOUT} after #{pool.spec.checkout_ms} ms#{init_error(pool.counts)}")
end

# Waits for the result of the body that started: `lease_ms`, and a moment for the lease task to answer.
def await_finish[A, W, R](pool: Pool[A, W], events: Channel[Event[R]]) -> Result[R]
  wait_ms = pool.spec.lease_ms + REPLY_GRACE_MS
  deadline = Time.monotonic_ms() + wait_ms
  while Time.monotonic_ms() < deadline
    case events.recv((deadline - Time.monotonic_ms()).clamp(1, POLL_MS))
      ok(event) ->
        case event
          Event.Started -> next
          Event.Finished(result) -> return result
        end

      error(_) ->
        if pool.jobs.closed?
          return last_event(pool, events)
        end
    end
  end

  events.close
  return error("#{LEASE_TIMEOUT} after #{wait_ms} ms")
end

# The owner ended: a close denies the jobs just after it closes `jobs`, so give that a moment, unless `control` is
# closed too: the owner closes it last, after it has denied every job (or it ended in a crash and denies none), so
# nothing more can come.
def last_event[A, W, R](pool: Pool[A, W], events: Channel[Event[R]]) -> Result[R]
  grace_ms = CLOSE_GRACE_MS
  if pool.control.closed?
    grace_ms = 0
  end

  case events.recv(grace_ms)
    ok(event) ->
      case event
        Event.Started -> return last_event(pool, events)
        Event.Finished(result) -> return result
      end

    error(_) ->
      events.close
      return error(closed_reason(pool))
  end
end

# The Stop of `close` is never dropped: it waits for room in `control` until the owner is gone.
def send_stop[A, W](pool: Pool[A, W], closing: Closing) -> Bool
  while not pool.control.closed?
    if pool.control.send(Msg.Stop(closing), SEND_MS).ok?
      return true
    end
  end

  return false
end

# The start did not finish in time: the owner is asked to end the resources it made and stop (it does at its next
# step), and is cancelled if it does not.
def abandon_start[W](chans: Chans[W], counts: ATS[String, Int], owner: Task[Void]) -> String
  if chans.ready.closed?
    return "pool error: owner task ended during the start"
  end

  counts.put_new(CLOSED, 1)
  _ = chans.ready.recv(CLOSE_GRACE_MS)
  Task.cancel(owner)
  return "pool error: start timed out after #{START_MS} ms"
end

def check_spec[A, W](spec: Spec[A, W]) -> Result[Void]
  if spec.size < 1
    return error("pool error: size must be at least 1, got #{spec.size}")
  end

  if spec.size + spec.max_overflow > MAX_RESOURCES
    return error("pool error: size + max_overflow cannot be more than #{MAX_RESOURCES}")
  end

  if spec.checkout_ms < 1 or spec.lease_ms < 1
    return error("pool error: checkout_ms and lease_ms must be at least 1")
  end

  if (
    spec.max_overflow < 0 or
    spec.overflow_idle_ms < 0 or
    spec.max_age_ms < 0 or
    spec.idle_ms < 0 or
    spec.max_waiting < 0 or
    spec.health_ms < 0
  )
    return error(
      "pool error: max_overflow, overflow_idle_ms, max_age_ms, idle_ms, max_waiting and health_ms cannot be negative",
    )
  end

  if (spec.max_age_ms > 0 or spec.idle_ms > 0) and spec.health_ms == 0
    return error("pool error: max_age_ms and idle_ms need health_ms, which applies them")
  end

  if spec.idle_ms > 0 and not spec.lazy
    return error("pool error: idle_ms needs a lazy pool, which does not make a new resource at once")
  end

  return ok()
end

# The owner task: makes the resources, then serves the control channel until a Stop has drained.
def own[A, W](spec: Spec[A, W], counts: ATS[String, Int], chans: Chans[W]) -> Void
  core = Core(
    spec: spec,
    counts: counts,
    jobs: chans.jobs,
    control: chans.control,
    idle: chans.idle,
    ready: chans.ready,
  )

  made = top_up(core, fresh(core))
  if not made.failure.empty? or core.counts.has_key?(CLOSED)
    end_all(core, made)
    _ = core.ready.send(error(start_error(made)), SEND_MS)
    return
  end

  _ = core.ready.send(ok(), SEND_MS)
  state = made
  while not state.done
    state = step(core, state)
  end
end

def start_error[W](made: Owned[W]) -> String
  if made.failure.empty?
    return "pool error: start abandoned"
  end

  return made.failure
end

def fresh[A, W](core: Core[A, W]) -> Owned[W]
  return Owned(
    workers: {},
    jobs: {},
    leases: {},
    failure: "",
    retry_at_ms: 0,
    trim_at_ms: 0,
    health: none,
    next_tick_ms: Time.monotonic_ms() + core.spec.health_ms,
    closing: none,
    deadline_ms: 0,
    done: false,
  )
end

# Waits for one message, at most until the next health tick, init retry or end of a drain, handles it and then
# takes in the jobs that came meanwhile.
def step[A, W](core: Core[A, W], state: Owned[W]) -> Owned[W]
  case core.control.recv(wait_ms(core, state))
    ok(msg) -> return after(core, take_jobs(core, handle(core, state, msg)))
    error(_) -> return after(core, take_jobs(core, state))
  end
end

def wait_ms[A, W](core: Core[A, W], state: Owned[W]) -> Int
  now = Time.monotonic_ms()
  until = now + MAX_WAIT_MS
  if state.closing.some?
    until = state.deadline_ms
  elsif core.spec.health_ms > 0
    until = state.next_tick_ms
  end

  if state.retry_at_ms > 0 and live(core) < wanted(core, state) and state.retry_at_ms < until
    until = state.retry_at_ms
  end

  # A drain ends the pool without trimming: a trim that is due would make the wait 1 ms long until the drain is over.
  if state.trim_at_ms > 0 and state.trim_at_ms < until and not state.closing.some?
    until = state.trim_at_ms
  end

  return (until - now).clamp(1, MAX_WAIT_MS)
end

def handle[A, W](core: Core[A, W], state: Owned[W], msg: Msg[W]) -> Owned[W]
  case msg
    Msg.Wake -> return state
    Msg.Back(release) -> return take_back(core, state, release)
    Msg.Drop(slot) -> return replace(core, state, slot)
    Msg.GaveUp(job_id) -> return schedule_trim(core, forget(state, job_id))
    Msg.Stop(closing) -> return state.with(closing: some(closing), deadline_ms: Time.monotonic_ms() + closing.drain_ms)
  end
end

def forget[W](state: Owned[W], job_id: Int) -> Owned[W]
  return state.with(jobs: state.jobs.delete(job_id), leases: state.leases.delete(job_id))
end

def take_jobs[A, W](core: Core[A, W], state: Owned[W]) -> Owned[W]
  current = state
  while true
    case core.jobs.recv(0)
      error(_) -> return current
      ok(job) -> current = admit(core, current, job)
    end
  end

  return current
end

# A new job: start its lease task, which times out on its own, then make a resource if the pool is lazy (or in a
# spike) and every one is taken. A slow `init` holds the owner, not the clock of the lease task.
def admit[A, W](core: Core[A, W], state: Owned[W], job: Job[W]) -> Owned[W]
  if state.closing.some?
    _ = job.call(Offer.Deny(CLOSED_ERROR))
    return state
  end

  job_id = core.counts.add(NEXT_JOB, 1)
  lease_fn: Fn[Lease[A, W], Void] = &lease
  task = Task.spawn(lease_fn, Lease(core: core, job_id: job_id, job: job))
  waiting = state.with(jobs: state.jobs.put(job_id, job), leases: state.leases.put(job_id, task))
  return top_up(core, waiting)
end

# A lease task ended: the resource goes back to the line, or is ended and replaced. A resource beyond `size` that no
# job needs goes back to the line too, and is ended later if it is still idle (`overflow_idle_ms`).
def take_back[A, W](core: Core[A, W], state: Owned[W], release: Release[W]) -> Owned[W]
  slot = release.slot
  ended = forget(state, release.job_id)
  now = Time.monotonic_ms()
  if not release.keep or not state.workers.key?(slot.id) or aged?(core.spec, slot, now)
    return replace(core, ended, slot)
  end

  if surplus?(core, ended) and core.spec.overflow_idle_ms == 0
    return replace(core, ended, slot)
  end

  _ = core.idle.send(slot.with(idle_since_ms: now), 0)
  return schedule_trim(core, ended)
end

# Ends a resource and makes another in its place if the pool wants one.
def replace[A, W](core: Core[A, W], state: Owned[W], slot: Slot[W]) -> Owned[W]
  if not state.workers.key?(slot.id)
    return state
  end

  core.spec.terminate.call(slot.worker)
  core.counts.add(LIVE, -1)
  return top_up(core, state.with(workers: state.workers.delete(slot.id)))
end

# Plans to end the idle overflow resources `overflow_idle_ms` from now, unless a plan waits already.
def schedule_trim[A, W](core: Core[A, W], state: Owned[W]) -> Owned[W]
  if not surplus?(core, state) or state.trim_at_ms > 0
    return state
  end

  if core.spec.overflow_idle_ms == 0
    return trim(core, state)
  end

  return state.with(trim_at_ms: Time.monotonic_ms() + core.spec.overflow_idle_ms)
end

# Ends the idle resources beyond what the jobs need and `size` that have been idle for `overflow_idle_ms`. A resource
# that the health check holds is not in `idle`; the plan is made again, so it is looked at when it is back.
def trim[A, W](core: Core[A, W], state: Owned[W]) -> Owned[W]
  current = state.with(trim_at_ms: 0)
  now = Time.monotonic_ms()
  left = live(core)
  while left > 0 and surplus?(core, current)
    left -= 1
    case core.idle.recv(0)
      error(_) -> left = 0
      ok(slot) ->
        if now - slot.idle_since_ms >= core.spec.overflow_idle_ms
          current = replace(core, current, slot)
        else
          _ = core.idle.send(slot, 0)
        end
    end
  end

  if core.spec.overflow_idle_ms == 0
    return current
  end

  return schedule_trim(core, current)
end

def surplus?[A, W](core: Core[A, W], state: Owned[W]) -> Bool
  return live(core) > state.jobs.size.clamp(core.spec.size, core.spec.size + core.spec.max_overflow)
end

# Makes resources until the pool has as many as it wants. A failed `init` stops it, and the next try waits
# INIT_RETRY_MS: a database that is down is not asked once for every job.
def top_up[A, W](core: Core[A, W], state: Owned[W]) -> Owned[W]
  current = state
  while live(core) < wanted(core, current) and Time.monotonic_ms() >= current.retry_at_ms
    current = add_worker(core, current)
    if not current.failure.empty?
      return current
    end
  end

  return current
end

def add_worker[A, W](core: Core[A, W], state: Owned[W]) -> Owned[W]
  case core.spec.init.call(core.spec.config)
    error(message) ->
      forget_init_error(core.counts)
      core.counts.put_new("#{INIT_ERROR}#{message}", 1)
      return state.with(failure: message, retry_at_ms: Time.monotonic_ms() + INIT_RETRY_MS)
    ok(worker) ->
      forget_init_error(core.counts)
      id = core.counts.add(NEXT_ID, 1)
      now = Time.monotonic_ms()
      core.counts.add(LIVE, 1)
      _ = core.idle.send(Slot(id: id, worker: worker, born_ms: now, idle_since_ms: now), 0)
      return state.with(workers: state.workers.put(id, worker), failure: "", retry_at_ms: 0)
  end
end

# An eager pool keeps `size` resources, a lazy one the resources it has made, and both grow with the jobs that have
# not ended up to `size + max_overflow`.
def wanted[A, W](core: Core[A, W], state: Owned[W]) -> Int
  if state.closing.some? or core.counts.has_key?(CLOSED)
    return live(core)
  end

  most = core.spec.size + core.spec.max_overflow
  if core.spec.lazy
    return state.jobs.size.clamp(live(core), most)
  end

  return state.jobs.size.clamp(core.spec.size, most)
end

def live[A, W](core: Core[A, W]) -> Int
  return core.counts.get(LIVE).unwrap_or(0)
end

# Runs after every message and every wait: finishes a drain, retries a failed `init`, or starts the health check when
# it is due.
def after[A, W](core: Core[A, W], state: Owned[W]) -> Owned[W]
  now = Time.monotonic_ms()
  if state.closing.some?
    if state.jobs.empty? or now >= state.deadline_ms
      return finish(core, state)
    end

    return state
  end

  topped = top_up(core, state)
  if topped.trim_at_ms > 0 and now >= topped.trim_at_ms
    return after_trim(core, trim(core, topped), now)
  end

  return after_trim(core, topped, now)
end

def after_trim[A, W](core: Core[A, W], state: Owned[W], now: Int) -> Owned[W]
  if core.spec.health_ms == 0 or now < state.next_tick_ms
    return state
  end

  return health_tick(core, state, now)
end

def health_tick[A, W](core: Core[A, W], state: Owned[W], now: Int) -> Owned[W]
  next_tick = state.with(next_tick_ms: now + core.spec.health_ms)
  if checking?(state.health)
    return next_tick
  end

  check_fn: Fn[Core[A, W], Void] = &check_idle
  return next_tick.with(health: some(Task.spawn(check_fn, core)))
end

def checking?(health: Optional[Task[Void]]) -> Bool
  case health
    some(task) ->
      case Task.await(task, 1)
        Await.Done(_) -> return false
        Await.TimedOut -> return true
      end

    none -> return false
  end
end

# The health check, in a task of its own so that the owner keeps serving while a ping is slow (the resource that is
# being pinged is not lent meanwhile): looks at each idle resource once, drops the stale and the unhealthy ones (the
# owner replaces them) and puts the others back.
def check_idle[A, W](core: Core[A, W]) -> Void
  seen: Set[Int] = Set.new([])
  while true
    case core.idle.recv(0)
      error(_) -> return
      ok(slot) ->
        if seen.include?(slot.id)
          _ = core.idle.send(slot, 0)
          return
        end

        seen = seen.add(slot.id)
        inspect_idle(core, slot)
    end
  end
end

def inspect_idle[A, W](core: Core[A, W], slot: Slot[W]) -> Void
  if stale?(core.spec, slot, Time.monotonic_ms()) or not settled?(Task.spawn do core.spec.ping.call(slot.worker) end)
    notify(core, Msg.Drop(slot))
  else
    _ = core.idle.send(slot, 0)
  end
end

# Tells the owner. The news is never dropped: it waits for room in `control` until the owner is gone.
def notify[A, W](core: Core[A, W], msg: Msg[W]) -> Void
  while not core.control.closed?
    if core.control.send(msg, SEND_MS).ok?
      return
    end
  end
end

# A resource that is too old, or that has waited too long without a job.
def stale?[A, W](spec: Spec[A, W], slot: Slot[W], now: Int) -> Bool
  idle_for = now - slot.idle_since_ms
  return aged?(spec, slot, now) or (spec.idle_ms > 0 and idle_for >= spec.idle_ms)
end

def aged?[A, W](spec: Spec[A, W], slot: Slot[W], now: Int) -> Bool
  return spec.max_age_ms > 0 and now - slot.born_ms >= spec.max_age_ms
end

# True when the task gives ok within HOOK_MS; a task that is late is cancelled.
def settled?(task: Task[Result[Void]]) -> Bool
  case Task.await(task, HOOK_MS)
    Await.Done(result) -> return result.ok?
    Await.TimedOut ->
      Task.cancel(task)
      return false
  end
end

# The end of a drain. The jobs left are failed first, so that a caller hears `closed` and not the cancel of its lease.
# Nobody can take a resource any more (`idle` is closed and emptied) and the lease tasks and the health check that are
# left are cancelled, with a moment for them to stop, before the resources are ended: no body or ping runs on a
# resource that is gone.
# Then it tells `close` that it is done.
def finish[A, W](core: Core[A, W], state: Owned[W]) -> Owned[W]
  state.jobs.values.each do |job| _ = job.call(Offer.Deny(CLOSED_ERROR)) end
  core.idle.close
  while core.idle.recv(0).ok?
    next
  end

  state.leases.values.each do |task| Task.cancel(task) end
  stop_health(state.health)
  if not state.leases.empty? or state.health.some?
    Task.sleep(CANCEL_GRACE_MS)
  end

  ended = end_all(core, state)
  core.jobs.close
  refuse_queued(core)
  core.control.close
  acknowledge(state.closing)
  return ended.with(done: true, jobs: {}, leases: {})
end

# The health check pings a resource in a task of its own, so it is cancelled before `terminate` ends that resource.
def stop_health(health: Optional[Task[Void]]) -> Void
  case health
    some(task) -> Task.cancel(task)
    none -> return
  end
end

def acknowledge(closing: Optional[Closing]) -> Void
  case closing
    some(asked) -> _ = asked.done.send(true, SEND_MS)
    none -> return
  end
end

# The jobs that reached `jobs` before it closed.
def refuse_queued[A, W](core: Core[A, W]) -> Void
  while true
    case core.jobs.recv(0)
      error(_) -> return
      ok(job) -> _ = job.call(Offer.Deny(CLOSED_ERROR))
    end
  end
end

def end_all[A, W](core: Core[A, W], state: Owned[W]) -> Owned[W]
  state.workers.values.each do |worker| core.spec.terminate.call(worker) end
  return state.with(workers: {})
end

# A lease task: waits for a resource, runs the body on it, checks it in, and tells the owner. Whatever happens to the
# body or to the caller, it reaches the last step, so the owner always gets the resource back.
def lease[A, W](held: Lease[A, W]) -> Void
  core = held.core
  case take(core)
    error(message) ->
      _ = held.job.call(Offer.Deny(message))
      notify(core, Msg.GaveUp(held.job_id))
    ok(slot) ->
      outcome = run_body(held, slot)
      kept = settled?(Task.spawn do core.spec.checkin.call(slot.worker, outcome) end)
      keep = kept and outcome != Outcome.TimedOut
      notify(core, Msg.Back(Release(job_id: held.job_id, slot: slot, keep: keep)))
  end
end

# A free resource if there is one, else a place in line (when `max_waiting` allows) for up to `checkout_ms`.
def take[A, W](core: Core[A, W]) -> Result[Slot[W]]
  case core.idle.recv(0)
    ok(slot) -> return ok(slot)
    error(_) -> return wait_for(core)
  end
end

def wait_for[A, W](core: Core[A, W]) -> Result[Slot[W]]
  if core.counts.add(WAITING, 1) > core.spec.max_waiting
    core.counts.add(WAITING, -1)
    return error("#{QUEUE_FULL_ERROR} (max_waiting #{core.spec.max_waiting})")
  end

  got = core.idle.recv(core.spec.checkout_ms)
  core.counts.add(WAITING, -1)
  case got
    ok(slot) -> return ok(slot)
    error(_) if core.idle.closed? -> return error(closed_message(core))
    error(_) -> return error("#{CHECKOUT_TIMEOUT} after #{core.spec.checkout_ms} ms#{init_error(core.counts)}")
  end
end

def closed_message[A, W](core: Core[A, W]) -> String
  if core.counts.has_key?(CLOSED)
    return CLOSED_ERROR
  end

  return OWNER_ENDED_ERROR
end

# The error of the last `init`, when it failed, for the caller that waited in vain.
def init_error(counts: ATS[String, Int]) -> String
  for key in counts.keys
    if key.start_with?(INIT_ERROR)
      return " (the last init failed: #{key.slice(INIT_ERROR.size, key.size - INIT_ERROR.size)})"
    end
  end

  return ""
end

def forget_init_error(counts: ATS[String, Int]) -> Void
  for key in counts.keys
    if key.start_with?(INIT_ERROR)
      counts.delete(key)
    end
  end
end

# Runs the body in a task of its own and says how it ended. The caller learns of a crash or a timeout here, since
# the body could not send its result. A body that ran past `lease_ms` is cancelled, and given a moment to stop.
def run_body[A, W](held: Lease[A, W], slot: Slot[W]) -> Outcome
  lease_ms = held.core.spec.lease_ms
  runner = Task.spawn(held.job, Offer.Grant(slot.worker))
  case Task.await(runner, lease_ms)
    Await.TimedOut ->
      Task.cancel(runner)
      Task.sleep(CANCEL_GRACE_MS)
      _ = held.job.call(Offer.Deny("#{LEASE_TIMEOUT} after #{lease_ms} ms"))
      return Outcome.TimedOut
    Await.Done(error(message)) ->
      _ = held.job.call(Offer.Deny(message))
      return Outcome.Crashed
    Await.Done(_) -> return Outcome.Done
  end
end
