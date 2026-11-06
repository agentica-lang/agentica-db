## The SQLite adapter, through the system libsqlite3.
##
## `open` gives a `Connection`, which the task that opened it owns: close it with `close`, or the end of the task
## closes it (a transaction still open is rolled back). Using a closed connection is a runtime error
## (`RUNTIME-NATIVE-CLOSED`).
##
## `open` sets up the connection for a web app. The parameters after a `?` change it (`sqlite/url.agc` reads them):
## `journal_mode` (default `wal`), `foreign_keys` (default `on`), `busy_timeout` (milliseconds, default 5000),
## `synchronous` (default `normal` in WAL, SQLite's `full` in other modes), `mmap_size` (134217728 bytes),
## `cache_size` (2000 pages) and `journal_size_limit` (67108864 bytes), the pragmas of Rails 8, `statement_cache` (128
## prepared statements per connection, see below) and `fts5=required` (the open fails when this SQLite has no FTS5).
## `sqlite:app.db?journal_mode=delete&foreign_keys=off` is SQLite's own behavior. A name that starts with `file:` is a
## SQLite URI and goes to SQLite as it is, with its own `?` parameters (`file:app.db?mode=ro`); the defaults still
## apply to it (change one with its PRAGMA after `open`). A default `wal` that a read-only database refuses is skipped
## (for a `file:` name, one that SQLite will not set is skipped too); an explicit one is an error.
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
## A connection can keep the statements it prepared, by their sql text, up to `statement_cache` of them: the next call
## with the same sql skips the prepare (a hop to the compute pool, and the parse) and only resets the statement and
## binds the new values. A full cache finalizes the statement used least recently to make room. A statement that fails
## to prepare is not kept, and neither is one whose sql is longer than MAX_CACHED_SQL_BYTES. The default is 0 for
## `open` and 128 for `open_pooled` (what `DbPool` opens), because of what an unclosed connection costs, see below.
##
## The cache is a mutable table that the copies of a `Connection` share (`bounded` makes one per call). It is not
## locked: a connection is used by one task at a time, as a pool lease guarantees, and that task alone prepares, runs,
## evicts and closes. A cached statement is a raw pointer and not a resource, because a resource is finalized with the
## task that made it (a lease task) and the cache outlives it. So `close` finalizes the statements: SQLite keeps a
## closed connection as a zombie, with its file, page cache and WAL, while one of them is unfinalized. The end of the
## task that owns a connection closes the handle only and finalizes nothing, so a connection that nobody closes must
## not hold statements: that is why `open` keeps none by default. A statement that is not cached is tracked from its
## prepare to its release (`flight`), and `close` finalizes those too.
##
## A cancelled task cannot run its release. It is parked in a step (a compute call) or in a sleep for a lock, and the
## statement may be at a row, or inside a step that runs on with its result dropped. `close` finalizes every statement
## but the one of the call that was parked in a step, closes the handle, and then gives that statement up to
## RUNNING_WAIT_MS to leave its step before it finalizes it too (SQLite built without a mutex for each connection, as
## Apple's, crashes on a finalize under a step). The pool interrupts the connection first, which ends a long step at
## once. A task cancelled during the prepare itself loses the new statement (an out pointer is not freed on a cancel),
## and the connection then stays open until the program ends.
##
## Never close a connection while another task runs a statement on it (a pool does it only after the lease is over and
## the statement interrupted): `close` waits for the step to end, which blocks the scheduler thread that runs it, and
## the call that wakes up finds the connection closed and fails with `sqlite error: the connection was closed while the
## statement ran`.
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
TXN_STATE_VERSION = 3_034_000
# The counter of `sqlite3_stmt_status` that says how many times SQLite prepared the statement again by itself, which
# it does at the first step after the schema changed.
STMTSTATUS_REPREPARE = 5
# The counter of `sqlite3_stmt_status` of the opcodes a statement has run. SQLite adds to it when a step returns, so it
# grows by at least one with each step. Nothing calls `sqlite3_stmt_status` with reset=1, so the counters only grow.
STMTSTATUS_VM_STEP = 4
# The sql of a longer statement (a bulk insert with thousands of values) is run and finalized, not kept.
MAX_CACHED_SQL_BYTES = 16_384
# The keys of the counters of a cache: the clock of the uses, the address of the statement of the call that is in a
# native call or a sleep (0 for none) and the opcode count it had when its last step was dispatched.
TICK = "tick"
RUNNING = "running"
STEPS = "steps"
# How long `close` waits for the statement of a call that was parked in a step to leave it. An interrupted step ends in
# well under a millisecond; a statement that is idle at a row never changes, so this is also what a cancelled lease
# that stopped in the middle of a result costs.
RUNNING_WAIT_MS = 20
# What `open_pooled` keeps: a pool owns its connections and always closes them.
POOL_STATEMENT_CACHE = 128
# The sleep between two tries starts at 1 ms, grows with the time already waited and stops at 25 ms.
MAX_PAUSE_MS = 25
# What a call that was parked when another task closed the connection fails with.
CLOSED_DURING_CALL = "sqlite error: the connection was closed while the statement ran"
# The length argument that means "up to the NUL" for the sql.
NUL_TERMINATED = -1
# The destructor argument SQLITE_TRANSIENT, which makes SQLite copy the bound value.
TRANSIENT_DESTRUCTOR = -1

