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
## the exact text of the sql, so a statement that runs again is not parsed and planned again. A task of its own, the
## keeper, owns them: a statement dies with its preparing task, and a connection of a pool is used by a new task for
## each block. The keeper is a child of the task that opened the connection, so it ends with it, and its statements
## with it; `close` ends them first. A call takes a statement from the keeper and gives it back reset and with no
## bindings, also after a failure. A statement that runs is not in the cache, so a second call for the same sql
## (another task on the same connection) gets a statement of its own, which is cached when it comes back if the sql has
## no idle one.
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
# The start of the error of a result with two columns of one name: its statement is not kept.
DUPLICATE_COLUMNS = "sqlite error: the result has the column"
# How long the keeper waits for a message before it looks whether the connection is still open (the end of the task
# that opened it closes it, with no word to the keeper), how long a caller waits to hand it one, and how long a caller
# waits after a busy connection's own time for the answer (the keeper may be preparing for a lock).
KEEPER_POLL_MS = 50
SEND_MS = 5_000
ANSWER_SLACK_MS = 10_000
# The size of the queue of the keeper: a call has at most two messages in it.
INBOX_SIZE = 256
# The destructor argument SQLITE_TRANSIENT, which makes SQLite copy the bound value.
TRANSIENT_DESTRUCTOR = -1

## An open database, the time its statements wait for a lock, and the limit of a statement (0: none). `handle` is
## public because a struct has no private fields, but its type is not exported (a user cannot name it): treat it as
## opaque and pass the `Connection` around. `deadline` is set only on the copy that a bounded call works with.
## `inbox` is the queue of the keeper of the statement cache, which holds `cache_limit` statements at most.
export struct Connection
  handle: Handle
  busy_timeout: Int
  inbox: Channel[Msg]
  cache_limit: Int
  timeout_ms: Int = 0
  deadline: Int = 0
end

# What a call says to the keeper of the statement cache of a connection. `Take` (connection, sql, reply) asks for a
# statement for the sql and gets it on the reply channel; `Give` (id, sql, keep) hands one back (`keep` false: it
# is not
# fit for another use); `Shut` (reply) finalizes every statement, whoever holds it, and says so on its channel.
enum Msg
  Take(Connection, String, Channel[Result[Granted]])
  Give(Int, String, Bool)
  Shut(Channel[Bool])
end

# A statement the keeper lends, with the id it knows it by, and whether it was just prepared (the names of its columns
# are then current, which a statement of the cache has to check after its first step).
struct Granted
  id: Int
  stmt: Stmt
  fresh: Bool
end

# What a call works with: a statement of the keeper (`cached`, with its id) or one of its own, which it closes.
struct Held
  stmt: Stmt
  id: Int
  cached: Bool
  fresh: Bool
end

# What the keeper starts with.
struct Keeping
  inbox: Channel[Msg]
  limit: Int
  handle: Handle
end

