## The program under test of the features: it holds one pool of fake resources and the jobs that use it, and runs the
## requests that `steps.agc` sends (`protocol.agc`), one JSON line in and one reply line out.
##
## A resource is a `Cell` with a number. The counters of the fake (`made`, `terminated`, `checkin_done`,
## `checkin_crashed`, `checkin_timed_out`, `pings`, `active`, `peak`) say what the pool did with its resources.

import Pool from "../pool"
import Protocol from "protocol"
import {Request} from "protocol"

# Gap after a job starts, so that its task is in line for a resource before the next request starts another.
JOB_GAP_MS = 40
WAIT_JOBS_MS = 10_000
POLL_MS = 20
HANG_MS = 60_000
LOOP_NAP_MS = 5
SETTING_NAMES = [
  "size", "max_overflow", "overflow_idle_ms", "checkout_ms", "lease_ms", "max_age_ms", "idle_ms", "max_waiting",
  "lazy", "health_ms", "keep_dirty", "bad_ping_id", "init_fails_from", "init_crashes_at", "slow_init_at",
  "slow_init_ms",
]

# The resource of the pool.
struct Cell
  id: Int
  fake: Fake
end

# The config of the pool: where to count, and how the fake resource misbehaves.
struct Fake
  stats: ATS[String, Int]
  keep_dirty: Bool
  bad_ping_id: Int
  init_fails_from: Int
  init_crashes_at: Int
  slow_init_at: Int
  slow_init_ms: Int
end

struct Driver
  stats: ATS[String, Int]
  finished: Channel[String]
  pool: Optional[Pool.Pool[Fake, Cell]]
  tasks: Map[String, Task[Void]]
  results: Map[String, String]
  order: List[String]
end

struct JobArgs
  pool: Pool.Pool[Fake, Cell]
  name: String
  kind: String
  ms: Int
  stats: ATS[String, Int]
  finished: Channel[String]
end

struct Handled
  driver: Driver
  reply: String
end

def main() -> Void
  stats: ATS[String, Int] = ATS.new()
  finished: Channel[String] = Channel.new(5_000)
  driver = Driver(stats: stats, finished: finished, pool: none, tasks: {}, results: {}, order: [])
  line = IO.gets
  while line.ok?
    handled = handle(driver, line.unwrap_or(""))
    driver = handled.driver
    puts(handled.reply.replace("\n", "\\n"))
    IO.flush()
    line = IO.gets
  end
end

def handle(driver: Driver, line: String) -> Handled
  case JSON.decode(line, Request)
    error(message) -> return Handled(driver: driver, reply: "bad request: #{message}")
    ok(req) -> return act(driver, req)
  end
end

def act(driver: Driver, req: Request) -> Handled
  case req.op
    "start" -> return start(driver, req)
    "start_fails" -> return start_fails(driver, req)
    "job" -> return start_job(driver, req)
    "flood" -> return flood(driver, req.number)
    "cancel_job" -> return cancel_job(driver, req.name)
    "wait_jobs" -> return wait_jobs(driver)
    "sleep" -> return slept(driver, req.number)
    "close" -> return close(driver, req.number)
    "expect_job" -> return expect_job(collect(driver), req)
    "expect_timeout" -> return expect_timeout(collect(driver), req.name)
    "expect_order" -> return expect_order(collect(driver), req.text)
    "expect_count" -> return expect_count(driver, req)
    _ -> return Handled(driver: driver, reply: "unknown op #{req.op.inspect}")
  end
end

def reply(driver: Driver, message: String) -> Handled
  return Handled(driver: driver, reply: message)
end

# The Spec of a request: the defaults of `Pool.Spec`, then the settings of the table.
def spec_of(driver: Driver, table: List[List[String]]) -> Result[Pool.Spec[Fake, Cell]]
  settings: Map[String, String] = {}
  for row in table.drop(1)
    if not SETTING_NAMES.include?(row[0])
      return error("unknown setting #{row[0].inspect}")
    end

    settings = settings.put(row[0], row[1])
  end

  fake = Fake(
    stats: driver.stats,
    keep_dirty: settings.get("keep_dirty", "false") == "true",
    bad_ping_id: try settings.get("bad_ping_id", "0").to_i,
    init_fails_from: try settings.get("init_fails_from", "0").to_i,
    init_crashes_at: try settings.get("init_crashes_at", "0").to_i,
    slow_init_at: try settings.get("slow_init_at", "0").to_i,
    slow_init_ms: try settings.get("slow_init_ms", "0").to_i,
  )

  base = Pool.Spec(config: fake, init: &make, checkin: &check_in, terminate: &end_it, ping: &ping)
  return ok(
    base.with(
      size: try settings.get("size", base.size.to_s).to_i,
      max_overflow: try settings.get("max_overflow", "0").to_i,
      overflow_idle_ms: try settings.get("overflow_idle_ms", base.overflow_idle_ms.to_s).to_i,
      checkout_ms: try settings.get("checkout_ms", base.checkout_ms.to_s).to_i,
      lease_ms: try settings.get("lease_ms", base.lease_ms.to_s).to_i,
      max_age_ms: try settings.get("max_age_ms", "0").to_i,
      idle_ms: try settings.get("idle_ms", "0").to_i,
      max_waiting: try settings.get("max_waiting", base.max_waiting.to_s).to_i,
      lazy: settings.get("lazy", "false") == "true",
      health_ms: try settings.get("health_ms", "0").to_i,
    ),
  )