## An open database, the time its statements wait for a lock, the limit of a statement (0: none) and its cache of
## prepared statements. `handle` and `statements` are public because a struct has no private fields, but their types
## are not exported (a user cannot name them): treat them as opaque and pass the `Connection` around. `deadline` is
## set only on the copy that a bounded call works with.
export struct Connection
  handle: Handle
  statements: Cache
  busy_timeout: Int
  timeout_ms: Int = 0
  deadline: Int = 0
end

# The prepared statements of a connection by their sql text, at most `capacity`. The tables are shared by the copies of
# the connection. `flight` holds the address of each statement that is not in
# the cache and is between its prepare and its release, so that `close` can finalize it when the call is cancelled.
# `counters` holds the clock of the uses, and the statement that is running with its opcode count (`RUNNING`, `STEPS`).
struct Cache
  entries: ATS[String, Entry]
  flight: ATS[Int, Int]
  counters: ATS[String, Int]
  capacity: Int
end

# What the cache keeps for one statement. `address` is the integer of its `sqlite3_stmt *`: a table holds data, not
# pointers. `names` are the columns of the result as SQLite named them when it last prepared the statement
# (`reprepares` is the count of `sqlite3_stmt_status` then, which tells when SQLite did it again).
struct Entry
  address: Int
  used: Int
  names: List[String]
  duplicate: Bool
  parameters: Int
  reprepares: Int
end

# A statement a call works with: from the cache, or new. `cached` says whether the cache owns it; if not, `release`
# finalizes it.
struct Prepared
  pointer: C.Pointer
  sql: String
  names: List[String]
  duplicate: Bool
  parameters: Int
  reprepares: Int
  cached: Bool
end

# What the watchdog of a bounded call needs.
struct Watch
  handle: Handle
  ms: Int
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
  # Prepare is compute too: a big schema makes it slow. The statement is an out pointer, not an out resource: a
  # resource is finalized with the task that made it, and the cache keeps it for the tasks that come after.
  compute def sqlite3_prepare_v2(db: Handle, sql: C.Pointer, bytes: C.Int32, out stmt: C.Pointer,
                                 out tail: C.Pointer) -> C.Int32
  def sqlite3_finalize(stmt: C.Pointer) -> C.Int32
  def sqlite3_next_stmt(db: Handle, stmt: C.Pointer) -> C.Pointer
  def sqlite3_reset(stmt: C.Pointer) -> C.Int32
  def sqlite3_stmt_busy(stmt: C.Pointer) -> C.Int32
  def sqlite3_clear_bindings(stmt: C.Pointer) -> C.Int32
  def sqlite3_stmt_status(stmt: C.Pointer, op: C.Int32, reset: C.Int32) -> C.Int32
  compute def sqlite3_step(stmt: C.Pointer) -> C.Int32
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
## opened by name, except as a `file:` URI. The connection keeps no prepared statements unless the url sets
## `statement_cache`: the end of its task then closes it cleanly.
export def open(path: String) -> Result[Connection]
  return open_with(path, 0)
end

## Like `open`, for a connection whose owner always closes it (a pool): it keeps up to 128 prepared statements unless
## the url sets `statement_cache`.
export def open_pooled(path: String) -> Result[Connection]
  return open_with(path, POOL_STATEMENT_CACHE)
end

