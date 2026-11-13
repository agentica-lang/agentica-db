## A pool of database connections (`Db.Pool`), on the generic pool of `pkg/pool/pool`. A web app opens the pool once,
## in `main`, and each request borrows a connection for the length of its work:
##
##     pool = DbPool.start(DbPool.Options(url: "postgres://...")).unwrap!
##     DbPool.with(pool) do |conn| Orm.find(conn, users, key) end
##
## The block gets a `Db.Connection`, so `Db`, `Orm` and `Migrate` work in it as they do on a connection of `Db.open`,
## and `Db.transaction(conn)` too. Callers wait in line when every connection is taken. The connection goes back to
## the pool when the block ends, whatever the block does:
##
## - A transaction the block left open is rolled back, so the next caller starts clean.
## - A block that crashes, or runs past `lease_ms`, costs its connection: the pool closes it and opens another. So does
##   a caller that is cancelled while it holds the connection: the block is cancelled with it, the connection is
##   interrupted (SQLite), closed and replaced.
## - A connection the block closed or lost, one that fails its rollback, and one that fails the health check are closed
##   and replaced the same way. A connection that was closed or lost while it was idle is not lent: the pool checks
##   `Db.connected?` before each block (no round trip) and gives the caller the next connection.
##
## Each connection is opened in a task of the pool of its own, which owns it: start the pool in a task that lives as
## long as the pool does, such as `main`.
##
## The size follows poolboy: `size` connections, and up to `max_overflow` more in a spike, ended after
## `overflow_idle_ms` of idleness. They are opened at the start (`lazy: false`), so a wrong url or a down server fails
## `start`. `timeout_ms` of the url bounds each statement, as on a connection of `Db.open` (see `Db`).
##
## The SQLite connections of a pool take turns at `Db.transaction`: a writer waits in line for the one before it to
## commit, in the order they came (a channel's waiters are served first come, first served), instead of trying its
## `BEGIN IMMEDIATE` again every few milliseconds. A writer waits for its turn up to `busy_timeout` and at most half
## of `lease_ms`; then its BEGIN takes SQLite's lock if it is free and fails with `sqlite error 5: database is locked`
## if not, as without the line. So a block that checks out a second connection inside its transaction and starts a
## transaction on it fails after that wait, as before. A block that crashes or runs past `lease_ms` in its
## transaction gives the turn back when its connection is checked in.
##
## A pool of a SQLite file in WAL mode on the native driver takes the checkpoints of the WAL off the writers. Its
## connections run with SQLite's autocheckpoint off, which would copy the WAL into the database inside a COMMIT, now
## and then for many milliseconds while the writer holds the turn. A checkpointer task with a connection of its own
## runs a PASSIVE checkpoint on the compute pool when a commit leaves `checkpoint_frames` frames in the WAL that no
## checkpoint has copied, and every `checkpoint_ms`. A commit that leaves `checkpoint_cap` such frames checkpoints at
## once on its own connection, so the WAL stays near the cap when the checkpointer lags, as long as no reader holds an
## older snapshot (a PASSIVE checkpoint, like SQLite's own, cannot copy past it). A COMMIT then never checkpoints, and
## runs in a short call on the scheduler after the cheap writes of its transaction (see `sqlite/sqlite.agc`), except
## while a checkpoint runs and for the transaction after one that copied the whole WAL, whose commit starts the WAL
## again and syncs it. `close` stops the checkpointer. With the FFI driver, or `checkpoint_frames` 0, each connection
## checkpoints as SQLite does by itself.

import Db from "db"
import P from "pkg/pool/pool"
import Sqlite from "sqlite/sqlite"

## A pool of connections.
type Pool = P.Pool[Config, Db.Connection]

