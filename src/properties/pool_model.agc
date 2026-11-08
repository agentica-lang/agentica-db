## Random sequences of checkouts, releases, cancels, lease timeouts and closes on a pool of fake resources, and the
## invariants that every sequence must keep. A resource is a numbered cell; the counters of `Fake` say what the pool
## did with it. The numbers of a `Setup` and of a `Job` are what the generator makes (any Int in -1000..1000);
## `setup_of` and `job_of` bring them into small ranges, so that a shrunk case is the plain one (size 1, a body that
## holds).

import Pool from "pkg/pool/pool"
import Prop from "pkg/prop/prop"

LEASE_MS = 30
CHECKOUT_MS = 60
# A burst never times out a caller or a body: it counts who is refused.
BURST_LEASE_MS = 30_000
BURST_CHECKOUT_MS = 30_000
# Longer than the time the callers of a burst need to arrive, so none finishes before the last one asks.
BURST_HOLD_MS = 100
HANG_MS = 60_000
CLOSE_DRAIN_MS = 100
ANSWER_MS = 10_000
SETTLE_MS = 3_000
POLL_MS = 5
MAX_JOBS = 6
MAX_BURST = 8
QUEUE_FULL = "pool error: queue full"
# The counter of the callers in line, which the pool keeps in its public `counts` (the name is the pool's).
WAITING = "waiting"

## The settings of a pool and of the sequence, as the generator makes them. `close_ms` closes the pool in the middle of
## the sequence.
export struct Setup
  size: Int
  max_overflow: Int
  max_waiting: Int
  lazy: Bool
  reuse_crashed: Bool
  close_ms: Optional[Int]
end

## What the body of a caller does: holds the resource for `hold_ms`, crashes, fails, or hangs until the lease ends it.
export enum Body
  Holds
  Crashes
  Fails
  Hangs
end

## One caller: it starts after `start_ms`, takes a resource and runs a body of its `kind`; `cancel_ms` cancels the
## caller that long after the start.
export struct Job
  kind: Body
  start_ms: Int
  hold_ms: Int
  cancel_ms: Optional[Int]
end

# The config of the pool: where to count, and whether a resource whose body crashed goes back to the line.
struct Fake
  stats: ATS[String, Int]
  reuse_crashed: Bool
end

struct Cell
  id: Int
  fake: Fake
end

struct JobArgs
  pool: Pool.Pool[Fake, Cell]
  stats: ATS[String, Int]
  job: Job
end

struct CancelArgs
  task: Task[Void]
  ms: Int
end

struct CloseArgs
  pool: Pool.Pool[Fake, Cell]
  ms: Int
end

## The generator of a sequence: a setup and up to six jobs.
export def sequence_gen() -> Prop.Gen[Prop.Pair[Setup, List[Job]]]
  return Prop.pair(Prop.of(Setup.codec, JSON.schema(Setup)), Prop.list(Prop.of(Job.codec, JSON.schema(Job)), MAX_JOBS))
end

## The generator of a burst: a setup and how many callers arrive at once.
export def burst_gen() -> Prop.Gen[Prop.Pair[Setup, Int]]
  return Prop.pair(Prop.of(Setup.codec, JSON.schema(Setup)), Prop.int(1, MAX_BURST))
end

## Runs the jobs on a pool of the setup, a task each, with the cancels and the close of the sequence. It checks that no
## resource was lent twice or after it ended, that the resources in use never passed `size + max_overflow`, that every
## caller that was not cancelled got an answer, and, once the pool is closed, that every resource made was ended and
## that no caller holds one or waits in line.
export def keeps_invariants(raw: Setup, raw_jobs: List[Job]) -> Result[Void]
  setup = setup_of(raw)
  stats: ATS[String, Int] = ATS.new()
  pool = try Pool.start(spec_of(setup, stats, CHECKOUT_MS, LEASE_MS))
  closer = start_closer(pool, setup)
  answered = run_jobs(pool, stats, raw_jobs.map do |job| job_of(job) end)
  Pool.close(pool, CLOSE_DRAIN_MS)
  try wait_closer(closer)
  try answered
  return audit(setup, pool, stats)
end