## Closes the connection and finalizes its prepared statements; closing it again does nothing. Closing the last
## connection of a WAL database checkpoints it, which can take a while: this call blocks the task meanwhile.
export def close(conn: Connection) -> Void
  cache = conn.statements
  running = cache.counters.get(RUNNING).unwrap_or(0)
  since = cache.counters.get(STEPS).unwrap_or(0)
  left = finalize_tracked(cache, running)
  # The handle closes before the wait, so a task that wakes up in it finds the connection closed.
  Native.close(conn.handle)
  if left
    cache.counters.put(RUNNING, 0)
    pointer = Native.pointer(running)
    wait_for_step(pointer, since)
    _ = sqlite3_finalize(pointer)
  end
end

## The number of prepared statements SQLite lists for the connection: the cache, which `statement_cache` bounds, and
## nothing else between calls, besides what a virtual table (FTS5) keeps inside. For the specs of the cache; not part
## of `Db`.
export def prepared_count(conn: Connection) -> Int
  count = 0
  stmt = sqlite3_next_stmt(conn.handle, Native.null())
  while not Native.null?(stmt)
    count += 1
    stmt = sqlite3_next_stmt(conn.handle, stmt)
  end

  return count
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

# `cache` is the size of the statement cache when the url does not say.
def open_with(path: String, cache: Int) -> Result[Connection]
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

  # The setup statements run once and would only fill the cache, so they run without one.
  conn = Connection(
    handle: opened.db,
    statements: new_cache(0),
    busy_timeout: target.settings.busy_timeout,
    timeout_ms: target.settings.timeout_ms,
  )

  configured = configure(conn, target.settings)
  case configured
    ok(_) -> return ok(conn.with(statements: new_cache(statement_cache_size(target.settings, cache))))
    error(message) ->
      Native.close(opened.db)
      return error(message)
  end
end

def run_query(conn: Connection, sql: String, params: List[Value]) -> Result[List[Row]]
  stmt = try prepare(conn, sql, params)
  if stmt.duplicate
    release(conn, stmt)
    return error(duplicate_message(stmt.names))
  end

  rows = collect(conn, stmt, true)
  release(conn, stmt)
  return rows
end

def run_execute(conn: Connection, sql: String, params: List[Value]) -> Result[Int]
  stmt = try prepare(conn, sql, params)
  before = sqlite3_total_changes(conn.handle)
  # A statement that returns rows is run for its effect: its rows are stepped over, not read.
  ran = collect(conn, stmt, false)
  release(conn, stmt)
  try ran
  return ok(changes_since(conn, before))
end

def duplicate_message(names: List[String]) -> String
  return "sqlite error: the result has the column #{repeated_name(names)} twice, alias one of them"
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
  mode = try set_journal_mode(conn, settings)
  try set_synchronous(conn, settings, mode)
  try run_query(conn, "PRAGMA mmap_size = #{settings.mmap_size}", [])
  try run_query(conn, "PRAGMA cache_size = #{settings.cache_size}", [])
  try run_query(conn, "PRAGMA journal_size_limit = #{settings.journal_size_limit}", [])
  return ok()
end

# NORMAL in WAL does not sync the WAL file at each commit, only at a checkpoint: a power loss (not a crash of the
# process) can lose the last commits, but never corrupts the database. That is why it is the default only there; in
# the other modes SQLite's own FULL stays, and a url that names the level always wins. `mode` is the journal mode in
# force, empty when it is not known (a database that cannot be written, which has nothing to sync).
def set_synchronous(conn: Connection, settings: SqliteUrl.Settings, mode: String) -> Result[Void]
  level = settings.synchronous
  if level.empty? and mode == "wal"
    level = "normal"
  end

  if level.empty?
    return ok()
  end

  try run_execute(conn, "PRAGMA synchronous = #{level.upcase}", [])
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
# app would rather stop at startup than run in another mode. An explicit journal_mode is always an error. It gives
# the mode in force (empty when the pragma was skipped).
def set_journal_mode(conn: Connection, settings: SqliteUrl.Settings) -> Result[String]
  mode = settings.journal_mode
  asked = run_query(conn, "PRAGMA journal_mode = #{mode.upcase}", [])
  case asked
    error(message) ->
      if not settings.journal_given and message.start_with?("sqlite error #{SQLITE_READONLY}:")
        return ok("")
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

      return ok(answer)
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