## How to open a pool. `url` is anything `Db.open` takes. `size` 0 takes the size of the database: 4 for SQLite (1 for
## a private in-memory database), 10 for PostgreSQL and MySQL. The other fields are the ones of the generic pool (see
## the Connection pool guide): `checkout_ms` is how long a caller waits for a connection and `lease_ms` how long a
## block may run, both in milliseconds (`lease_ms` 0 runs the block in the caller with no limit: a crash in it is the
## caller's own, and the check-in after it is not bounded); `max_age_ms` closes a connection that old and `idle_ms` one
## unused that long (it needs `lazy`), 0 turns each off; `health_ms` is the interval of the health check that pings the
## idle connections and applies those two (0 turns the check off, and then `max_age_ms` and `idle_ms` must be 0);
## `max_waiting` is how many callers may wait in line for a connection at once (0 or more; 0 lets nobody wait, so a
## caller that finds every connection busy is refused at once).
##
## The last three are the checkpoints of a SQLite file in WAL mode (see the top of this file): a commit that leaves
## `checkpoint_frames` frames (pages) in the WAL that no checkpoint has copied wakes the checkpointer, which also runs
## every `checkpoint_ms`, and a commit that leaves `checkpoint_cap` such frames checkpoints itself (0: four times
## `checkpoint_frames`). A
## `checkpoint_frames` of 0 leaves the checkpoints to SQLite (its autocheckpoint, at 1000 frames, inside a COMMIT).
struct Options
  url: String
  size: Int = 0
  max_overflow: Int = 0
  overflow_idle_ms: Int = 1_000
  checkout_ms: Int = 5_000
  lease_ms: Int = 30_000
  max_age_ms: Int = 0
  idle_ms: Int = 0
  max_waiting: Int = 1_000
  lazy: Bool = false
  health_ms: Int = 5_000
  checkpoint_frames: Int = 1_000
  checkpoint_ms: Int = 1_000
  checkpoint_cap: Int = 0
end

## Opens the connections and starts the pool. A url that does not open, or a pool that is not valid (a `size` below 1),
## is an `error`; so is more than one connection to a private in-memory SQLite database (`sqlite::memory:`,
## `sqlite:file::memory:`, a `file:` name with `mode=memory`), each of which would be an empty database of its
## own. With `cache=shared` in the name the database is one to all, and the size is free. A checkpoint option below
## 0, or a `checkpoint_ms` of 0, is an error too, and so is a negative `max_waiting`.
def start(options: Options) -> Result[Pool]
  size = options.size
  if size == 0
    size = default_size(options.url)
  end

  if private_memory?(options.url) and size + options.max_overflow > 1
    return error("db error: a pool of a private in-memory database can have one connection only: each is its own")
  end

  try check_checkpoints(options)
  gate: Channel[Int] = Channel.new(1)
  _ = gate.send(1, 0)
  checkpointer = start_checkpointer(options)
  spec = P.Spec(
    config: Config(url: options.url, gate: gate, lease_ms: options.lease_ms, checkpointer: checkpointer),
    init: &connect,
    checkin: &check_in,
    checkout: some(&lendable),
    terminate: &Db.close,
    ping: &ping,
    size: size,
    max_overflow: options.max_overflow,
    overflow_idle_ms: options.overflow_idle_ms,
    checkout_ms: options.checkout_ms,
    lease_ms: options.lease_ms,
    max_age_ms: options.max_age_ms,
    idle_ms: options.idle_ms,
    max_waiting: options.max_waiting,
    lazy: options.lazy,
    health_ms: options.health_ms,
  )

  started = P.start(spec)
  if not started.ok?
    stop_checkpointer(checkpointer)
  end

  started
end

## Runs the block with a connection of the pool and gives its result. The block runs in a task of the pool: a crash in
## it is an `error` here (with `lease_ms` 0 it runs in the caller, and a crash is the caller's own). A caller that
## finds no free connection waits up to `checkout_ms`, then gets `pool error: checkout timed out after N ms`; a block
## that runs past `lease_ms` gets `pool error: lease timed out after N ms`; more than `max_waiting` callers in line
## get `pool error: queue full (max_waiting N)`; a closed pool gives `pool error: closed`. The errors have kinds
## (`pool.timeout.checkout`, `pool.timeout.lease`, `pool.full`, `pool.closed`). The connection is checked in after the
## block (see the top of this file). Cancelling the caller cancels the block, and its connection is interrupted,
## closed and replaced; `lease_ms` bounds the block too.
def with[R](pool: Pool, body: Fn[Db.Connection, Result[R]]) -> Result[R] = P.with(pool, body)

## Refuses new callers, lets the blocks that run and the callers in line finish for up to `drain_ms`, fails the rest
## with `pool error: closed`, closes every connection and stops the pool, then its checkpointer, which ends its
## checkpoint, if one runs, and closes its connection before `close` returns.
def close(pool: Pool, drain_ms: Int) -> Void
  P.close(pool, drain_ms)
  stop_checkpointer(pool.spec.config.checkpointer)
