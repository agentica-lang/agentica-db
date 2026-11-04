## A generic pool of resources (the idea of Elixir's NimblePool): a fixed number of long-lived resources of any type
## `W`, made and ended by the functions of a `Spec`, lent to the body of `Pool.with` one caller at a time.
##
## One owner task makes and ends the resources and never runs the body of a caller. For each job it starts a lease
## task, which waits in line for a free resource (first come, first served), runs the body in a task of its own,
## and hands the resource back with the outcome of the body. A body that crashes or runs past `lease_ms`, and a
## caller that crashes or is cancelled, cannot keep a resource: the lease task always returns it.
##
## Start the pool in a task that lives as long as the pool (`main`): the owner task ends with the task that started
## it. The body of a caller is not cancelled when the caller is; `lease_ms` bounds it.

# Sizes of the queues and the waits that are not part of a `Spec`.
INBOX_SIZE = 1_024
START_MS = 60_000
HOOK_MS = 5_000
SEND_MS = 5_000
REPLY_GRACE_MS = 5_000
CLOSE_GRACE_MS = 2_000
MAX_WAIT_MS = 1_000

# The keys of the counters that the owner, the lease tasks and the callers share.
LIVE = "live"
WAITING = "waiting"
NEXT_ID = "next_id"
NEXT_JOB = "next_job"
CLOSED = "closed"

CLOSED_ERROR = "pool error: closed"
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
## run in the owner task, so they must not crash or block for long. A time of 0 for `max_age_ms`, `idle_ms` or
## `health_ms` turns that rule off.
export struct Spec[A, W]
  config: A
  init: Fn[A, Result[W]]
  checkin: Fn[W, Outcome, Result[Void]]
  terminate: Fn[W, Void]
  ping: Fn[W, Result[Void]]
  size: Int = 10
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
  inbox: Channel[Msg[W]]
  owner: Task[Void]
  counts: ATS[String, Int]
end

# A caller's work. It runs the body on a granted resource and gives the caller's result; a denial it gives the caller
# as an error.
type Job[W] = Fn[Offer[W], Result[Void]]

# What the callers and the lease tasks tell the owner.
enum Msg[W]
  Run(Job[W])
  Back(Release[W])
  Drop(Slot[W])
  GaveUp(Int)
  Stop(Closing)
end

# What a lease task tells a caller's job: a resource to run the body on, or the error that the caller gets instead.
enum Offer[W]
  Grant(W)
  Deny(String)
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

# What every task of the pool shares.
struct Core[A, W]
  spec: Spec[A, W]
  inbox: Channel[Msg[W]]
  idle: Channel[Slot[W]]
  counts: ATS[String, Int]
  ready: Channel[Result[Void]]
end

struct Lease[A, W]
  core: Core[A, W]
  job_id: Int
  job: Job[W]
end

# The owner's state: the resources it holds, by slot id, and the jobs that have not ended. `failure` is why the last
# `init` failed, empty when it did not.
struct Owned[W]
  workers: Map[Int, W]
  jobs: Map[Int, Job[W]]
  failure: String
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
  inbox: Channel[Msg[W]] = Channel.new(INBOX_SIZE)
  idle: Channel[Slot[W]] = Channel.new(spec.size)
  ready: Channel[Result[Void]] = Channel.new(1)
  counts: ATS[String, Int] = ATS.new()
  core = Core(spec: spec, inbox: inbox, idle: idle, counts: counts, ready: ready)
  owner_fn: Fn[Core[A, W], Void] = &own
  owner = Task.spawn(owner_fn, core)
  started = ready.recv(START_MS)
  if not started.ok?
    Task.cancel(owner)
    return error("pool error: start timed out after #{START_MS} ms")
  end

  try try started
  return ok(Pool(spec: spec, inbox: inbox, owner: owner, counts: counts))
end