# The url's size, or `fallback` when the url did not say (-1).
def statement_cache_size(settings: SqliteUrl.Settings, fallback: Int) -> Int
  if settings.statement_cache < 0
    return fallback
  end

  return settings.statement_cache
end

def new_cache(capacity: Int) -> Cache
  entries: ATS[String, Entry] = ATS.new()
  flight: ATS[Int, Int] = ATS.new()
  counters: ATS[String, Int] = ATS.new()
  return Cache(entries: entries, flight: flight, counters: counters, capacity: capacity)
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

# The statement for `sql` with the values bound, ready to step. It goes back with `release`, also when this fails.
def prepare(conn: Connection, sql: String, params: List[Value]) -> Result[Prepared]
  stmt = try acquire(conn, sql)
  bound = bind_all(conn, stmt, params)
  case bound
    ok(_) -> return ok(stmt)
    error(message) ->
      release(conn, stmt)
      return error(message)
  end
end

# The statement of the cache, reset, or a new one. The hit does not touch the handle, so a closed connection is
# stopped here with the error of its first call (RUNTIME-NATIVE-CLOSED) before a pointer of the cache is used (`close`
# empties the cache, so this only guards a call that raced with it).
def acquire(conn: Connection, sql: String) -> Result[Prepared]
  cache = conn.statements
  found = cache.entries.get(sql)
  case found
    ok(entry) ->
      if Native.closed?(conn.handle)
        _ = sqlite3_get_autocommit(conn.handle)
      end

      pointer = Native.pointer(entry.address)
      # A call that was cancelled or crashed may have left the statement in the middle of a run.
      _ = sqlite3_reset(pointer)
      cache.entries.put(sql, entry.with(used: cache.counters.add(TICK, 1)))
      return ok(
        Prepared(
          pointer: pointer,
          sql: sql,
          names: entry.names,
          duplicate: entry.duplicate,
          parameters: entry.parameters,
          reprepares: entry.reprepares,
          cached: true,
        ),
      )
    error(_) -> return prepare_new(conn, sql)
  end
end

def prepare_new(conn: Connection, sql: String) -> Result[Prepared]
  if has_nul?(sql)
    return error("sqlite error: the sql contains a NUL character")
  end

  # The sql goes through an owned buffer, not a C.String: SQLite points `tail` into its copy, and a C.String copy
  # lives only during the call.
  made: Result[C.Pointer] = Native.from_string(sql) do |buf| prepare_buffer(conn, buf) end
  pointer = try made
  names = column_names(pointer)
  stmt = Prepared(
    pointer: pointer,
    sql: sql,
    names: names,
    duplicate: names.uniq.size != names.size,
    parameters: sqlite3_bind_parameter_count(pointer),
    reprepares: sqlite3_stmt_status(pointer, STMTSTATUS_REPREPARE, 0),
    cached: false,
  )

  return ok(keep(conn, stmt))
end

# Puts a new statement in the cache, finalizing the least recently used one when the cache is full. A cache of
# capacity 0 and a long sql keep nothing: the statement is tracked as in flight until `release` finalizes it, so that
# `close` can finalize it if the call is cancelled in between.
def keep(conn: Connection, stmt: Prepared) -> Prepared
  cache = conn.statements
  if cache.capacity == 0 or stmt.sql.bytesize > MAX_CACHED_SQL_BYTES
    cache.flight.put(Native.address(stmt.pointer), 1)
    return stmt
  end

  if cache.entries.size >= cache.capacity
    evict_oldest(cache)
  end

  cache.entries.put(stmt.sql, entry_of(stmt, cache.counters.add(TICK, 1)))
  return stmt.with(cached: true)
end

def entry_of(stmt: Prepared, used: Int) -> Entry
  return Entry(
    address: Native.address(stmt.pointer),
    used: used,
    names: stmt.names,
    duplicate: stmt.duplicate,
    parameters: stmt.parameters,
    reprepares: stmt.reprepares,
  )
end

# The scan reads the entries one by one, with no copy of the table, and runs only when a new statement finds the cache
# full.
def evict_oldest(cache: Cache) -> Void
  oldest = ""
  oldest_used = -1
  for sql in cache.entries.keys
    used = cache.entries.get(sql).unwrap!.used
    if oldest_used < 0 or used < oldest_used
      oldest = sql
      oldest_used = used
    end
  end

  if oldest_used < 0
    return
  end

  _ = sqlite3_finalize(Native.pointer(cache.entries.get(oldest).unwrap!.address))
  cache.entries.delete(oldest)
