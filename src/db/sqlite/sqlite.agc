## The SQLite adapter, through the system libsqlite3.
##
## `open` gives a `Connection`, which the task that opened it owns: close it with `close`, or the end of the task
## closes it (a transaction still open is rolled back). Using a closed connection is a runtime error
## (`RUNTIME-NATIVE-CLOSED`).
##
## `open` sets up the connection for a web app. The parameters after a `?` change it (`sqlite/url.agc` reads them):
## `journal_mode` (default `wal`), `foreign_keys` (default `on`), `busy_timeout` (milliseconds, default 5000) and
## `fts5=required` (the open fails when this SQLite has no FTS5). `sqlite:app.db?journal_mode=delete&foreign_keys=off`
## is SQLite's own behavior. A name that starts with `file:` is a SQLite URI and goes to SQLite as it is, with its own
## `?` parameters (`file:app.db?mode=ro`); the defaults still apply to it. A default `wal` that a read-only database
## refuses is skipped (for a `file:` name, one that SQLite will not set is skipped too); an explicit one is an error.
##
## A statement that finds a lock held by another connection (SQLITE_BUSY, or SQLITE_LOCKED for a table of a shared
## cache) is tried again after a short sleep until `busy_timeout` is over, then fails with that error; 0 fails at once.
## The wait is made here and not by SQLite (SQLite's busy timeout stays 0): a `compute def` call that sleeps in
## SQLite's busy handler holds one of the threads of the compute pool, which has one per scheduler, so the writers that
## wait would keep the writer that holds the lock from finishing. A write in a transaction that has read (a plain
## `BEGIN`, a read, then the write) is not waited for: SQLite does not wait there either, since the connection that
## holds the lock may be waiting for this one to let go of its read lock. It fails at once.
##
## `timeout_ms` (a url parameter, and an argument of `query` and `execute`; none by default) bounds a statement. A
## watchdog task calls `sqlite3_interrupt` when the time is over, and the statement fails with `sqlite error 9:
## interrupted`. The wait for a lock ends with the time too. SQLite rolls back the whole transaction when it
## interrupts a write inside one (`in_transaction?` is then false). A statement whose deadline has passed before its
## first step does not run at all, so nothing is rolled back and the transaction stays open. The watchdog is awaited
## before the call returns, so an interrupt never reaches the next statement.
##
## Each connection keeps up to `statement_cache` prepared statements (64 by default; a url parameter, 0 for none), by
## the exact text of the sql, so a statement that runs again is not parsed and planned again. The cache belongs to the
## connection and is only touched while a call holds it (see `lease`): a statement is out of the cache while it runs,
## so it is never handed out twice, and a call that finds the cache in use by another task prepares its own statement
## and finalizes it after. A statement goes back reset and with no bindings, also after a failure. The oldest unused
## statement is finalized when the cache is full, and `close` finalizes them all. A connection that is only dropped
## (the end of its task closes it) leaves its cached statements to SQLite until the process ends: close it.
##
## An engine failure is `sqlite error <code>: <message>`; a bad input is `sqlite error: <message>`.

import SqliteLock from "lock"
import SqliteUrl from "url"
import {Row, Value} from "../support/value"

## The statement that starts a transaction: IMMEDIATE takes the write lock at once, so a busy database fails at
## BEGIN, not in the middle of the body.
export BEGIN_SQL = "BEGIN IMMEDIATE"
SQLITE_OK = 0
SQLITE_ROW = 100
SQLITE_DONE = 101
SQLITE_INTEGER = 1
SQLITE_FLOAT = 2
SQLITE_TEXT = 3
SQLITE_BLOB = 4
# SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_URI: the URI flag makes `file:` names work the same on
# every build, whatever its default.
OPEN_FLAGS = 70
SQLITE_READONLY = 8
SQLITE_LOCKED = 6
SQLITE_INTERRUPT = 9
# The state of a connection with a read transaction open, for `sqlite3_txn_state`, which SQLite has since 3.34.0
# (3034000 for `sqlite3_libversion_number`). A system library that is older never says it, and the write is waited for.
SQLITE_TXN_READ = 1
# `sqlite3_stmt_status` counter of the times SQLite prepared a statement again by itself (a schema change).
STMTSTATUS_REPREPARE = 5
TXN_STATE_VERSION = 3_034_000
# The sleep between two tries starts at 1 ms, grows with the time already waited and stops at 25 ms.
MAX_PAUSE_MS = 25
# The length argument that means "up to the NUL" for the sql.
NUL_TERMINATED = -1
# The key of the counter of the calls that hold the cache of a connection (`lease`).
LEASE_KEY = "lease"
# The destructor argument SQLITE_TRANSIENT, which makes SQLite copy the bound value.
TRANSIENT_DESTRUCTOR = -1