## Runs the body with a resource of the pool and gives its result. The body runs in a task of the pool, so a crash
## in it is an `error` here, and the resource is checked in with the outcome. Other errors: `pool error: checkout
## timed out after N ms`, `pool error: lease timed out after N ms` (the body ran longer than `lease_ms`),
## `pool error: queue full` (`max_waiting` callers wait already) and `pool error: closed`.
export def with[A, W, R](pool: Pool[A, W], body: Fn[W, Result[R]]) -> Result[R]
  if pool.counts.has_key?(CLOSED)
    return error(CLOSED_ERROR)
  end

  reply: Channel[Result[R]] = Channel.new(1)
  sent = enqueue(pool) do |offer| answer(reply, body, offer) end
  if pool.inbox.closed?
    return error(CLOSED_ERROR)
  end

  if not sent.ok?
    return error(QUEUE_FULL_ERROR)
  end

  wait_ms = pool.spec.checkout_ms + pool.spec.lease_ms + REPLY_GRACE_MS
  case reply.recv(wait_ms)
    ok(result) -> return result
    error(_) -> return error("pool error: no reply after #{wait_ms} ms")
  end
end

## Refuses new jobs, lets the running ones and the ones in line finish for up to `drain_ms`, fails the rest with
## `pool error: closed`, ends every resource and stops the pool. Closing twice does nothing.
export def close[A, W](pool: Pool[A, W], drain_ms: Int) -> Void
  if not pool.counts.put_new(CLOSED, 1)
    return
  end

  done: Channel[Bool] = Channel.new(1)
  closing = Closing(drain_ms: [drain_ms, 0].max.unwrap!, done: done)
  if pool.inbox.send(Msg.Stop(closing), CLOSE_GRACE_MS).ok?
    done.recv(closing.drain_ms + CLOSE_GRACE_MS)
  end

  Task.cancel(pool.owner)
end

## True for the error of a checkout or a lease that ran out of time.
export def timeout?(message: String) -> Bool
  return message.start_with?(CHECKOUT_TIMEOUT) or message.start_with?(LEASE_TIMEOUT)
end

def enqueue[A, W](pool: Pool[A, W], job: Job[W]) -> Result[Void]
  return pool.inbox.send(Msg.Run(job), pool.spec.checkout_ms)
end

# Runs inside the job: gives the caller the result of the body, or the denial.
def answer[W, R](reply: Channel[Result[R]], body: Fn[W, Result[R]], offer: Offer[W]) -> Result[Void]
  case offer
    Offer.Grant(worker) -> return reply.send(body.call(worker), SEND_MS)
    Offer.Deny(message) -> return reply.send(error(message), 0)
  end
end

def check_spec[A, W](spec: Spec[A, W]) -> Result[Void]
  if spec.size < 1
    return error("pool error: size must be at least 1, got #{spec.size}")
  end

  if spec.checkout_ms < 1 or spec.lease_ms < 1
    return error("pool error: checkout_ms and lease_ms must be at least 1")
  end

  if spec.max_age_ms < 0 or spec.idle_ms < 0 or spec.max_waiting < 0 or spec.health_ms < 0
    return error("pool error: max_age_ms, idle_ms, max_waiting and health_ms cannot be negative")
  end

  return ok()
end

# The owner task: makes the resources, then serves the inbox until a Stop has drained.
def own[A, W](core: Core[A, W]) -> Void
  made = top_up(core, fresh(core))
  if not made.failure.empty?
    end_all(core, made)
    core.ready.send(error(made.failure), SEND_MS)
    return
  end

  core.ready.send(ok(), SEND_MS)
  state = made
  while not state.done
    state = step(core, state)
  end
end

def fresh[A, W](core: Core[A, W]) -> Owned[W]
  return Owned(
    workers: {},
    jobs: {},
    failure: "",
    health: none,
    next_tick_ms: Time.monotonic_ms() + core.spec.health_ms,
    closing: none,
    deadline_ms: 0,
    done: false,
  )
end

# Waits for one message, at most until the next health tick or the end of a drain, and handles it.
def step[A, W](core: Core[A, W], state: Owned[W]) -> Owned[W]
  case core.inbox.recv(wait_ms(state))
    ok(msg) -> return after(core, handle(core, state, msg))
    error(_) -> return after(core, state)
  end