# What the keeper knows: the statements nobody holds, by sql (`idle`, with `order` oldest first), and every statement
# it made and has not finalized (`all`), by id, because a statement that a cancelled call held is in neither of the
# first two and still has to be finalized at the end.
struct Shelf
  limit: Int
  idle: Map[String, Int]
  order: List[String]
  all: Map[Int, Stmt]
  next_id: Int
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
  resource Stmt, free: sqlite3_finalize
  compute def sqlite3_open_v2(filename: C.String, out db: Handle, flags: C.Int32, vfs: C.Pointer) -> C.Int32
  def sqlite3_extended_errcode(db: Handle) -> C.Int32
  def sqlite3_errmsg(db: Handle) -> C.String
  def sqlite3_errstr(code: C.Int32) -> C.String
  def sqlite3_interrupt(db: Handle) -> Void
  def sqlite3_get_autocommit(db: Handle) -> C.Int32
  def sqlite3_changes(db: Handle) -> C.Int32
  def sqlite3_total_changes(db: Handle) -> C.Int32
  # Prepare is compute too: a big schema makes it slow. The probe is the same C function with an out pointer.
  compute def sqlite3_prepare_v2(db: Handle, sql: C.Pointer, bytes: C.Int32, out stmt: Stmt,
                                 out tail: C.Pointer) -> C.Int32
  compute def sqlite3_probe(db: Handle, sql: C.Pointer, bytes: C.Int32, out stmt: C.Pointer,
                            out tail: C.Pointer) -> C.Int32 = "sqlite3_prepare_v2"
  compute def sqlite3_step(stmt: Stmt) -> C.Int32
  def sqlite3_reset(stmt: Stmt) -> C.Int32
  def sqlite3_clear_bindings(stmt: Stmt) -> C.Int32
  def sqlite3_stmt_status(stmt: Stmt, op: C.Int32, reset: C.Int32) -> C.Int32
  def sqlite3_stmt_readonly(stmt: Stmt) -> C.Int32
  def sqlite3_libversion_number() -> C.Int32
  def sqlite3_txn_state(db: Handle, schema: C.Pointer) -> C.Int32
  def sqlite3_bind_parameter_count(stmt: Stmt) -> C.Int32
  def sqlite3_bind_null(stmt: Stmt, index: C.Int32) -> C.Int32
  def sqlite3_bind_int64(stmt: Stmt, index: C.Int32, value: C.Int64) -> C.Int32
  def sqlite3_bind_double(stmt: Stmt, index: C.Int32, value: C.Double) -> C.Int32
  def sqlite3_bind_text(stmt: Stmt, index: C.Int32, text: C.Pointer, bytes: C.Int32, destructor: C.Pointer) -> C.Int32
  def sqlite3_bind_blob(stmt: Stmt, index: C.Int32, blob: C.Bytes, bytes: C.Int32, destructor: C.Pointer) -> C.Int32
  def sqlite3_bind_zeroblob(stmt: Stmt, index: C.Int32, bytes: C.Int32) -> C.Int32
  def sqlite3_column_count(stmt: Stmt) -> C.Int32
  def sqlite3_column_name(stmt: Stmt, col: C.Int32) -> C.String
  def sqlite3_column_type(stmt: Stmt, col: C.Int32) -> C.Int32
  def sqlite3_column_int64(stmt: Stmt, col: C.Int32) -> C.Int64
  def sqlite3_column_double(stmt: Stmt, col: C.Int32) -> C.Double
  def sqlite3_column_text(stmt: Stmt, col: C.Int32) -> C.Pointer
  def sqlite3_column_blob(stmt: Stmt, col: C.Int32) -> C.Pointer
  def sqlite3_column_bytes(stmt: Stmt, col: C.Int32) -> C.Int32
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

  inbox: Channel[Msg] = Channel.new(INBOX_SIZE)
  conn = Connection(
    handle: opened.db,
    busy_timeout: target.settings.busy_timeout,
    inbox: inbox,
    cache_limit: 0,
    timeout_ms: target.settings.timeout_ms,
  )

  # The setup statements run once: they go without the cache, and so without its keeper.
  configured = configure(conn, target.settings)
  case configured
    ok(_) -> return ok(start_cache(conn, target.settings.statement_cache))
    error(message) ->
      Native.close(opened.db)
      return error(message)
  end
end

## Closes the connection, after its cached statements; closing it again does nothing. Closing the last connection of a
## WAL database checkpoints it, which can take a while: this call blocks the task meanwhile.
export def close(conn: Connection) -> Void
  if conn.cache_limit > 0 and not Native.closed?(conn.handle)
    shut_cache(conn)
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
  rows = query_statement(conn, held)
  release(conn, sql, held, not duplicate_columns?(rows))
  return rows
end

# A statement just prepared has its columns checked before it runs, so that a statement that would give two columns
# one name does not run (it may write: `insert ... returning`). A statement of the cache was checked when it was
# prepared, and `collect` checks it again when SQLite prepared it again since.
def query_statement(conn: Connection, held: Held) -> Result[List[Row]]
  names = column_names(held.stmt)
  if held.fresh
    try unique_names(names)
  end

  return collect(conn, held.stmt, names, true)