## An open database, the time its statements wait for a lock, and the limit of a statement (0: none). `handle` is
## public because a struct has no private fields, but its type is not exported (a user cannot name it): treat it as
## opaque and pass the `Connection` around. `deadline` is set only on the copy that a bounded call works with. The
## statement cache is `statements` (the address of each idle statement by its sql, oldest first: a key that is taken
## out and put back goes to the end of the table), `leases` (who holds it) and `cache_limit`; copies of a `Connection`
## share both tables.
export struct Connection
  handle: Handle
  busy_timeout: Int
  statements: ATS[String, Int]
  leases: ATS[String, Int]
  cache_limit: Int
  timeout_ms: Int = 0
  deadline: Int = 0
end

# What the watchdog of a bounded call needs.
struct Watch
  handle: Handle
  ms: Int
end

# A prepared statement is a raw pointer, not a resource: a resource would be finalized when the task that prepared it
# ends, and a connection of a pool is used by a new task for each block. The cache and the call that holds a statement
# are the only owners, and each finalizes by hand.
type Stmt = C.Pointer

# A statement a call works with, and whether the call holds the cache of the connection, so that the statement goes
# back into it (otherwise it is finalized).
struct Held
  stmt: Stmt
  cached: Bool
end

# The code of a step and whether it waited for a lock before: a statement that writes and was run again by SQLite
# gives its rows from the start.
struct Stepped
  code: Int
  waited: Bool
end

extern "sqlite3"
  resource Handle, free: sqlite3_close_v2
  compute def sqlite3_open_v2(filename: C.String, out db: Handle, flags: C.Int32, vfs: C.Pointer) -> C.Int32
  def sqlite3_extended_errcode(db: Handle) -> C.Int32
  def sqlite3_errmsg(db: Handle) -> C.String
  def sqlite3_errstr(code: C.Int32) -> C.String
  def sqlite3_interrupt(db: Handle) -> Void
  def sqlite3_get_autocommit(db: Handle) -> C.Int32
  def sqlite3_changes(db: Handle) -> C.Int32
  def sqlite3_total_changes(db: Handle) -> C.Int32
  # Prepare is compute too: a big schema makes it slow. The statement is an out pointer, which can be NULL (sql that
  # holds only whitespace and comments), and `tail` is where the text after the first statement starts.
  compute def sqlite3_prepare_v2(db: Handle, sql: C.Pointer, bytes: C.Int32, out stmt: C.Pointer,
                                 out tail: C.Pointer) -> C.Int32
  compute def sqlite3_step(stmt: C.Pointer) -> C.Int32
  def sqlite3_reset(stmt: C.Pointer) -> C.Int32
  def sqlite3_clear_bindings(stmt: C.Pointer) -> C.Int32
  def sqlite3_finalize(stmt: C.Pointer) -> C.Int32
  def sqlite3_stmt_status(stmt: C.Pointer, op: C.Int32, reset: C.Int32) -> C.Int32
  def sqlite3_stmt_readonly(stmt: C.Pointer) -> C.Int32
  def sqlite3_libversion_number() -> C.Int32
  def sqlite3_txn_state(db: Handle, schema: C.Pointer) -> C.Int32
  def sqlite3_bind_parameter_count(stmt: C.Pointer) -> C.Int32
  def sqlite3_bind_null(stmt: C.Pointer, index: C.Int32) -> C.Int32
  def sqlite3_bind_int64(stmt: C.Pointer, index: C.Int32, value: C.Int64) -> C.Int32
  def sqlite3_bind_double(stmt: C.Pointer, index: C.Int32, value: C.Double) -> C.Int32
  def sqlite3_bind_text(stmt: C.Pointer, index: C.Int32, text: C.Pointer, bytes: C.Int32,
                        destructor: C.Pointer) -> C.Int32
  def sqlite3_bind_blob(stmt: C.Pointer, index: C.Int32, blob: C.Bytes, bytes: C.Int32,
                        destructor: C.Pointer) -> C.Int32
  def sqlite3_bind_zeroblob(stmt: C.Pointer, index: C.Int32, bytes: C.Int32) -> C.Int32
  def sqlite3_column_count(stmt: C.Pointer) -> C.Int32
  def sqlite3_column_name(stmt: C.Pointer, col: C.Int32) -> C.String
  def sqlite3_column_type(stmt: C.Pointer, col: C.Int32) -> C.Int32
  def sqlite3_column_int64(stmt: C.Pointer, col: C.Int32) -> C.Int64
  def sqlite3_column_double(stmt: C.Pointer, col: C.Int32) -> C.Double
  def sqlite3_column_text(stmt: C.Pointer, col: C.Int32) -> C.Pointer
  def sqlite3_column_blob(stmt: C.Pointer, col: C.Int32) -> C.Pointer
  def sqlite3_column_bytes(stmt: C.Pointer, col: C.Int32) -> C.Int32
