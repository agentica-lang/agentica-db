## The native driver of the SQLite adapter: the module of `native/db_sqlite.c` (`[native.db_sqlite]` of
## `agentica.toml`), which Agentica builds at the first run or compile of a program, a fetched package too. A
## connection keeps its prepared statements in a cache keyed by the sql text, so a statement it ran before is not
## prepared again. A read of a cached statement runs whole in one short call when it is small (`Fetch.quick_steps`,
## `quick_rows`), and so does a cached write whose plan bounds its work, once `inline_writes` allows it (the top of
## `native/db_sqlite.c` says when); any other statement runs on the compute pool, one call per batch of rows. A lock
## comes back at once, and the wait is made here.

import SqliteWait from "wait"
import {Row, Value} from "../support/value"

## What a call may give at once: up to `rows` rows or about `bytes` bytes of values; a longer result takes more calls.
## `keep` is false for `execute`, whose rows are stepped over, and `cache` false for a statement that runs once. A
## cached read runs in a short call when it takes at most `quick_steps` SQLite VM instructions and gives at most
## `quick_rows` rows (0: never).
struct Fetch
  keep: Bool = true
  cache: Bool = true
  rows: Int = 1000
  bytes: Int = 4_194_304
  quick_rows: Int = QUICK_ROWS
  quick_steps: Int = QUICK_STEPS
end

## What the statement cache of a connection holds (`size` of `capacity`) and how it was used: a `hit` ran a cached
## statement, a `miss` prepared one, an `eviction` finalized the one used least long ago to make room, `shorts`
## counts the statements that ran whole in a short call on the scheduler, and `fallbacks` the short calls that took a
## statement and then left it to the compute pool: its bound data too big (before it ran), or a lock, a value too
## long or rows past the caps (while it ran).
struct CacheStats
  size: Int
  capacity: Int
  hits: Int
  misses: Int
  evictions: Int
  shorts: Int
  fallbacks: Int
end

## The rows and the count of changes of a statement that ran to its end, and the frames in the WAL that no checkpoint
## has copied after its commit (0 when it did not commit, or the pool does not take the checkpoints of the connection).
struct Done
  rows: List[Row]
  changes: Int
  frames: Int
end

extern module "db_sqlite"
  ## A connection; `Native.close` finalizes its cached statements and closes it.
  resource Conn
  ## Stops the statement that runs on the connection, which then fails with `sqlite error 9: interrupted`.
  def interrupt(conn: Conn) -> Void
  ## Whether no transaction is open.
  def autocommit?(conn: Conn) -> Bool
  def cache_stats(conn: Conn) -> CacheStats
  ## Lets a short call run the cheap writes and the BEGIN of a transaction (a WAL database only), and with `commits`
  ## a write that commits too (only after `own_checkpoints`, and where a commit does not sync the WAL).
  def inline_writes(conn: Conn, commits: Bool) -> Void
  ## What the connections of a pool share about their WAL: whether a checkpoint runs, or the next write to the WAL
  ## starts it again, which syncs it; no connection writes in a short call meanwhile.
  resource Wal
  def wal() -> Wal
  ## Turns SQLite's autocheckpoint off for the connection: its pool takes the checkpoints of the WAL that it shares in
  ## `wal`, and each commit gives the frames in the WAL that no checkpoint has copied (`Done.frames`).
  compute def own_checkpoints(conn: Conn, wal: Wal) -> Void
  ## A PASSIVE checkpoint of the WAL shared in `wal`: it copies what no reader needs and waits for nobody.
  compute def checkpoint(conn: Conn, wal: Wal) -> Void
end

## Whether the module opens: false where the built library does not load, and the FFI driver runs.
def available?() -> Bool = Native.load("db_sqlite").ok?

## Opens a database with `flags` (of `sqlite3_open_v2`) and a cache of `cache` statements (0: none).
def open(path: String, flags: Int, cache: Int) -> Result[Conn] = connect(path, flags, cache)

## Runs one statement and gives its rows.
def query(conn: Conn, wait: SqliteWait.Wait, sql: String, params: List[Value], options: Fetch) -> Result[Done]
  return error(SqliteWait.INTERRUPTED) if SqliteWait.expired?(wait)

  run_short(conn, wait, sql, params, options)
end

## Ends what a cancelled query left on the connection: a write stopped before its end, which SQLite counts as running,
## keeps the connection in a hidden transaction until it is reset. Every fetch does it first; the adapter
## does it before it reads whether a transaction is open.
def settle(conn: Conn) -> Void
  if pending?(conn)
    tidy(conn)
  end
end

## Runs one statement for its effect: its rows are stepped over, and `Done.changes` is the number of rows it inserted,
## updated or deleted.
def execute(conn: Conn, wait: SqliteWait.Wait, sql: String, params: List[Value], options: Fetch) -> Result[Done]
  return error(SqliteWait.INTERRUPTED) if SqliteWait.expired?(wait)

  run_short(conn, wait, sql, params, options.with(keep: false))
end

private

SQLITE_ROW = 100
SQLITE_DONE = 101
# What a read may do in a short call on the scheduler: SQLite VM instructions (about 100 microseconds of work) and
# rows. A longer one goes to the compute pool, run again from its start.
QUICK_STEPS = 10_000
QUICK_ROWS = 100

# One call's part of a statement. `code` is SQLITE_ROW when more rows follow, SQLITE_DONE at the end, else the code of
# the failure, whose text is `failure`. `upgrade` is a write refused because this connection holds a read lock, which
# is not waited for. `changes` is the count of the statement at SQLITE_DONE, and `frames` the frames in the WAL that no
# checkpoint has copied after a commit of this call, on a connection whose pool takes its checkpoints
# (`own_checkpoints`; else 0).
struct Batch
  code: Int
  extended: Int
  upgrade: Bool
  readonly: Bool
  failure: String
  rows: List[Row]
  changes: Int
  frames: Int
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

# The statement in one short call when the module can run it there, else on the compute pool.
def run_short(conn: Conn, wait: SqliteWait.Wait, sql: String, params: List[Value], options: Fetch) -> Result[Done]
  if options.quick_steps > 0
    case quick(conn, sql, params, options)
      some(batch) -> return done_of(batch)
      none -> return run(conn, wait, sql, params, options)
    end
  end

  run(conn, wait, sql, params, options)
end

def done_of(batch: Batch) -> Result[Done]
  return ok(Done(rows: batch.rows, changes: batch.changes, frames: batch.frames)) if batch.code == SQLITE_DONE

  error(batch.failure)
end

# The batches of the statement until its end. A lock is waited for here and the statement fetched again, which steps
# it again. SQLite rolls a write back and runs it again after a lock (a commit refused in a rollback journal), so the
# rows that a write gave before the wait are dropped; a read goes on from where it stopped.
def run(conn: Conn, wait: SqliteWait.Wait, sql: String, params: List[Value], options: Fetch) -> Result[Done]
  cur = cursor(conn)
  rows: List[Row] = []
  started = 0
  frames = 0
  waited = false
  while true
    batch = fetch(conn, cur, sql, params, options)
    if batch.frames > frames
      frames = batch.frames
    end

    if waited and not batch.readonly
      rows = batch.rows
    else
      rows = rows.concat(batch.rows)
    end

    waited = false
    if batch.code == SQLITE_DONE
      Native.close(cur)
      return ok(Done(rows: rows, changes: batch.changes, frames: frames))
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
  ok(Done(rows: rows, changes: 0, frames: frames))
end