end

def run_execute(conn: Connection, sql: String, params: List[Value]) -> Result[Int]
  held = try acquire(conn, sql, params)
  before = sqlite3_total_changes(conn.handle)
  # A statement that returns rows is run for its effect: its rows are stepped over, not read.
  ran = collect(conn, held.stmt, [], false)
  release(conn, sql, held, true)
  try ran
  return ok(changes_since(conn, before))
end

def unique_names(names: List[String]) -> Result[Void]
  if names.uniq.size != names.size
    return error("#{DUPLICATE_COLUMNS} #{repeated_name(names)} twice, alias one of them")
  end

  return ok()
end

# A statement whose columns have one name twice is finalized, not kept: when the schema changes it must be prepared
# again, and SQLite would not do it by itself for a statement that never got to run.
def duplicate_columns?(rows: Result[List[Row]]) -> Bool
  case rows
    ok(_) -> return false
    error(message) -> return message.start_with?(DUPLICATE_COLUMNS)
  end
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

# A statement for `sql` with `params` bound: one of the cache, or a new one.
def acquire(conn: Connection, sql: String, params: List[Value]) -> Result[Held]
  if has_nul?(sql)
    return error("sqlite error: the sql contains a NUL character")
  end

  held = try take(conn, sql)
  bound = bind_all(conn, held.stmt, params)
  case bound
    ok(_) -> return ok(held)
    error(message) ->
      release(conn, sql, held, true)
      return error(message)
  end
end

# Asks the keeper for a statement. A connection without a cache, a closed one (the call that follows stops with the
# runtime error of a closed handle, as it always did) and a keeper that does not answer get a statement of their own.
def take(conn: Connection, sql: String) -> Result[Held]
  if conn.cache_limit == 0 or Native.closed?(conn.handle)
    return own_statement(conn, sql)
  end

  reply: Channel[Result[Granted]] = Channel.new(1)
  sent = conn.inbox.send(Msg.Take(conn, sql, reply), SEND_MS)
  if not sent.ok?
    return own_statement(conn, sql)
  end

  answer = reply.recv(conn.busy_timeout + ANSWER_SLACK_MS)
  case answer
    error(_) -> return own_statement(conn, sql)
    ok(granted) ->
      case granted
        error(message) -> return error(message)
        ok(lent) -> return ok(Held(stmt: lent.stmt, id: lent.id, cached: true, fresh: lent.fresh))
      end
  end
end

def own_statement(conn: Connection, sql: String) -> Result[Held]
  stmt = try prepare_new(conn, sql)
  return ok(Held(stmt: stmt, id: 0, cached: false, fresh: true))
end

# Ends a call's use of a statement. A statement of the keeper is reset (which also stops one that is half way through
# its rows, after a failed step or a deadline) and loses its bindings before it goes back; `keep` false has it
# finalized. A statement of the call's own is finalized. A statement the connection's close has finalized already is
# left alone.
def release(conn: Connection, sql: String, held: Held, keep: Bool) -> Void
  if Native.closed?(held.stmt)
    return
  end

  if not held.cached
    Native.close(held.stmt)
    return
  end

  sqlite3_reset(held.stmt)
  sqlite3_clear_bindings(held.stmt)
  _ = conn.inbox.send(Msg.Give(held.id, sql, keep), SEND_MS)
end

# Starts the keeper, a child of the task that opens the connection. The `Connection` that gives its statements a limit
# is the one that is returned.
def start_cache(conn: Connection, limit: Int) -> Connection
  if limit == 0
    return conn
  end

  _ = Task.spawn(&keep, Keeping(inbox: conn.inbox, limit: limit, handle: conn.handle))
  return conn.with(cache_limit: limit)
end