end

## Opens a database file, or `:memory:`; the file is created when it does not exist. A `?` ends the path and starts
## the settings (see the top of this file); a path that holds a `?` (as does the Windows `\\?\` prefix) cannot be
## opened by name, except as a `file:` URI.
export def open(path: String) -> Result[Connection]
  if has_nul?(path)
    return error("sqlite error: the path contains a NUL character")
  end

  target = try SqliteUrl.parse(path)
  try load_library()
  opened = sqlite3_open_v2(target.path, OPEN_FLAGS, Native.pointer(0))
  if opened.result != SQLITE_OK
    # The handle may be NULL (out of memory), which errmsg cannot take, so the text comes from the code.
    Native.close(opened.db)
    return error("sqlite error #{opened.result}: #{sqlite3_errstr(opened.result)}")
  end

  statements: ATS[String, Int] = ATS.new()
  leases: ATS[String, Int] = ATS.new()
  conn = Connection(
    handle: opened.db,
    busy_timeout: target.settings.busy_timeout,
    statements: statements,
    leases: leases,
    cache_limit: target.settings.statement_cache,
    timeout_ms: target.settings.timeout_ms,
  )

  # The setup statements run once: they do not go through the cache.
  configured = configure(conn.with(cache_limit: 0), target.settings)
  case configured
    ok(_) -> return ok(conn)
    error(message) ->
      Native.close(opened.db)
      return error(message)
  end
end

## Closes the connection, after finalizing its cached statements; closing it again does nothing. Closing the last
## connection of a WAL database checkpoints it, which can take a while: this call blocks the task meanwhile.
export def close(conn: Connection) -> Void
  # The lease is never given back: nothing may use the cache of a closed connection. When another call holds it (a
  # statement is running on another task) the cached statements are left to SQLite, which keeps the connection until
  # they are finalized: finalizing a statement that a thread is stepping would be a crash.
  if conn.leases.add(LEASE_KEY, 1) == 1
    finalize_cached(conn)
  end

  Native.close(conn.handle)
end

## Runs one statement with bound parameters and gives its rows, which are empty for a statement without a result.
## Two columns with one name are an error: alias them. `timeout_ms` is the limit of this call: -1 takes the one of the
## connection, 0 is none.
export def query(conn: Connection, sql: String, params: List[Value], timeout_ms: Int = -1) -> Result[List[Row]]
  return bounded(conn, timeout_ms) do |run| run_query(run, sql, params) end
end

## Runs one statement with bound parameters and gives the number of rows it inserted, updated or deleted.
## `timeout_ms` is as in `query`.
export def execute(conn: Connection, sql: String, params: List[Value], timeout_ms: Int = -1) -> Result[Int]
  return bounded(conn, timeout_ms) do |run| run_execute(run, sql, params) end
end

## Whether a transaction is open, which SQLite knows without asking the database. A closed connection is not in one.
export def in_transaction?(conn: Connection) -> Bool
  if Native.closed?(conn.handle)
    return false
  end

  return sqlite3_get_autocommit(conn.handle) == 0