end

def wait_ms[W](state: Owned[W]) -> Int
  now = Time.monotonic_ms()
  until = state.next_tick_ms
  if state.closing.some?
    until = state.deadline_ms
  end

  return (until - now).clamp(1, MAX_WAIT_MS)
end

def handle[A, W](core: Core[A, W], state: Owned[W], msg: Msg[W]) -> Owned[W]
  case msg
    Msg.Run(job) -> return admit(core, state, job)
    Msg.Back(release) -> return take_back(core, state, release)
    Msg.Drop(slot) -> return replace(core, state, slot)
    Msg.GaveUp(job_id) -> return state.with(jobs: state.jobs.delete(job_id))
    Msg.Stop(closing) -> return state.with(closing: some(closing), deadline_ms: Time.monotonic_ms() + closing.drain_ms)
  end
end

# A new job: make a resource first when the pool is lazy and every one is taken, then start its lease task.
def admit[A, W](core: Core[A, W], state: Owned[W], job: Job[W]) -> Owned[W]
  if state.closing.some?
    job.call(Offer.Deny(CLOSED_ERROR))
    return state
  end

  job_id = core.counts.add(NEXT_JOB, 1)
  jobs = state.jobs.put(job_id, job)
  grown = top_up(core, state.with(jobs: jobs, failure: ""))
  lease_fn: Fn[Lease[A, W], Void] = &lease
  Task.spawn(lease_fn, Lease(core: core, job_id: job_id, job: job))
  return grown
end

# A lease task ended: the resource goes back to the line, or is ended and replaced.
def take_back[A, W](core: Core[A, W], state: Owned[W], release: Release[W]) -> Owned[W]
  slot = release.slot
  ended = state.with(jobs: state.jobs.delete(release.job_id))
  if release.keep and state.workers.key?(slot.id) and not aged?(core.spec, slot, Time.monotonic_ms())
    core.idle.send(slot.with(idle_since_ms: Time.monotonic_ms()), 0)
    return ended
  end

  return replace(core, ended, slot)
end

# Ends a resource and, unless the pool is lazy or closing, makes another in its place.
def replace[A, W](core: Core[A, W], state: Owned[W], slot: Slot[W]) -> Owned[W]
  if not state.workers.key?(slot.id)
    return state
  end

  core.spec.terminate.call(slot.worker)
  core.counts.add(LIVE, -1)
  return top_up(core, state.with(workers: state.workers.delete(slot.id), failure: ""))
end

# Makes resources until the pool has as many as it wants. A failed `init` stops it; the next job, release or health
# tick tries again.
def top_up[A, W](core: Core[A, W], state: Owned[W]) -> Owned[W]
  current = state
  while live(core) < wanted(core, current) and current.failure.empty?
    current = add_worker(core, current)
  end

  return current
end

def add_worker[A, W](core: Core[A, W], state: Owned[W]) -> Owned[W]
  case core.spec.init.call(core.spec.config)
    error(message) -> return state.with(failure: message)
    ok(worker) ->
      id = core.counts.add(NEXT_ID, 1)
      now = Time.monotonic_ms()
      core.counts.add(LIVE, 1)
      core.idle.send(Slot(id: id, worker: worker, born_ms: now, idle_since_ms: now), 0)
      return state.with(workers: state.workers.put(id, worker))
  end
end

# A lazy pool grows with the jobs that have not ended, up to its size; any other pool keeps its size.
def wanted[A, W](core: Core[A, W], state: Owned[W]) -> Int
  if state.closing.some?
    return live(core)
  end

  if not core.spec.lazy
    return core.spec.size
  end

  return state.jobs.size.clamp(live(core), core.spec.size)
end

def live[A, W](core: Core[A, W]) -> Int
  return core.counts.get(LIVE).unwrap_or(0)
end