end

## True for a failure that ran out of time: a caller that waited too long for a connection or a block that ran too
## long (`pool error: ... timed out`), and a statement that ran over its `timeout_ms` (`Db.timeout?`).
def timeout?(message: String) -> Bool = P.timeout?(message) or Db.timeout?(message)

## The size of a pool for a url when `Options.size` is 0.
def default_size(url: String) -> Int
  return MEMORY_SIZE if private_memory?(url)

  return SQLITE_SIZE if url.start_with?(SQLITE_PREFIX)

  SERVER_SIZE
end

private

SQLITE_PREFIX = "sqlite:"
SQLITE_URI_PREFIX = "sqlite:file:"
SQLITE_MEMORY = "sqlite::memory:"
SQLITE_SIZE = 4
SERVER_SIZE = 10
# Every connection of a private in-memory database is a database of its own.
MEMORY_SIZE = 1
# A `checkpoint_cap` of 0 is this many times `checkpoint_frames`.
CAP_FACTOR = 4

# What each connection of the pool is opened with: the url, and the line that the SQLite writers of the pool share
# (`gate` holds one token) with the lease of a block, which bounds the wait in it, and the checkpointer of a
# SQLite file.
struct Config
  url: String
  gate: Channel[Int]
  lease_ms: Int
  checkpointer: Optional[Checkpointer]
end

# The task that checkpoints the WAL of the pool's database, and how the commits of the pool reach it (`plan.nudge`).
struct Checkpointer
  plan: Sqlite.Checkpoints
  task: Task[Result[Void]]
end

# What the checkpointer task needs: the url of its own connection, the checkpoints of the pool (`plan.nudge` wakes it,
# and closed stops it), and the time between two checkpoints when nothing wakes it.
struct Watch
  url: String
  plan: Sqlite.Checkpoints
  every_ms: Int
end

# A SQLite url whose database lives in the connection: `sqlite::memory:`, or a `file:` name that is `:memory:` or has
# `mode=memory`, unless `cache=shared` makes it one database for every connection of the process.
def private_memory?(url: String) -> Bool
  return true if url.start_with?(SQLITE_MEMORY)

  return false if not url.start_with?(SQLITE_URI_PREFIX) or url.include?("cache=shared")

  url.include?(":memory:") or url.include?("mode=memory")
end

def connect(config: Config) -> Result[Db.Connection]
  conn = try Db.open(config.url)
  case conn
    Db.Connection.Sqlite(sqlite) ->
      ok(Db.Connection.Sqlite(own_checkpoints(Sqlite.with_gate(sqlite, config.gate, config.lease_ms), config)))
    _ -> ok(conn)
  end
end

def own_checkpoints(sqlite: Sqlite.Connection, config: Config) -> Sqlite.Connection
  case config.checkpointer
    some(checkpointer) -> Sqlite.own_checkpoints(sqlite, checkpointer.plan)
    none -> sqlite
  end
end

def check_checkpoints(options: Options) -> Result[Void]
  if options.checkpoint_frames < 0
    return error("db error: checkpoint_frames must be 0 or more, got #{options.checkpoint_frames}")
  end

  if options.checkpoint_cap < 0
    return error("db error: checkpoint_cap must be 0 or more, got #{options.checkpoint_cap}")
  end

  return error("db error: checkpoint_ms must be 1 or more, got #{options.checkpoint_ms}") if options.checkpoint_ms < 1

  ok()
end

# The checkpointer of a pool of a SQLite file, none for any other url or with `checkpoint_frames` 0. It starts before
# the connections, so that none of them runs without it.
def start_checkpointer(options: Options) -> Optional[Checkpointer]
  return none if options.checkpoint_frames == 0 or not sqlite_file?(options.url)

  cap = options.checkpoint_cap
  if cap == 0
    cap = options.checkpoint_frames * CAP_FACTOR
  end

  nudge: Channel[Int] = Channel.new(1)
  case Sqlite.checkpoints(nudge, options.checkpoint_frames, cap)
    none -> none
    some(plan) ->
      task = Task.spawn(&checkpoints, Watch(url: options.url, plan: plan, every_ms: options.checkpoint_ms))
      some(Checkpointer(plan: plan, task: task))
  end