end

## Whether the connection is open. SQLite has no link that can be lost, so a closed handle is all there is to know
## without running a statement.
export def connected?(conn: Connection) -> Bool
  return not Native.closed?(conn.handle)
end

## Stops the statement that is running on the connection, if any, which then fails with `sqlite error 9: interrupted`.
## A pool calls it when a block outlives its lease: `close` waits for a running `sqlite3_step`, and this lets it end.
## An interrupt while no statement runs does nothing. Not for `Db`: only the pool reaches it.
export def interrupt(conn: Connection) -> Void
  if not Native.closed?(conn.handle)
    sqlite3_interrupt(conn.handle)
  end
end

## Whether the connection works: it is open and answers `SELECT 1`.
export def healthy?(conn: Connection) -> Bool
  if Native.closed?(conn.handle)
    return false
  end

  return run_query(conn, "SELECT 1", []).ok?
end

# `try` leaves only before the statement is held: from there every path ends in `release`.
def run_query(conn: Connection, sql: String, params: List[Value]) -> Result[List[Row]]
  held = try acquire(conn, sql, params)
  rows = query_statement(conn, held.stmt)
  release(conn, sql, held)
  return rows
end

def query_statement(conn: Connection, stmt: Stmt) -> Result[List[Row]]
  names = column_names(stmt)
  try unique_names(names)
  return collect(conn, stmt, names, true)
end

def run_execute(conn: Connection, sql: String, params: List[Value]) -> Result[Int]
  held = try acquire(conn, sql, params)
  before = sqlite3_total_changes(conn.handle)
  # A statement that returns rows is run for its effect: its rows are stepped over, not read.
  ran = collect(conn, held.stmt, [], false)
  release(conn, sql, held)
  try ran
  return ok(changes_since(conn, before))
end

def unique_names(names: List[String]) -> Result[Void]
  if names.uniq.size != names.size
    return error("sqlite error: the result has the column #{repeated_name(names)} twice, alias one of them")
  end

  return ok()
end

# Runs `body` with the limit of the call. With a limit, a watchdog task interrupts the statement when the time is over
# and the waits for a lock stop at the same deadline. The watchdog is cancelled and awaited before the call returns:
# an interrupt that came after the statement ended would be taken by the next one. It is a `Result[Void]` task so that
# the await of a cancelled one is a value.
def bounded[R](conn: Connection, timeout_ms: Int, body: Fn[Connection, Result[R]]) -> Result[R]
  limit = timeout_ms
  if limit < 0
    limit = conn.timeout_ms
  end

  if limit == 0
    return body.call(conn)
  end

  deadline = Time.monotonic_ms() + limit
  watchdog_task = Task.spawn(&watchdog, Watch(handle: conn.handle, ms: limit))
  done = body.call(conn.with(deadline: deadline))
  Task.cancel(watchdog_task)
  _ = Task.await(watchdog_task)
  return timed_out(done, limit, deadline)
end

def watchdog(watch: Watch) -> Result[Void]
  Task.sleep(watch.ms)
  sqlite3_interrupt(watch.handle)
  return ok()
end

# A lock that was still held when the deadline stopped the wait is a timeout like an interrupt.
def timed_out[R](done: Result[R], limit: Int, deadline: Int) -> Result[R]
  case done
    ok(_) -> return done
    error(message) ->
      busy = message.start_with?("sqlite error #{SqliteLock.SQLITE_BUSY}:")
      locked = busy or message.start_with?("sqlite error #{SQLITE_LOCKED}:")
      if locked and Time.monotonic_ms() >= deadline
        return error(
          "sqlite error #{SQLITE_INTERRUPT}: interrupted, the timeout of #{limit} ms ended while waiting for a lock",
        )
      end

      return done
  end
end

def configure(conn: Connection, settings: SqliteUrl.Settings) -> Result[Void]
  if settings.fts5 and not fts5?(conn)
    return error("sqlite error: this SQLite was built without FTS5 (fts5=required)")
  end

  # Set in both cases: a build can turn foreign keys on by default.
  try run_execute(conn, "PRAGMA foreign_keys = #{on_off(settings.foreign_keys)}", [])
  try set_journal_mode(conn, settings)
  return ok()