# Runs after every message and every wait: finishes a drain, or starts the health check when it is due.
def after[A, W](core: Core[A, W], state: Owned[W]) -> Owned[W]
  now = Time.monotonic_ms()
  if state.closing.some?
    if state.jobs.empty? or now >= state.deadline_ms
      return finish(core, state)
    end

    return state
  end

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

  topped = top_up(core, next_tick.with(failure: ""))
  check_fn: Fn[Core[A, W], Void] = &check_idle
  return topped.with(health: some(Task.spawn(check_fn, core)))
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

# The health check, in a task of its own so that a slow ping holds nobody: looks at each idle resource once, drops
# the stale and the unhealthy ones (the owner replaces them) and puts the others back.
def check_idle[A, W](core: Core[A, W]) -> Void
  seen: Set[Int] = Set.new([])
  while true
    case core.idle.recv(0)
      error(_) -> return
      ok(slot) ->
        if seen.include?(slot.id)
          core.idle.send(slot, 0)
          return
        end

        seen = seen.add(slot.id)
        inspect_idle(core, slot)
    end
  end
end

def inspect_idle[A, W](core: Core[A, W], slot: Slot[W]) -> Void
  if stale?(core.spec, slot, Time.monotonic_ms()) or not settled?(Task.spawn do core.spec.ping.call(slot.worker) end)
    core.inbox.send(Msg.Drop(slot), SEND_MS)
  else
    core.idle.send(slot, 0)
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

# The end of a drain: ends every resource, fails the jobs left, and tells `close` that it is done.
def finish[A, W](core: Core[A, W], state: Owned[W]) -> Owned[W]
  ended = end_all(core, state)
  core.idle.close
  core.inbox.close
  state.jobs.values.each do |job| job.call(Offer.Deny(CLOSED_ERROR)) end
  refuse_queued(core)
  acknowledge(state.closing)
  return ended.with(done: true, jobs: {})
end

def acknowledge(closing: Optional[Closing]) -> Void
  case closing
    some(asked) -> asked.done.send(true, SEND_MS)
    none -> return
  end
end

# The jobs that reached the inbox before it closed.
def refuse_queued[A, W](core: Core[A, W]) -> Void
  while true
    case core.inbox.recv(0)
      error(_) -> return
      ok(msg) ->
        case msg
          Msg.Run(job) -> job.call(Offer.Deny(CLOSED_ERROR))
          _ -> next
        end
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
      held.job.call(Offer.Deny(message))
      core.inbox.send(Msg.GaveUp(held.job_id), SEND_MS)
    ok(slot) ->
      outcome = run_body(held, slot)
      keep = settled?(Task.spawn do core.spec.checkin.call(slot.worker, outcome) end)
      core.inbox.send(Msg.Back(Release(job_id: held.job_id, slot: slot, keep: keep)), SEND_MS)
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
    return error(QUEUE_FULL_ERROR)
  end

  got = core.idle.recv(core.spec.checkout_ms)
  core.counts.add(WAITING, -1)
  case got
    ok(slot) -> return ok(slot)
    error(_) if core.idle.closed? -> return error(CLOSED_ERROR)
    error(_) -> return error("#{CHECKOUT_TIMEOUT} after #{core.spec.checkout_ms} ms")
  end
end

# Runs the body in a task of its own and says how it ended. The caller learns of a crash or a timeout here, since
# the body could not send its result.
def run_body[A, W](held: Lease[A, W], slot: Slot[W]) -> Outcome
  lease_ms = held.core.spec.lease_ms
  runner = Task.spawn(held.job, Offer.Grant(slot.worker))
  case Task.await(runner, lease_ms)
    Await.TimedOut ->
      Task.cancel(runner)
      held.job.call(Offer.Deny("#{LEASE_TIMEOUT} after #{lease_ms} ms"))
      return Outcome.TimedOut
    Await.Done(error(message)) if died?(message) ->
      held.job.call(Offer.Deny(message))
      return Outcome.Crashed
    Await.Done(_) -> return Outcome.Done
  end
end

# `Task.await` gives these errors for a task that crashed or was cancelled.
def died?(message: String) -> Bool
  return message.start_with?("task crashed") or message == "task: cancelled"
end