end

def start(driver: Driver, req: Request) -> Handled
  case spec_of(driver, req.table)
    error(message) -> return reply(driver, message)
    ok(spec) ->
      case Pool.start(spec)
        error(message) -> return reply(driver, "the pool did not start: #{message}")
        ok(pool) -> return reply(with_pool(driver, pool), Protocol.OK)
      end
  end
end

def with_pool(driver: Driver, pool: Pool.Pool[Fake, Cell]) -> Driver
  return driver.with(pool: some(pool))
end

def start_fails(driver: Driver, req: Request) -> Handled
  case spec_of(driver, req.table)
    error(message) -> return reply(driver, message)
    ok(spec) ->
      case Pool.start(spec)
        ok(_) -> return reply(driver, "the pool started")
        error(message) -> return reply(driver, expected_prefix(message, req.text))
      end
  end
end

# `ok` when the text starts with what was expected, else the text, which shows as the actual line of the step.
def expected_prefix(text: String, expected: String) -> String
  if text.start_with?(expected)
    return Protocol.OK
  end

  return text
end

def start_job(driver: Driver, req: Request) -> Handled
  case driver.pool
    none -> return reply(driver, "no pool is started")
    some(pool) ->
      args = JobArgs(
        pool: pool,
        name: req.name,
        kind: req.kind,
        ms: req.number,
        stats: driver.stats,
        finished: driver.finished,
      )

      run_fn: Fn[JobArgs, Void] = &run_job
      task = Task.spawn(run_fn, args)
      Task.sleep(JOB_GAP_MS)
      return reply(driver.with(tasks: driver.tasks.put(req.name, task)), Protocol.OK)
  end
end

# Starts `count` callers at once that take a resource and give it back; they have no name, and `flood_failed` counts
# the ones that got an error.
def flood(driver: Driver, count: Int) -> Handled
  case driver.pool
    none -> return reply(driver, "no pool is started")
    some(pool) ->
      run_fn: Fn[JobArgs, Void] = &run_job
      tasks = driver.tasks
      for i in 1..count
        args = JobArgs(pool: pool, name: "", kind: "holds", ms: 0, stats: driver.stats, finished: driver.finished)
        tasks = tasks.put("flood #{i}", Task.spawn(run_fn, args))
      end

      Task.sleep(JOB_GAP_MS)
      return reply(driver.with(tasks: tasks), Protocol.OK)
  end
end

def cancel_job(driver: Driver, name: String) -> Handled
  case driver.tasks.get(name)
    none -> return reply(driver, "no job #{name.inspect}")
    some(task) ->
      Task.cancel(task)
      Task.sleep(JOB_GAP_MS)
      # Awaiting a cancelled task halts, so `wait_jobs` must not see it.
      return reply(driver.with(tasks: driver.tasks.delete(name)), Protocol.OK)
  end
end

def wait_jobs(driver: Driver) -> Handled
  for task in driver.tasks.values
    case Task.await(task, WAIT_JOBS_MS)
      Await.Done(_) -> next
      Await.TimedOut -> return reply(driver, "a job did not end within #{WAIT_JOBS_MS} ms")
    end
  end

  return reply(driver, Protocol.OK)
end

def slept(driver: Driver, ms: Int) -> Handled
  Task.sleep(ms)
  return reply(driver, Protocol.OK)
end

def close(driver: Driver, drain_ms: Int) -> Handled
  case driver.pool
    none -> return reply(driver, "no pool is started")
    some(pool) ->
      Pool.close(pool, drain_ms)
      return reply(driver, Protocol.OK)
  end
end

# Moves the jobs that ended from the channel to the results, in the order they ended.
def collect(driver: Driver) -> Driver
  current = driver
  while true
    case current.finished.recv(0)
      error(_) -> return current
      ok(line) ->
        words = line.split(" ")
        current = current.with(
          results: current.results.put(words[0], words.drop(1).join(" ")),
          order: current.order.push(words[0]),
        )
    end
  end

  return current
end

def expect_job(driver: Driver, req: Request) -> Handled
  case driver.results.get(req.name)
    none -> return reply(driver, "job #{req.name.inspect} has not ended")
    some(result) -> return reply(driver, expected_prefix(result, req.text))
  end
end