end

def on_off(flag: Bool) -> String
  if flag
    return "ON"
  end

  return "OFF"
end

# The pragma answers with the mode in force. A memory database stays in `memory` whatever is asked, which is fine;
# any other answer means the mode did not change. When the url did not name a journal mode, the default WAL is
# best effort in two cases, so a url that worked before still opens: a database that cannot be written (code 8: a
# read-only file or `mode=ro`), and a `file:` URI, whose own parameters (`immutable=1`, `nolock=1`, `vfs=unix-none`)
# can rule WAL out. A plain path that cannot take WAL (a file system without shared memory) is an error, since a web
# app would rather stop at startup than run in another mode. An explicit journal_mode is always an error.
def set_journal_mode(conn: Connection, settings: SqliteUrl.Settings) -> Result[Void]
  mode = settings.journal_mode
  asked = run_query(conn, "PRAGMA journal_mode = #{mode.upcase}", [])
  case asked
    error(message) ->
      if not settings.journal_given and message.start_with?("sqlite error #{SQLITE_READONLY}:")
        return ok()
      end

      return error(message)

    ok(rows) ->
      answer = "unknown"
      if not rows.empty?
        case rows[0].get("journal_mode", Value.Null)
          Value.Text(text) -> answer = text
          _ -> answer = "unknown"
        end
      end

      if answer != mode and answer != "memory" and not (settings.uri and not settings.journal_given)
        return error("sqlite error: journal_mode #{mode} could not be set, the database is in #{answer} mode")
      end

      return ok()
  end
end

# Tries to create an FTS5 table in the temp schema, which no file keeps.
def fts5?(conn: Connection) -> Bool
  made = run_execute(conn, "CREATE VIRTUAL TABLE temp.agentica_fts5_probe USING fts5(x)", [])
  if not made.ok?
    return false
  end

  _ = run_execute(conn, "DROP TABLE temp.agentica_fts5_probe", [])
  return true
end

# A library that is missing is an error here, not a stop of the program at the first call.
def load_library() -> Result[Void]
  case Native.load("sqlite3")
    error(message) -> return error("sqlite error: cannot load the SQLite library: #{message}")
    ok(_) -> return ok()
  end
end

def repeated_name(names: List[String]) -> String
  counts = names.tally
  return names.find do |name| counts[name] > 1 end.unwrap_or("")
end

def changes_since(conn: Connection, before: Int) -> Int
  # sqlite3_changes keeps the count of the last row-changing statement, so a statement that changed nothing
  # (a CREATE TABLE after an INSERT) must not report it.
  if sqlite3_total_changes(conn.handle) == before
    return 0
  end

  return sqlite3_changes(conn.handle)
end

# A statement for `sql` with `params` bound: an idle one of the cache, or a new one. The cache is used only by the call
# that holds the lease, and a statement taken from it is not in it until it is released, so nobody else gets it.
def acquire(conn: Connection, sql: String, params: List[Value]) -> Result[Held]
  if has_nul?(sql)
    return error("sqlite error: the sql contains a NUL character")
  end

  # A cached statement does not touch the handle before its first step, so a closed connection is told here (the
  # runtime error of any call on a closed handle).
  sqlite3_get_autocommit(conn.handle)
  cached = lease(conn)
  made = prepared_for(conn, sql, cached)
  case made
    error(message) ->
      unlease(conn, cached)
      return error(message)

    ok(stmt) ->
      held = Held(stmt: stmt, cached: cached)
      bound = bind_all(conn, stmt, params)
      case bound
        ok(_) -> return ok(held)
        error(message) ->
          release(conn, sql, held)
          return error(message)
      end
  end
end

def prepared_for(conn: Connection, sql: String, cached: Bool) -> Result[Stmt]
  if cached
    found = conn.statements.get(sql)
    case found
      ok(address) ->
        conn.statements.delete(sql)
        return ok(Native.pointer(address))

      error(_) -> return prepare_new(conn, sql)
    end
  end

  return prepare_new(conn, sql)
end