# Has the keeper finalize every statement and waits for it, so that SQLite closes the connection at once and not when
# the last statement is finalized. A keeper that is busy preparing is waited for as long as a prepare can last.
def shut_cache(conn: Connection) -> Void
  reply: Channel[Bool] = Channel.new(1)
  sent = conn.inbox.send(Msg.Shut(reply), SEND_MS)
  if sent.ok?
    _ = reply.recv(conn.busy_timeout + ANSWER_SLACK_MS)
  end
end

# The keeper: one task for the statements of a connection, which owns them all. It serves one message at a time, so
# the statements need no lock, and what it owns is finalized by the end of the task, whatever ends it.
def keep(args: Keeping) -> Void
  shelf = Shelf(limit: args.limit, idle: {}, order: [], all: {}, next_id: 1)
  running = true
  while running
    case args.inbox.recv(KEEPER_POLL_MS)
      error(_) ->
        # The statements have to go before SQLite can close a connection whose task has ended.
        if Native.closed?(args.handle) or (args.inbox.closed? and args.inbox.empty?)
          finalize_all(shelf)
          running = false
        end

      ok(msg) ->
        case msg
          Msg.Take(conn, sql, reply) -> shelf = lend(shelf, conn, sql, reply)
          Msg.Give(id, sql, keepit) -> shelf = shelve(shelf, id, sql, keepit)
          Msg.Shut(reply) ->
            finalize_all(shelf)
            _ = reply.send(true, SEND_MS)
            running = false
        end
    end
  end
end

# Lends the idle statement of the sql, or prepares a new one. A new statement is the keeper's own, whoever asked.
def lend(shelf: Shelf, conn: Connection, sql: String, reply: Channel[Result[Granted]]) -> Shelf
  idle_id = shelf.idle.get(sql)
  case idle_id
    some(id) ->
      _ = reply.send(ok(Granted(id: id, stmt: shelf.all[id], fresh: false)), SEND_MS)
      return shelf.with(idle: shelf.idle.delete(sql), order: shelf.order.select do |kept| kept != sql end)

    none -> return lend_new(shelf, conn, sql, reply)
  end
end

def lend_new(shelf: Shelf, conn: Connection, sql: String, reply: Channel[Result[Granted]]) -> Shelf
  # The connection may have been closed since the caller looked: a prepare would stop the keeper.
  if Native.closed?(conn.handle)
    _ = reply.send(error("sqlite error: the connection is closed"), SEND_MS)
    return shelf
  end

  made = prepare_new(conn, sql)
  case made
    error(message) ->
      _ = reply.send(error(message), SEND_MS)
      return shelf

    ok(stmt) ->
      id = shelf.next_id
      _ = reply.send(ok(Granted(id: id, stmt: stmt, fresh: true)), SEND_MS)
      return shelf.with(all: shelf.all.put(id, stmt), next_id: id + 1)
  end
end

# Takes a statement back: idle, as the newest, unless it is not fit or the sql has an idle one already (two calls ran
# it at once), in which case it is finalized. The oldest idle statements over the limit are finalized.
def shelve(shelf: Shelf, id: Int, sql: String, keepit: Bool) -> Shelf
  if not shelf.all.key?(id)
    return shelf
  end

  if not keepit or shelf.idle.key?(sql)
    Native.close(shelf.all[id])
    return shelf.with(all: shelf.all.delete(id))
  end

  idle = shelf.idle.put(sql, id)
  order = shelf.order.push(sql)
  return evict(shelf.with(idle: idle, order: order))
end

def evict(shelf: Shelf) -> Shelf
  current = shelf
  while current.idle.size > current.limit
    oldest = current.order[0]
    id = current.idle[oldest]
    Native.close(current.all[id])
    current = current.with(
      idle: current.idle.delete(oldest),
      order: current.order.drop(1),
      all: current.all.delete(id),
    )
  end

  return current
end

# Closing a statement that a call is stepping is the runtime's business: the free waits for the call to return.
def finalize_all(shelf: Shelf) -> Void
  for stmt in shelf.all.values
    Native.close(stmt)
  end