end

# A statement of the cache is reset and cleared, and stays; any other is finalized. The reset ends a run that SQLite
# left open (a step that gave SQLITE_BUSY does not end it) and so lets go of its locks. The bindings go now so that a
# big blob does not stay in memory until the sql runs again. A closed connection has no statement left to
# touch: `close`
# finalized them while the call was parked in a step.
def release(conn: Connection, stmt: Prepared) -> Void
  if Native.closed?(conn.handle)
    return
  end

  if stmt.cached
    _ = sqlite3_reset(stmt.pointer)
    _ = sqlite3_clear_bindings(stmt.pointer)
  else
    conn.statements.flight.delete(Native.address(stmt.pointer))
    _ = sqlite3_finalize(stmt.pointer)
  end
end

# Finalizes every statement of the cache and the ones in flight, except `running`, the one whose call may be inside a
# step: SQLite keeps a connection with live statements as a zombie until they are finalized, and its files stay open.
# Only these are ours to finalize: `sqlite3_next_stmt` also lists the statements that a virtual table such as FTS5
# keeps inside, which that module finalizes itself when the connection closes. The tables are emptied first so that no
# call finds a pointer that is gone. It tells whether `running` was one of ours, which is left to the caller.
def finalize_tracked(cache: Cache, running: Int) -> Bool
  left = false
  entries = cache.entries.to_map
  for sql in entries.keys
    cache.entries.delete(sql)
    left = finalize_unless(entries.get(sql).unwrap!.address, running) or left
  end

  for address in cache.flight.keys
    cache.flight.delete(address)
    left = finalize_unless(address, running) or left
  end

  return left
end

# Finalizes the statement at `address` unless it is `running`; gives whether it was.
def finalize_unless(address: Int, running: Int) -> Bool
  if address == running
    return true
  end

  _ = sqlite3_finalize(Native.pointer(address))
  return false
end

# Waits until a statement that was inside a step is out of it. A halted statement (an interrupted step ends that
# way) is
# out; so is one whose opcode count has grown since `since`, the count when its last step was dispatched. A statement
# idle at a row has neither sign, and is told apart from a running step only by waiting; the wait is short.
def wait_for_step(stmt: C.Pointer, since: Int) -> Void
  waited = 0
  while sqlite3_stmt_busy(stmt) != 0 and sqlite3_stmt_status(stmt, STMTSTATUS_VM_STEP, 0) == since
    if waited >= RUNNING_WAIT_MS
      return
    end

    Task.sleep(1)
    waited += 1
  end
end

# Prepares the first statement in the buffer, waiting for a lock like a step does, and refuses a second one. SQLite
# gives a NULL statement for sql that holds only whitespace and comments.
def prepare_buffer(conn: Connection, buf: C.Pointer) -> Result[C.Pointer]
  prepared = sqlite3_prepare_v2(conn.handle, buf, NUL_TERMINATED)
  if lock_code?(prepared.result)
    started = Time.monotonic_ms()
    while lock_wait?(conn, prepared.result, started)
      pause(conn, started)
      prepared = sqlite3_prepare_v2(conn.handle, buf, NUL_TERMINATED)
    end
  end

  if prepared.result != SQLITE_OK
    return error(failure(conn, prepared.result))
  end

  if Native.null?(prepared.stmt)
    return error("sqlite error: the sql has no statement")
  end

  stmt = prepared.stmt
  more = no_more_statements(conn, prepared.tail)
  case more
    ok(_) -> return ok(stmt)
    error(message) ->
      _ = sqlite3_finalize(stmt)
      return error(message)
  end
end

# The text after the first statement must hold none. It is tried with an out pointer, where NULL can be told, and the
# probe is finalized by hand right after its call. The call is a compute def: if the task is cancelled during the
# parse, the C call still finishes but its result is dropped, so that one probe statement is never finalized (an out
# C.Pointer is not freed on cancel, unlike an out resource).
def no_more_statements(conn: Connection, tail: C.Pointer) -> Result[Void]
  if Native.get_string(tail, 0) == ""
    return ok()
  end

  more = sqlite3_prepare_v2(conn.handle, tail, NUL_TERMINATED)
  if lock_code?(more.result)
    started = Time.monotonic_ms()
    while lock_wait?(conn, more.result, started)
      pause(conn, started)
      more = sqlite3_prepare_v2(conn.handle, tail, NUL_TERMINATED)
    end
  end

  # Text after the first statement that is only comments gives a NULL statement: still one statement.
  if more.result == SQLITE_OK and Native.null?(more.stmt)
    return ok()
  end

  if more.result == SQLITE_OK
    _ = sqlite3_finalize(more.stmt)
  end

  return error("sqlite error: the sql has more than one statement")