# Takes the cache of the connection when no other call holds it (`add` is atomic, so only one call gets 1). A call
# that does not get it gives its count back at once and uses no cache. A call that never gives the lease back (its
# task was cancelled in a step) leaves the connection without a cache, which is slow and safe.
def lease(conn: Connection) -> Bool
  if conn.cache_limit == 0
    return false
  end

  if conn.leases.add(LEASE_KEY, 1) == 1
    return true
  end

  conn.leases.add(LEASE_KEY, -1)
  return false
end

def unlease(conn: Connection, cached: Bool) -> Void
  if cached
    conn.leases.add(LEASE_KEY, -1)
  end
end

# Ends a call's use of a statement. A cached call resets it (which also stops a statement that is half way through its
# rows, after a failed step or a deadline) and clears its bindings before it goes back to the cache, then finalizes the
# oldest statements over the limit. Any other call finalizes its statement.
def release(conn: Connection, sql: String, held: Held) -> Void
  if not held.cached
    sqlite3_finalize(held.stmt)
    return
  end

  sqlite3_reset(held.stmt)
  sqlite3_clear_bindings(held.stmt)
  conn.statements.put(sql, Native.address(held.stmt))
  while conn.statements.size > conn.cache_limit
    evict_oldest(conn)
  end

  unlease(conn, true)
end

def evict_oldest(conn: Connection) -> Void
  oldest = conn.statements.keys.first
  finalize_cached_key(conn, oldest)
end

# Only the call that holds the lease (or `close`, which keeps it) gets here.
def finalize_cached(conn: Connection) -> Void
  for sql in conn.statements.keys
    finalize_cached_key(conn, sql)
  end
end

def finalize_cached_key(conn: Connection, sql: String) -> Void
  found = conn.statements.get(sql)
  conn.statements.delete(sql)
  case found
    ok(address) -> sqlite3_finalize(Native.pointer(address))
    error(_) -> return
  end
end

# A new statement for the one statement in `sql`. The sql goes through an owned buffer, not a C.String: SQLite points
# `tail` into its copy, and a C.String copy lives only during the call.
def prepare_new(conn: Connection, sql: String) -> Result[Stmt]
  made: Result[Stmt] = Native.from_string(sql) do |buf| prepare_buffer(conn, buf) end
  return made
end

# Prepares the first statement in the buffer, waiting for a lock like a step does, and refuses a second one. SQLite
# gives a NULL statement for sql that holds only whitespace and comments.
def prepare_buffer(conn: Connection, buf: C.Pointer) -> Result[Stmt]
  prepared = prepare_waiting(conn, buf)
  if prepared.result != SQLITE_OK
    return error(failure(conn, prepared.result))
  end

  if Native.null?(prepared.stmt)
    return error("sqlite error: the sql has no statement")
  end

  stmt = prepared.stmt
  if Native.get_string(prepared.tail, 0) != "" and not comments_only?(conn, prepared.tail)
    sqlite3_finalize(stmt)
    return error("sqlite error: the sql has more than one statement")
  end

  return ok(stmt)
end

# Whether the text after the first statement has no statement: a tail of comments gives a NULL statement, which is
# still one statement. The statement of the tail, if there is one, is finalized at once, never run.
def comments_only?(conn: Connection, tail: C.Pointer) -> Bool
  more = prepare_waiting(conn, tail)
  if more.result != SQLITE_OK
    return false
  end

  if Native.null?(more.stmt)
    return true
  end

  sqlite3_finalize(more.stmt)
  return false
end

# One prepare, tried again while the database is locked. The call is a compute def: if the task is cancelled during the
# parse, the C call still finishes but its statement is dropped, so it is never finalized (an out C.Pointer is not
# freed on cancel). SQLite frees it when the connection closes.
def prepare_waiting(conn: Connection, buf: C.Pointer) -> Sqlite3PrepareV2
  started = Time.monotonic_ms()
  prepared = sqlite3_prepare_v2(conn.handle, buf, NUL_TERMINATED)
  while lock_wait?(conn, prepared.result, started)
    pause(conn, started)
    prepared = sqlite3_prepare_v2(conn.handle, buf, NUL_TERMINATED)
  end

  return prepared
end