end

# A new statement for the one statement in `sql`, owned by the task that calls. The sql goes through an owned buffer,
# not a C.String: SQLite points `tail` into its copy, and a C.String copy lives only during the call.
def prepare_new(conn: Connection, sql: String) -> Result[Stmt]
  made: Result[Stmt] = Native.from_string(sql) do |buf| prepare_buffer(conn, buf) end
  return made
end

# Prepares the first statement in the buffer, waiting for a lock like a step does, and refuses a second one. SQLite
# gives a NULL statement for sql that holds only whitespace and comments, which an out resource shows as a closed one.
def prepare_buffer(conn: Connection, buf: C.Pointer) -> Result[Stmt]
  started = Time.monotonic_ms()
  prepared = sqlite3_prepare_v2(conn.handle, buf, NUL_TERMINATED)
  while lock_wait?(conn, prepared.result, started)
    pause(conn, started)
    prepared = sqlite3_prepare_v2(conn.handle, buf, NUL_TERMINATED)
  end

  if prepared.result != SQLITE_OK
    return error(failure(conn, prepared.result))
  end

  if Native.closed?(prepared.stmt)
    return error("sqlite error: the sql has no statement")
  end

  stmt = prepared.stmt
  more = no_more_statements(conn, prepared.tail)
  case more
    ok(_) -> return ok(stmt)
    error(message) ->
      Native.close(stmt)
      return error(message)
  end
end

# The text after the first statement must hold none. It is tried with an out pointer, where NULL can be told, and the
# probe is finalized by hand right after its call. The call is a compute def: if the task is cancelled during the
# parse, the C call still finishes but its result is dropped, so that one probe statement is never finalized (an out
# C.Pointer is not freed on cancel, unlike an out resource). SQLite frees it when the connection closes.
def no_more_statements(conn: Connection, tail: C.Pointer) -> Result[Void]
  if Native.get_string(tail, 0) == ""
    return ok()
  end

  started = Time.monotonic_ms()
  more = sqlite3_probe(conn.handle, tail, NUL_TERMINATED)
  while lock_wait?(conn, more.result, started)
    pause(conn, started)
    more = sqlite3_probe(conn.handle, tail, NUL_TERMINATED)
  end

  # Text after the first statement that is only comments gives a NULL statement: still one statement.
  if more.result == SQLITE_OK and Native.null?(more.stmt)
    return ok()
  end

  if more.result == SQLITE_OK
    sqlite3_finalize_pointer(more.stmt)
  end

  return error("sqlite error: the sql has more than one statement")
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

def bind_value(stmt: Stmt, index: Int, value: Value) -> Int
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
def bind_text(stmt: Stmt, index: Int, text: String) -> Int
  code: Int = Native.from_string(text) do |buf| sqlite3_bind_text(stmt, index, buf, text.bytesize, transient()) end

  return code
end

def bind_blob(stmt: Stmt, index: Int, bytes: Bytes) -> Int
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
      # A statement of the cache that SQLite prepared again at its first step (a schema change since its last use) may
      # have other columns than the ones read before the step.
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

def column_names(stmt: Stmt) -> List[String]
  names: List[String] = []
  count = sqlite3_column_count(stmt)
  for col in 0...count
    names = names.push(sqlite3_column_name(stmt, col))
  end

  return names
end

def read_row(stmt: Stmt, names: List[String]) -> Row
  row: Row = {}
  index = 0
  for name in names
    row = row.put(name, read_value(stmt, index))
    index += 1
  end

  return row
end

def read_value(stmt: Stmt, col: Int) -> Value
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

# A second block, because a probe statement is finalized through its pointer and the free function of the first
# block's Stmt cannot be declared there. The probe is finalized once, here, and never becomes a resource.
extern "sqlite3"
  def sqlite3_finalize_pointer(stmt: C.Pointer) -> C.Int32 = "sqlite3_finalize"
end