end

def bind_all(conn: Connection, stmt: Prepared, params: List[Value]) -> Result[Void]
  wanted = stmt.parameters
  if wanted != params.size
    return error("sqlite error: the sql has #{wanted} #{noun(wanted)}, got #{params.size}")
  end

  index = 1
  for param in params
    code = bind_value(stmt.pointer, index, param)
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

# The shared step loop: every row read with the column names of the statement, or none when `keep` is false. A step
# that gives a row costs one comparison here; the clock and the lock rules are for the step that finds a lock.
def collect(conn: Connection, prepared: Prepared, keep: Bool) -> Result[List[Row]]
  mark_running(conn, prepared.pointer)
  rows = step_all(conn, prepared, keep)
  mark_running(conn, Native.null())
  return rows
end

# Tells `close` which statement the call works with. A task is stopped by a cancel only where it waits: at the step (a
# compute call, which then runs on, its result dropped) or at the sleep for a lock, so that is the span the
# mark covers,
# and the sleep clears it. Whether the step of that moment is still running is told by `note_step`.
def mark_running(conn: Connection, stmt: C.Pointer) -> Void
  address = 0
  if not Native.null?(stmt)
    address = Native.address(stmt)
  end

  conn.statements.counters.put(RUNNING, address)
end

# Records the opcode count of the statement just before its step is dispatched: when the step returns the count is
# higher (see `step_ended?`), and a cancelled call never gets to say that it did.
def note_step(conn: Connection, stmt: C.Pointer) -> Void
  conn.statements.counters.put(STEPS, sqlite3_stmt_status(stmt, STMTSTATUS_VM_STEP, 0))
end

def step_all(conn: Connection, prepared: Prepared, keep: Bool) -> Result[List[Row]]
  stmt = prepared.pointer
  # An interrupt that came between the prepare and the first step is lost (SQLite ignores one while no statement
  # runs), so the deadline is read here. Later steps are left to the interrupt: a statement that SQLite stopped is
  # rolled back by SQLite, which a return from here would skip (a write with RETURNING does its work in the
  # first step).
  if conn.deadline > 0 and Time.monotonic_ms() >= conn.deadline
    return error(failure(conn, SQLITE_INTERRUPT))
  end

  names = prepared.names
  fresh = not keep
  rows: List[Row] = []
  while true
    note_step(conn, stmt)
    code = sqlite3_step(stmt)
    # Written out here, not as a call: the check runs once per row, and a row fails its first comparison. Keep it in
    # sync with `lock_code?`.
    if code != SQLITE_ROW and (code == SqliteLock.SQLITE_BUSY or code == SQLITE_LOCKED)
      stepped = step_after_lock(conn, stmt, code)
      code = stepped.code
      if Native.closed?(conn.handle)
        return error(CLOSED_DURING_CALL)
      end

      # SQLite rolls a write back and runs it again after a wait (a commit refused in a rollback journal), so the
      # rows of the first run are dropped; a read goes on from where it stopped.
      if stepped.waited and sqlite3_stmt_readonly(stmt) == 0
        rows = []
      end
    end

    # A `close` from another task finalized the statement while this step ran: nothing of it is safe to read.
    if Native.closed?(conn.handle)
      return error(CLOSED_DURING_CALL)
    end

    if code == SQLITE_ROW
      if not fresh
        # The first step is where SQLite prepares the statement again when the schema changed (a column was added to
        # a table of `select *`), so the names of the cache may be old: they are read once more then.
        fresh = true
        current = current_statement(conn, prepared)
        if current.duplicate
          return error(duplicate_message(current.names))
        end

        names = current.names
      end

      if keep
        rows = rows.push(read_row(stmt, names))
      end
    elsif code == SQLITE_DONE
      return ok(rows)
    else
      return error(failure(conn, code))
    end
  end

  return ok(rows)