def bind_all(conn: Connection, stmt: Stmt, params: List[Value]) -> Result[Void]
  wanted = sqlite3_bind_parameter_count(stmt)
  if wanted != params.size
    return error("sqlite error: the sql has #{wanted} #{noun(wanted)}, got #{params.size}")
  end

  index = 1
  for param in params
    code = bind_value(stmt, index, param)
    if code != SQLITE_OK
      return error(failure(conn, code))
    end

    index += 1
  end

  return ok()
end

def noun(count: Int) -> String
  if count == 1
    return "parameter"
  end

  return "parameters"
end

def bind_value(stmt: C.Pointer, index: Int, value: Value) -> Int
  case value
    Value.Null -> return sqlite3_bind_null(stmt, index)
    Value.Int(n) -> return sqlite3_bind_int64(stmt, index, n)
    Value.Float(x) -> return sqlite3_bind_double(stmt, index, x)
    Value.Text(text) -> return bind_text(stmt, index, text)
    Value.Blob(bytes) -> return bind_blob(stmt, index, bytes)
    Value.Bool(flag) -> return sqlite3_bind_int64(stmt, index, bool_int(flag))
  end
end

# The text goes with its length, so a NUL inside it is kept; SQLite copies it (transient) before the buffer is freed.
def bind_text(stmt: C.Pointer, index: Int, text: String) -> Int
  code: Int = Native.from_string(text) do |buf| sqlite3_bind_text(stmt, index, buf, text.bytesize, transient()) end

  return code
end

def bind_blob(stmt: C.Pointer, index: Int, bytes: Bytes) -> Int
  # Binding a NULL pointer would store NULL, so an empty blob has its own call.
  if bytes.empty?
    return sqlite3_bind_zeroblob(stmt, index, 0)
  end

  return sqlite3_bind_blob(stmt, index, bytes, bytes.size, transient())
end

def transient() -> C.Pointer
  return Native.pointer(TRANSIENT_DESTRUCTOR)
end

def bool_int(flag: Bool) -> Int
  if flag
    return 1
  end

  return 0
end

# The shared step loop: every row read with the given column names, or none when `keep` is false.
def collect(conn: Connection, stmt: Stmt, names: List[String], keep: Bool) -> Result[List[Row]]
  # An interrupt that came between the prepare and the first step is lost (SQLite ignores one while no statement
  # runs), so the deadline is read here. Later steps are left to the interrupt: a statement that SQLite stopped is
  # rolled back by SQLite, which a return from here would skip (a write with RETURNING does its work in the
  # first step).
  if conn.deadline > 0 and Time.monotonic_ms() >= conn.deadline
    return error(failure(conn, SQLITE_INTERRUPT))
  end

  rows: List[Row] = []
  columns = names
  checked = false
  while true
    stepped = step(conn, stmt)
    code = stepped.code
    # SQLite rolls a write back and runs it again after a wait (a commit refused in a rollback journal), so the rows
    # of the first run are dropped; a read goes on from where it stopped.
    if stepped.waited and sqlite3_stmt_readonly(stmt) == 0
      rows = []
    end

    if code == SQLITE_DONE
      return ok(rows)
    end

    if code != SQLITE_ROW
      return error(failure(conn, code))
    end

    if keep
      # A cached statement that SQLite prepared again at its first step (a schema change since its last use) may have
      # other columns than the ones read before the step.
      if not checked and reprepared?(stmt)
        columns = column_names(stmt)
        try unique_names(columns)
      end

      checked = true
      rows = rows.push(read_row(stmt, columns))
    end
  end

  return ok(rows)
end

# Whether SQLite has prepared the statement again since the last time this asked.
def reprepared?(stmt: Stmt) -> Bool
  return sqlite3_stmt_status(stmt, STMTSTATUS_REPREPARE, 1) > 0
end

# One step, tried again while the database is locked. SQLite documents a retry for a COMMIT, which stays open after
# SQLITE_BUSY, and for a statement outside a transaction. A write that a read transaction of this connection asks for
# is not tried again (`upgrade?`).
def step(conn: Connection, stmt: Stmt) -> Stepped
  started = Time.monotonic_ms()
  code = sqlite3_step(stmt)
  waited = false
  while lock_wait?(conn, code, started) and not upgrade?(conn, stmt)
    pause(conn, started)
    waited = true
    code = sqlite3_step(stmt)
  end

  return Stepped(code: code, waited: waited)