## A burst of `count` callers that hold a resource at once. Beyond the `size + max_overflow` resources only
## `max_waiting` callers may wait, so at least the rest are refused with a full queue; the others get their answer.
export def keeps_line(raw: Setup, count: Int) -> Result[Void]
  setup = setup_of(raw)
  stats: ATS[String, Int] = ATS.new()
  pool = try Pool.start(spec_of(setup, stats, BURST_CHECKOUT_MS, BURST_LEASE_MS))
  jobs: List[Job] = List.repeat(Job(kind: Body.Holds, start_ms: 0, hold_ms: BURST_HOLD_MS, cancel_ms: none), count)
  answered = run_jobs(pool, stats, jobs)
  Pool.close(pool, CLOSE_DRAIN_MS)
  try answered
  try audit(setup, pool, stats)
  refused = count_of(stats, "refused")
  least = count - setup.size - setup.max_overflow - setup.max_waiting
  if refused < least
    return error("#{refused} of #{count} callers were refused, at least #{least} must be (#{describe(setup)})")
  end

  if count_of(stats, "failed") > 0
    return error("#{count_of(stats, "failed")} of #{count} callers failed without being refused (#{describe(setup)})")
  end

  return ok()
end

def setup_of(raw: Setup) -> Setup
  return Setup(
    size: 1 + raw.size.abs % 3,
    max_overflow: raw.max_overflow.abs % 3,
    max_waiting: raw.max_waiting.abs % 4,
    lazy: raw.lazy,
    reuse_crashed: raw.reuse_crashed,
    close_ms: raw.close_ms.map do |ms| ms.abs % 120 end,
  )
end

def job_of(raw: Job) -> Job
  return Job(
    kind: raw.kind,
    start_ms: raw.start_ms.abs % 20,
    hold_ms: raw.hold_ms.abs % 16,
    cancel_ms: raw.cancel_ms.map do |ms| ms.abs % 50 end,
  )
end

def describe(setup: Setup) -> String
  return "size #{setup.size}, max_overflow #{setup.max_overflow}, max_waiting #{setup.max_waiting}, lazy #{setup.lazy}"
end

def spec_of(setup: Setup, stats: ATS[String, Int], checkout_ms: Int, lease_ms: Int) -> Pool.Spec[Fake, Cell]
  fake = Fake(stats: stats, reuse_crashed: setup.reuse_crashed)
  base = Pool.Spec(config: fake, init: &make, checkin: &check_in, terminate: &end_it, ping: &ping)
  return base.with(
    size: setup.size,
    max_overflow: setup.max_overflow,
    overflow_idle_ms: 0,
    checkout_ms: checkout_ms,
    lease_ms: lease_ms,
    max_waiting: setup.max_waiting,
    lazy: setup.lazy,
    health_ms: 0,
  )
end

def start_closer(pool: Pool.Pool[Fake, Cell], setup: Setup) -> Optional[Task[Void]]
  case setup.close_ms
    none -> return none
    some(ms) ->
      close_fn: Fn[CloseArgs, Void] = &close_after
      return some(Task.spawn(close_fn, CloseArgs(pool: pool, ms: ms)))
  end
end

def close_after(args: CloseArgs) -> Void
  Task.sleep(args.ms)
  Pool.close(args.pool, CLOSE_DRAIN_MS)
end

def wait_closer(closer: Optional[Task[Void]]) -> Result[Void]
  case closer
    none -> return ok()
    some(task) ->
      case Task.await(task, ANSWER_MS)
        Await.Done(_) -> return ok()
        Await.TimedOut -> return error("the close did not end within #{ANSWER_MS} ms")
      end
  end
end

# Starts a task for each caller (and one that cancels it, when the job says so), and waits for the answer of every
# caller that is not cancelled. A cancelled caller has no answer, which `audit` finds out from the counters.
def run_jobs(pool: Pool.Pool[Fake, Cell], stats: ATS[String, Int], jobs: List[Job]) -> Result[Void]
  run_fn: Fn[JobArgs, Void] = &run_job
  cancel_fn: Fn[CancelArgs, Void] = &cancel_after
  waited: List[Task[Void]] = []
  cancellers: List[Task[Void]] = []
  for job in jobs
    task = Task.spawn(run_fn, JobArgs(pool: pool, stats: stats, job: job))
    case job.cancel_ms
      none -> waited = waited.push(task)
      some(ms) -> cancellers = cancellers.push(Task.spawn(cancel_fn, CancelArgs(task: task, ms: job.start_ms + ms)))
    end
  end

  for task in waited
    case Task.await(task, ANSWER_MS)
      Await.Done(_) -> next
      Await.TimedOut -> return error("a caller got no answer within #{ANSWER_MS} ms")
    end
  end

  for task in cancellers
    case Task.await(task, ANSWER_MS)
      Await.Done(_) -> next
      Await.TimedOut -> return error("a cancel did not end within #{ANSWER_MS} ms")
    end
  end

  return ok()
