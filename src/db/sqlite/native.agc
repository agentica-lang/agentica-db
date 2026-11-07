## The native driver of the SQLite adapter: the module of `native/db_sqlite.c` (`[native.db_sqlite]` of
## `agentica.toml`), which Agentica builds at the first run or compile of a program, a fetched package too. A
## connection keeps its prepared statements in a cache keyed by the sql text, so a statement it ran before is not
## prepared again. A read of a cached statement runs whole in one short call when it is small (`Fetch.quick_steps`,
## `quick_rows`); any other statement runs on the compute pool, one call per batch of rows. A lock comes back at once,
## and the wait is made here.

import SqliteWait from "wait"
import {Row, Value} from "../support/value"

SQLITE_ROW = 100
SQLITE_DONE = 101
# What a read may do in a short call on the scheduler: SQLite VM instructions (about 100 microseconds of work) and
# rows. A longer one goes to the compute pool, run again from its start.
QUICK_STEPS = 10_000
QUICK_ROWS = 100

## What a call may give at once: up to `rows` rows or about `bytes` bytes of values; a longer result takes more calls.
## `keep` is false for `execute`, whose rows are stepped over, and `cache` false for a statement that runs once. A
## cached read runs in a short call when it takes at most `quick_steps` SQLite VM instructions and gives at most
## `quick_rows` rows (0: never).
export struct Fetch
  keep: Bool = true
  cache: Bool = true
  rows: Int = 1000
  bytes: Int = 4_194_304
  quick_rows: Int = QUICK_ROWS
  quick_steps: Int = QUICK_STEPS
end

# One call's part of a statement. `code` is SQLITE_ROW when more rows follow, SQLITE_DONE at the end, else the code of
# the failure, whose text is `failure`. `upgrade` is a write refused because this connection holds a read lock, which
# is not waited for. `changes` is the count of the statement at SQLITE_DONE.
struct Batch
  code: Int
  extended: Int
  upgrade: Bool
  readonly: Bool
  failure: String
  rows: List[Row]
  changes: Int
end

## What the statement cache of a connection holds (`size` of `capacity`) and how it was used: a `hit` ran a cached
## statement, a `miss` prepared one, an `eviction` finalized the one used least long ago to make room.
export struct CacheStats
  size: Int
  capacity: Int
  hits: Int
  misses: Int
  evictions: Int
end

# The rows and the count of changes of a statement that ran to its end.
struct Done
  rows: List[Row]
  changes: Int
end

extern module "db_sqlite"
  ## A connection; `Native.close` finalizes its cached statements and closes it.
  export resource Conn
  ## Stops the statement that runs on the connection, which then fails with `sqlite error 9: interrupted`.
  export def interrupt(conn: Conn) -> Void
  ## Whether no transaction is open.
  export def autocommit?(conn: Conn) -> Bool
  export def cache_stats(conn: Conn) -> CacheStats
end

## Whether the module opens: false where the built library does not load, and the FFI driver runs.
export def available?() -> Bool
  return Native.load("db_sqlite").ok?
end

## Opens a database with `flags` (of `sqlite3_open_v2`) and a cache of `cache` statements (0: none).
export def open(path: String, flags: Int, cache: Int) -> Result[Conn]
  return connect(path, flags, cache)
end

## Runs one statement and gives its rows.
export def query(
  conn: Conn,
  wait: SqliteWait.Wait,
  sql: String,
  params: List[Value],
  options: Fetch,
) -> Result[List[Row]]
  if SqliteWait.expired?(wait)
    return error(SqliteWait.INTERRUPTED)
  end

  if options.quick_steps > 0
    case quick(conn, sql, params, options)
      some(batch) -> return rows_of(batch)
      none -> return all_rows(conn, wait, sql, params, options)
    end
  end

  return all_rows(conn, wait, sql, params, options)
end

## Ends what a cancelled query left on the connection: a statement that a lock stopped holds a write that SQLite never
## ended, which keeps the connection in a hidden transaction until it is reset. Every fetch does it first; the adapter
## does it before it reads whether a transaction is open.
export def settle(conn: Conn) -> Void
  if pending?(conn)
    tidy(conn)
  end
end

## Runs one statement for its effect and gives the number of rows it inserted, updated or deleted.
export def execute(conn: Conn, wait: SqliteWait.Wait, sql: String, params: List[Value], options: Fetch) -> Result[Int]
  if SqliteWait.expired?(wait)
    return error(SqliteWait.INTERRUPTED)
  end

  done = try run(conn, wait, sql, params, options.with(keep: false, quick_steps: 0))
  return ok(done.changes)
end

# The calls that only this file makes. A Cursor holds the statement of one query between its fetch calls; the last
# fetch gives the statement back to the cache, and so does `finish` for a query that stops at a lock (on the compute
# pool: the reset waits for SQLite's mutex) or closing the cursor (the end of the task, for one that was cancelled).
extern module "db_sqlite"
  resource Cursor
  compute def connect(path: String, flags: Int, cache: Int) -> Result[Conn]
  def cursor(conn: Conn) -> Cursor
  compute def fetch(conn: Conn, cursor: Cursor, sql: String, params: List[Value], options: Fetch) -> Batch
  compute def finish(conn: Conn, cursor: Cursor) -> Void
  def pending?(conn: Conn) -> Bool
  compute def tidy(conn: Conn) -> Void
  def quick(conn: Conn, sql: String, params: List[Value], options: Fetch) -> Optional[Batch]
end

def all_rows(conn: Conn, wait: SqliteWait.Wait, sql: String, params: List[Value], options: Fetch) -> Result[List[Row]]
  done = try run(conn, wait, sql, params, options)
  return ok(done.rows)
end

def rows_of(batch: Batch) -> Result[List[Row]]
  if batch.code == SQLITE_DONE
    return ok(batch.rows)
  end

  return error(batch.failure)
end

# The batches of the statement until its end. A lock is waited for here and the statement fetched again, which steps
# it again. SQLite rolls a write back and runs it again after a lock (a commit refused in a rollback journal), so the
# rows that a write gave before the wait are dropped; a read goes on from where it stopped.
def run(conn: Conn, wait: SqliteWait.Wait, sql: String, params: List[Value], options: Fetch) -> Result[Done]
  cur = cursor(conn)
  rows: List[Row] = []
  started = 0
  waited = false
  while true
    batch = fetch(conn, cur, sql, params, options)
    if waited and not batch.readonly
      rows = batch.rows
    else
      rows = rows.concat(batch.rows)
    end

    waited = false
    if batch.code == SQLITE_DONE
      Native.close(cur)
      return ok(Done(rows: rows, changes: batch.changes))
    elsif batch.code == SQLITE_ROW
      started = 0
    else
      if started == 0
        started = Time.monotonic_ms()
      end

      if batch.upgrade or not SqliteWait.lock_wait?(wait, batch.code, batch.extended, started)
        # Only a lock leaves the statement with the cursor; fetch gave back any other.
        if SqliteWait.lock_code?(batch.code)
          finish(conn, cur)
        end

        Native.close(cur)
        return error(batch.failure)
      end

      SqliteWait.pause(wait, started)
      waited = true
    end
  end

  Native.close(cur)
  return ok(Done(rows: rows, changes: 0))
end