end

# Closing the channel stops the task at its next wake-up, after the checkpoint that runs, if any; it closes its
# connection before it ends.
def stop_checkpointer(checkpointer: Optional[Checkpointer]) -> Void
  case checkpointer
    none -> return
    some(running) ->
      running.plan.nudge.close
      _ = Task.await(running.task)
  end
end

# The checkpointer task: a PASSIVE checkpoint on a connection of its own (the compute pool runs it) each time a commit
# wakes it, and every `every_ms`, until the channel closes. A connection that the pool cannot checkpoint (the FFI
# driver, not WAL) ends it at once, and so does one that does not open: the commits then checkpoint at the cap.
def checkpoints(watch: Watch) -> Result[Void]
  conn = try Db.open(watch.url)
  case conn
    Db.Connection.Sqlite(sqlite) if Sqlite.checkpointable?(sqlite) -> checkpoint_loop(sqlite, watch)
    _ -> return close_with(conn)
  end

  close_with(conn)
end

def checkpoint_loop(sqlite: Sqlite.Connection, watch: Watch) -> Void
  while true
    _ = watch.plan.nudge.recv(watch.every_ms)
    return if watch.plan.nudge.closed?

    Sqlite.checkpoint(sqlite, watch.plan)
  end
end

def close_with(conn: Db.Connection) -> Result[Void]
  Db.close(conn)
  ok()
end

# A SQLite url of a file: not a private in-memory database, nor a shared one (`mode=memory`, `:memory:`).
def sqlite_file?(url: String) -> Bool
  return false if not url.start_with?(SQLITE_PREFIX) or private_memory?(url)

  not url.include?(":memory:") and not url.include?("mode=memory")
end

# Gets a connection back after a block. A connection the block closed or lost is not reused (`Db.connected?`, no round
# trip). A transaction the block left open is rolled back (`Db.in_transaction?` reads the state of the connection, no
# round trip), and a connection that is still in one after that is not reused. A crashed block ends its connection
# after a rollback that may fail, since the connection is closed anyway. A block that timed out may still be running
# its statement: on SQLite it is interrupted, so that closing the connection does not wait for it, and nobody touches
# the connection but the pool, which closes it. The other databases keep running the statement until their own limit
# (`timeout_ms` of the url): set it under `lease_ms`.
def check_in(conn: Db.Connection, outcome: P.Outcome) -> Result[Void]
  case outcome
    P.Outcome.TimedOut ->
      interrupt(conn)
      reopen_gate(conn)
      error("db pool: the block ran past lease_ms")
    P.Outcome.Crashed ->
      _ = roll_back(conn)
      reopen_gate(conn)
      error("db pool: the block crashed")
    P.Outcome.Done -> reset(conn)
  end
end

# The check before a block: a connection that the server or a block closed while it was idle is not lent again.
def lendable(conn: Db.Connection) -> Result[Void]
  return ok() if Db.connected?(conn)

  error("db pool: the connection is closed or lost")
end

def reset(conn: Db.Connection) -> Result[Void]
  return error("db pool: the block closed or lost the connection") if not Db.connected?(conn)

  try roll_back(conn)
  return error("db pool: the connection is still in a transaction after a rollback") if Db.in_transaction?(conn)

  ok()
end

def roll_back(conn: Db.Connection) -> Result[Void]
  return ok() if not Db.connected?(conn) or not Db.in_transaction?(conn)

  try Db.execute(conn, "ROLLBACK", [])
  ok()
end

def interrupt(conn: Db.Connection) -> Void
  case conn
    Db.Connection.Sqlite(handle) -> Sqlite.interrupt(handle)
    _ -> return
  end
end

# A block that ended inside Db.transaction may hold the turn of the writers, which it will never give back: it goes
# back now. Only the connection that holds the turn gives it (Sqlite.leave_gate), so a block that waited in vain, or
# never reached its transaction, adds no token.
def reopen_gate(conn: Db.Connection) -> Void
  case conn
    Db.Connection.Sqlite(handle) -> Sqlite.leave_gate(handle)
    _ -> return
  end
end

def ping(conn: Db.Connection) -> Result[Void]
  return ok() if Db.healthy?(conn)

  error("db pool: the connection is not healthy")
end
