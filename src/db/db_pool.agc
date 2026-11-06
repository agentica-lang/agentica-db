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
## - A block that crashes, or runs past `lease_ms`, costs its connection: the pool closes it and opens another.
## - A connection the block closed or lost, one that fails its rollback, and one that fails the health check are closed
##   and replaced the same way.
##
## The connections are opened in the task that started the pool, which owns them: start the pool in a task that lives
## as long as it does, such as `main`.
##
## The size follows poolboy: `size` connections, and up to `max_overflow` more in a spike, ended after
## `overflow_idle_ms` of idleness. They are opened at the start (`lazy: false`), so a wrong url or a down server fails
## `start`. `timeout_ms` of the url bounds each statement, as on a connection of `Db.open` (see `Db`).

import Db from "db"
import P from "pkg/pool/pool"
import Sqlite from "sqlite/sqlite"

SQLITE_PREFIX = "sqlite:"
SQLITE_URI_PREFIX = "sqlite:file:"
SQLITE_MEMORY = "sqlite::memory:"
SQLITE_SIZE = 4
SERVER_SIZE = 10
# Every connection of a private in-memory database is a database of its own.
MEMORY_SIZE = 1

## A pool of connections.
export type Pool = P.Pool[String, Db.Connection]

## How to open a pool. `url` is anything `Db.open` takes. `size` 0 takes the size of the database: 4 for SQLite (1 for
## a private in-memory database), 10 for PostgreSQL and MySQL. The other fields are the ones of the generic pool (see
## the Connection pool guide): `checkout_ms` is how long a caller waits for a connection and `lease_ms` how long a
## block may run, both in milliseconds; `max_age_ms` closes a connection that old and `idle_ms` one unused that long
## (it needs `lazy`), 0 turns each off; `health_ms` is the interval of the health check that pings the idle connections
## and applies those two (0 turns the check off, and then `max_age_ms` and `idle_ms` must be 0).
export struct Options
  url: String
  size: Int = 0
  max_overflow: Int = 0
  overflow_idle_ms: Int = 1_000
  checkout_ms: Int = 5_000
  lease_ms: Int = 30_000
  max_age_ms: Int = 0
  idle_ms: Int = 0
  lazy: Bool = false
  health_ms: Int = 5_000
end

## Opens the connections and starts the pool. A url that does not open, or a pool that is not valid (a `size` below 1),
## is an `error`; so is more than one connection to a private in-memory SQLite database (`sqlite::memory:`,
## `sqlite:file::memory:`, a `file:` name with `mode=memory`), each of which would be an empty database of its
## own. With `cache=shared` in the name the database is one to all, and the size is free.
export def start(options: Options) -> Result[Pool]
  size = options.size
  if size == 0
    size = default_size(options.url)
  end

  if private_memory?(options.url) and size + options.max_overflow > 1
    return error("db error: a pool of a private in-memory database can have one connection only: each is its own")
  end

  spec = P.Spec(
    config: options.url,
    init: &connect,
    checkin: &check_in,
    terminate: &Db.close,
    ping: &ping,
    size: size,
    max_overflow: options.max_overflow,
    overflow_idle_ms: options.overflow_idle_ms,
    checkout_ms: options.checkout_ms,
    lease_ms: options.lease_ms,
    max_age_ms: options.max_age_ms,
    idle_ms: options.idle_ms,
    lazy: options.lazy,
    health_ms: options.health_ms,
  )

  return P.start(spec)
end

## Runs the block with a connection of the pool and gives its result. The block runs in a task of the pool: a crash in
## it is an `error` here. A caller that finds no free connection waits up to `checkout_ms`, then gets `pool error:
## checkout timed out after N ms`; a block that runs past `lease_ms` gets `pool error: lease timed out after N ms`;
## more than 1000 callers in line get `pool error: queue full`; a closed pool gives `pool error: closed`. The
## connection is checked in after the block (see the top of this file). Cancelling the caller does not cancel the
## block; `lease_ms` bounds it.
export def with[R](pool: Pool, body: Fn[Db.Connection, Result[R]]) -> Result[R]
  return P.with(pool, body)
end

## Refuses new callers, lets the blocks that run and the callers in line finish for up to `drain_ms`, fails the rest
## with `pool error: closed`, closes every connection and stops the pool.
export def close(pool: Pool, drain_ms: Int) -> Void
  P.close(pool, drain_ms)
end

## True for a failure that ran out of time: a caller that waited too long for a connection or a block that ran too
## long (`pool error: ... timed out`), and a statement that ran over its `timeout_ms` (`Db.timeout?`).
export def timeout?(message: String) -> Bool
  return P.timeout?(message) or Db.timeout?(message)
end

## The size of a pool for a url when `Options.size` is 0.
export def default_size(url: String) -> Int
  if private_memory?(url)
    return MEMORY_SIZE
  end

  if url.start_with?(SQLITE_PREFIX)
    return SQLITE_SIZE
  end

  return SERVER_SIZE
end

# A SQLite url whose database lives in the connection: `sqlite::memory:`, or a `file:` name that is `:memory:` or has
# `mode=memory`, unless `cache=shared` makes it one database for every connection of the process.
def private_memory?(url: String) -> Bool
  if url.start_with?(SQLITE_MEMORY)
    return true
  end

  if not url.start_with?(SQLITE_URI_PREFIX) or url.include?("cache=shared")
    return false
  end

  return url.include?(":memory:") or url.include?("mode=memory")
end

def connect(url: String) -> Result[Db.Connection]
  return Db.open_pooled(url)
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
      return error("db pool: the block ran past lease_ms")
    P.Outcome.Crashed ->
      _ = roll_back(conn)
      return error("db pool: the block crashed")
    P.Outcome.Done -> return reset(conn)
  end
end

def reset(conn: Db.Connection) -> Result[Void]
  if not Db.connected?(conn)
    return error("db pool: the block closed or lost the connection")
  end

  try roll_back(conn)
  if Db.in_transaction?(conn)
    return error("db pool: the connection is still in a transaction after a rollback")
  end

  return ok()
end

def roll_back(conn: Db.Connection) -> Result[Void]
  if not Db.connected?(conn) or not Db.in_transaction?(conn)
    return ok()
  end

  try Db.execute(conn, "ROLLBACK", [])
  return ok()
end

def interrupt(conn: Db.Connection) -> Void
  case conn
    Db.Connection.Sqlite(handle) -> Sqlite.interrupt(handle)
    _ -> return
  end
end

def ping(conn: Db.Connection) -> Result[Void]
  if Db.healthy?(conn)
    return ok()
  end

  return error("db pool: the connection is not healthy")
end