end

# The statement after its first step. One that SQLite did not prepare again is as it was; one that it did gets its
# names read, and the cache is told.
def current_statement(conn: Connection, prepared: Prepared) -> Prepared
  count = sqlite3_stmt_status(prepared.pointer, STMTSTATUS_REPREPARE, 0)
  if count == prepared.reprepares
    return prepared
  end

  names = column_names(prepared.pointer)
  current = prepared.with(
    names: names,
    duplicate: names.uniq.size != names.size,
    parameters: sqlite3_bind_parameter_count(prepared.pointer),
    reprepares: count,
  )

  if prepared.cached
    found = conn.statements.entries.get(prepared.sql)
    case found
      ok(entry) -> conn.statements.entries.put(prepared.sql, entry_with(entry, current))
      error(_) -> return current
    end
  end

  return current
end

def entry_with(entry: Entry, stmt: Prepared) -> Entry
  return entry.with(
    names: stmt.names,
    duplicate: stmt.duplicate,
    parameters: stmt.parameters,
    reprepares: stmt.reprepares,
  )
end

# What is left of a step that found a lock (`code`), tried again while the database stays locked. SQLite documents a
# retry for a COMMIT, which stays open after SQLITE_BUSY, and for a statement outside a transaction. A write that a
# read transaction of this connection asks for is not tried again (`upgrade?`). The wait is counted from here, after
# the first refusal, which SQLite gives at once (its own busy timeout is 0), so the clock is read only on this path.
def step_after_lock(conn: Connection, stmt: C.Pointer, code: Int) -> Stepped
  started = Time.monotonic_ms()
  current = code
  waited = false
  while lock_wait?(conn, current, started) and not upgrade?(conn, stmt)
    mark_running(conn, Native.null())
    pause(conn, started)
    # The sleep is where a `close` from another task can finalize the statement.
    if Native.closed?(conn.handle)
      break
    end

    mark_running(conn, stmt)
    waited = true
    note_step(conn, stmt)
    current = sqlite3_step(stmt)
  end

  return Stepped(code: current, waited: waited)
end

# A statement that writes, in a connection that holds a read lock: SQLite does not wait for the lock of the writer
# (its busy handler is skipped, since the holder of the write lock may be waiting for our read lock, which we keep
# until the write is done), so waiting here would stall the other connection's COMMIT until `busy_timeout` is over,
# and then fail with the same error. `Db.transaction` begins with BEGIN IMMEDIATE, so its statements never get here.
def upgrade?(conn: Connection, stmt: C.Pointer) -> Bool
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

# Whether a result code is SQLITE_BUSY or SQLITE_LOCKED, the two that can be a lock of another connection.
def lock_code?(code: Int) -> Bool
  return code == SqliteLock.SQLITE_BUSY or code == SQLITE_LOCKED
end

# True when `code` says that another connection holds a lock and the wait that began at `started` is not over, so
# the caller pauses and tries again. The codes are checked first, so a call that succeeded asks nothing of SQLite.
def lock_wait?(conn: Connection, code: Int, started: Int) -> Bool
  if not lock_code?(code)
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

# The type of each value is asked of SQLite every time, since a column of one statement can hold a different type in
# each row. The value is read in this loop, not in a function, because it runs for every column of every row.
def read_row(stmt: C.Pointer, names: List[String]) -> Row
  row: Row = {}
  col = 0
  for name in names
    kind = sqlite3_column_type(stmt, col)
    if kind == SQLITE_INTEGER
      row = row.put(name, Value.Int(sqlite3_column_int64(stmt, col)))
    elsif kind == SQLITE_TEXT
      # The pointer first, then its length: sqlite3_column_bytes is only right after the conversion.
      text = sqlite3_column_text(stmt, col)
      row = row.put(name, Value.Text(Native.get_string(text, 0, sqlite3_column_bytes(stmt, col))))
    elsif kind == SQLITE_FLOAT
      row = row.put(name, Value.Float(sqlite3_column_double(stmt, col)))
    elsif kind == SQLITE_BLOB
      blob = sqlite3_column_blob(stmt, col)
      row = row.put(name, Value.Blob(Native.get_bytes(blob, 0, sqlite3_column_bytes(stmt, col))))
    else
      row = row.put(name, Value.Null)
    end

    col += 1
  end

  return row
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