def expect_timeout(driver: Driver, name: String) -> Handled
  case driver.results.get(name)
    none -> return reply(driver, "job #{name.inspect} has not ended")
    some(result) ->
      message = result.split(" ").drop(1).join(" ")
      if result.start_with?("error ") and Pool.timeout?(message)
        return reply(driver, Protocol.OK)
      end

      return reply(driver, "not a pool timeout: #{result}")
  end
end

def expect_order(driver: Driver, expected: String) -> Handled
  return reply(driver, expected_prefix(driver.order.join(","), expected))
end

# Polls the counter every POLL_MS up to `wait` milliseconds: `is` wants the value exactly, `reaches` at least.
def expect_count(driver: Driver, req: Request) -> Handled
  deadline = Time.monotonic_ms() + req.wait
  value = driver.stats.get(req.name).unwrap_or(0)
  while not counted?(req, value) and Time.monotonic_ms() < deadline
    Task.sleep(POLL_MS)
    value = driver.stats.get(req.name).unwrap_or(0)
  end

  if counted?(req, value)
    return reply(driver, Protocol.OK)
  end

  return reply(driver, "the count #{req.name.inspect} is #{value}, not #{req.number}")
end

def counted?(req: Request, value: Int) -> Bool
  return value == req.number or (req.kind == "reaches" and value > req.number)
end

# The fake resource: a numbered cell that counts what the pool does with it.
def make(fake: Fake) -> Result[Cell]
  id = fake.stats.add("made", 1)
  if id == fake.slow_init_at
    Task.sleep(fake.slow_init_ms)
  end

  if id == fake.init_crashes_at
    return ok(Cell(id: "not a number".to_i!, fake: fake))
  end

  if fake.init_fails_from > 0 and id >= fake.init_fails_from
    return error("init failed for resource #{id}")
  end

  return ok(Cell(id: id, fake: fake))
end

# A cell is kept after a clean job; after a crash or a timeout only when the fake says so (`keep_dirty`).
def check_in(cell: Cell, outcome: Pool.Outcome) -> Result[Void]
  stats = cell.fake.stats
  case outcome
    Pool.Outcome.Done ->
      stats.add("checkin_done", 1)
      return ok()
    Pool.Outcome.Crashed -> stats.add("checkin_crashed", 1)
    Pool.Outcome.TimedOut -> stats.add("checkin_timed_out", 1)
  end

  if cell.fake.keep_dirty
    return ok()
  end

  return error("cell #{cell.id} is dirty")
end

def end_it(cell: Cell) -> Void
  cell.fake.stats.add("terminated", 1)
end

def ping(cell: Cell) -> Result[Void]
  cell.fake.stats.add("pings", 1)
  if cell.id == cell.fake.bad_ping_id
    return error("cell #{cell.id} does not answer")
  end

  return ok()
end

def run_job(args: JobArgs) -> Void
  if args.kind == "loops"
    return loop_job(args)
  end

  result = Pool.with(args.pool) do |cell| use(args, cell) end
  if args.name.empty?
    if not result.ok?
      args.stats.add("flood_failed", 1)
    end

    return
  end

  case result
    ok(id) -> args.finished.send("#{args.name} ok #{id}", 1_000)
    error(message) -> args.finished.send("#{args.name} error #{message}", 1_000)
  end
end

# A caller that takes a resource again and again for `ms` milliseconds, as a busy server does. `loop_failed` counts
# the errors.
def loop_job(args: JobArgs) -> Void
  deadline = Time.monotonic_ms() + args.ms
  while Time.monotonic_ms() < deadline
    result = Pool.with(args.pool) do |cell| nap(cell) end
    if not result.ok?
      args.stats.add("loop_failed", 1)
    end
  end

  args.finished.send("#{args.name} ok 0", 1_000)
end

def nap(cell: Cell) -> Result[Int]
  Task.sleep(LOOP_NAP_MS)
  return ok(cell.id)
end

# The body of a job: it holds the cell, crashes, fails or hangs. `peak` is the most cells in use at once; the `probe`
# jobs count in `probe_peak` instead, so that a check can ignore the jobs that came before them.
def use(args: JobArgs, cell: Cell) -> Result[Int]
  prefix = ""
  if args.kind == "probe"
    prefix = "probe_"
  end

  args.stats.add("body_ran", 1)
  active = args.stats.add("#{prefix}active", 1)
  if active > args.stats.get("#{prefix}peak").unwrap_or(0)
    args.stats.put("#{prefix}peak", active)
  end

  case args.kind
    "hangs" -> Task.sleep(HANG_MS)
    "crashes" ->
      args.stats.add("active", -1)
      return ok("not a number".to_i!)
    "fails" ->
      args.stats.add("active", -1)
      return error("the body failed")
    _ -> Task.sleep(args.ms)
  end

  args.stats.add("#{prefix}active", -1)
  return ok(cell.id)
end