end

def cancel_after(args: CancelArgs) -> Void
  Task.sleep(args.ms)
  Task.cancel(args.task)
end

# A caller: it counts how its checkout ended. A refusal is a full queue; anything else is a failure of the body or of
# the pool (a timeout, a close), which the invariants allow.
def run_job(args: JobArgs) -> Void
  Task.sleep(args.job.start_ms)
  result = Pool.with(args.pool) do |cell| use(cell, args.job) end
  case result
    ok(_) -> args.stats.add("answered", 1)
    error(message) if message.start_with?(QUEUE_FULL) -> args.stats.add("refused", 1)
    error(_) -> args.stats.add("failed", 1)
  end
end

# The body: it holds the resource, crashes, fails or hangs until the lease ends it. `holders` counts the resources in
# use (the checkin gives one back), `peak` the most at once, and `violations` a resource lent while it was in use or
# after it ended.
def use(cell: Cell, job: Job) -> Result[Int]
  stats = cell.fake.stats
  holders = stats.add("holders", 1)
  if holders > count_of(stats, "peak")
    stats.put("peak", holders)
  end

  if stats.add("lent_#{cell.id}", 1) > 1 or stats.has_key?("ended_#{cell.id}")
    stats.add("violations", 1)
  end

  case job.kind
    Body.Crashes -> return ok("not a number".to_i!)
    Body.Fails -> return error("the body failed")
    Body.Hangs ->
      Task.sleep(HANG_MS)
      return ok(cell.id)
    Body.Holds ->
      Task.sleep(job.hold_ms)
      return ok(cell.id)
  end
end

def make(fake: Fake) -> Result[Cell]
  return ok(Cell(id: fake.stats.add("made", 1), fake: fake))
end

# A resource goes back to the line after a clean body, and after a crash when the setup says so. After a timeout it is
# ended whatever this says (the body may still run), so a timed out one is marked as ended here, before the pool may
# lend it again.
def check_in(cell: Cell, outcome: Pool.Outcome) -> Result[Void]
  stats = cell.fake.stats
  stats.add("holders", -1)
  stats.add("lent_#{cell.id}", -1)
  case outcome
    Pool.Outcome.Done -> return ok()
    Pool.Outcome.Crashed ->
      if cell.fake.reuse_crashed
        return ok()
      end

      stats.put("ended_#{cell.id}", 1)
      return error("cell #{cell.id} is dirty")
    Pool.Outcome.TimedOut ->
      stats.put("ended_#{cell.id}", 1)
      return error("cell #{cell.id} timed out")
  end
end

def end_it(cell: Cell) -> Void
  cell.fake.stats.put("ended_#{cell.id}", 1)
  cell.fake.stats.add("terminated", 1)
end

def ping(_cell: Cell) -> Result[Void]
  return ok()
end

def count_of(stats: ATS[String, Int], name: String) -> Int
  return stats.get(name).unwrap_or(0)
end

# What must hold once the pool is closed. The ending of the resources and the return of the last bodies are
# asynchronous, so a count that is not yet right is polled for a while.
def audit(setup: Setup, pool: Pool.Pool[Fake, Cell], stats: ATS[String, Int]) -> Result[Void]
  if count_of(stats, "violations") > 0
    return error("a resource was lent twice or after it ended (#{describe(setup)})")
  end

  if count_of(stats, "peak") > setup.size + setup.max_overflow
    return error("#{count_of(stats, "peak")} resources in use at once (#{describe(setup)})")
  end

  try settle("resources in use", stats, "holders")
  try settle("callers in line", pool.counts, WAITING)
  deadline = Time.monotonic_ms() + SETTLE_MS
  while count_of(stats, "made") != count_of(stats, "terminated") and Time.monotonic_ms() < deadline
    Task.sleep(POLL_MS)
  end

  if count_of(stats, "made") != count_of(stats, "terminated")
    return error(
      "#{count_of(stats, "made")} resources made, #{count_of(stats, "terminated")} ended (#{describe(setup)})",
    )
  end

  return ok()
end

def settle(what: String, counts: ATS[String, Int], name: String) -> Result[Void]
  deadline = Time.monotonic_ms() + SETTLE_MS
  while count_of(counts, name) != 0 and Time.monotonic_ms() < deadline
    Task.sleep(POLL_MS)
  end

  if count_of(counts, name) != 0
    return error("#{count_of(counts, name)} #{what} after the close, not 0")
  end

  return ok()
end