end

# A statement that writes, in a connection that holds a read lock: SQLite does not wait for the lock of the writer
# (its busy handler is skipped, since the holder of the write lock may be waiting for our read lock, which we keep
# until the write is done), so waiting here would stall the other connection's COMMIT until `busy_timeout` is over,
# and then fail with the same error. `Db.transaction` begins with BEGIN IMMEDIATE, so its statements never get here.
def upgrade?(conn: Connection, stmt: Stmt) -> Bool
  if sqlite3_stmt_readonly(stmt) != 0 or sqlite3_libversion_number() < TXN_STATE_VERSION
    return false
  end

  # Only SQLITE_BUSY itself is that refusal: a table lock of a shared cache (262) or a WAL being recovered (261) goes
  # away without this connection letting go of anything.
  if not SqliteLock.plain_busy?(sqlite3_extended_errcode(conn.handle))
    return false
  end

  return sqlite3_txn_state(conn.handle, Native.pointer(0)) == SQLITE_TXN_READ
end

# True when `code` says that another connection holds a lock and the wait that began at `started` is not over, so
# the caller pauses and tries again. The codes are checked first, so a step that gives a row asks nothing of SQLite.
def lock_wait?(conn: Connection, code: Int, started: Int) -> Bool
  if code != SqliteLock.SQLITE_BUSY and code != SQLITE_LOCKED
    return false
  end

  if not SqliteLock.waitable?(sqlite3_extended_errcode(conn.handle))
    return false
  end

  now = Time.monotonic_ms()
  if conn.deadline > 0 and now >= conn.deadline
    return false
  end

  return now - started < conn.busy_timeout
end

# Sleeps a little: the task parks, so its thread of the compute pool is free for the connection that holds the lock.
# The sleep never goes past the end of the wait, nor the deadline of the call.
def pause(conn: Connection, started: Int) -> Void
  now = Time.monotonic_ms()
  waited = now - started
  length = waited / 4 + 1
  if length > MAX_PAUSE_MS
    length = MAX_PAUSE_MS
  end

  left = conn.busy_timeout - waited
  if conn.deadline > 0 and conn.deadline - now < left
    left = conn.deadline - now
  end

  if length > left
    length = left
  end

  if length < 1
    length = 1
  end

  Task.sleep(length)
end

def column_names(stmt: C.Pointer) -> List[String]
  names: List[String] = []
  count = sqlite3_column_count(stmt)
  for col in 0...count
    names = names.push(sqlite3_column_name(stmt, col))
  end

  return names
end

def read_row(stmt: C.Pointer, names: List[String]) -> Row
  row: Row = {}
  index = 0
  for name in names
    row = row.put(name, read_value(stmt, index))
    index += 1
  end

  return row
end

def read_value(stmt: C.Pointer, col: Int) -> Value
  kind = sqlite3_column_type(stmt, col)
  if kind == SQLITE_INTEGER
    return Value.Int(sqlite3_column_int64(stmt, col))
  elsif kind == SQLITE_FLOAT
    return Value.Float(sqlite3_column_double(stmt, col))
  elsif kind == SQLITE_TEXT
    # The pointer first, then its length: sqlite3_column_bytes is only right after the conversion.
    text = sqlite3_column_text(stmt, col)
    return Value.Text(Native.get_string(text, 0, sqlite3_column_bytes(stmt, col)))
  elsif kind == SQLITE_BLOB
    blob = sqlite3_column_blob(stmt, col)
    return Value.Blob(Native.get_bytes(blob, 0, sqlite3_column_bytes(stmt, col)))
  end

  return Value.Null
end

# The code is the one the failed call returned; the text is SQLite's own message.
def failure(conn: Connection, code: Int) -> String
  if code == SQLITE_INTERRUPT
    return "sqlite error #{SQLITE_INTERRUPT}: interrupted"
  end

  return "sqlite error #{code}: #{sqlite3_errmsg(conn.handle)}"
end

# A NUL ends a C.String early, and the VM stops the program at the call (RUNTIME-INVALID-CHARACTER).
def has_nul?(text: String) -> Bool
  return text.include?(String.from_code(0))
end
