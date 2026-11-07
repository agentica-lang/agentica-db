## The FFI driver of the SQLite adapter: the system libsqlite3 through `extern` calls, one call per C function and a
## compute call per step. The adapter runs it where the library of the native driver (`native.agc`) does not load, as
## in compiled bytecode run where the built library is gone. Each statement is prepared at its call and finalized after
## it.

import SqliteLock from "lock"
import SqliteWait from "wait"
import {Row, Value} from "../support/value"

SQLITE_OK = 0
SQLITE_ROW = 100
SQLITE_DONE = 101
SQLITE_INTEGER = 1
SQLITE_FLOAT = 2
SQLITE_TEXT = 3
SQLITE_BLOB = 4
# The state of a connection with a read transaction open, for `sqlite3_txn_state`, which SQLite has since 3.34.0
# (3034000 for `sqlite3_libversion_number`). A system library that is older never says it, and the write is waited for.
SQLITE_TXN_READ = 1
TXN_STATE_VERSION = 3_034_000
# The length argument that means "up to the NUL" for the sql.
NUL_TERMINATED = -1
# The destructor argument SQLITE_TRANSIENT, which makes SQLite copy the bound value.
TRANSIENT_DESTRUCTOR = -1

# A connection and the wait of the call that runs on it.
struct Conn
  handle: Handle
  wait: SqliteWait.Wait
end

# The code of a step and whether it waited for a lock before: a statement that writes and was run again by SQLite
# gives its rows from the start.
struct Stepped
  code: Int
  waited: Bool
end

extern "sqlite3"
  ## An open database; `Native.close` closes it.
  export resource Handle, free: sqlite3_close_v2
  resource Stmt, free: sqlite3_finalize
  compute def sqlite3_open_v2(filename: C.String, out db: Handle, flags: C.Int32, vfs: C.Pointer) -> C.Int32
  def sqlite3_extended_errcode(db: Handle) -> C.Int32
  def sqlite3_errmsg(db: Handle) -> C.String
  def sqlite3_errstr(code: C.Int32) -> C.String
  ## Stops the statement that runs on the connection, which then fails with `sqlite error 9: interrupted`.
  export def sqlite3_interrupt(db: Handle) -> Void
  ## 0 while a transaction is open.
  export def sqlite3_get_autocommit(db: Handle) -> C.Int32
  def sqlite3_changes(db: Handle) -> C.Int32
  def sqlite3_total_changes(db: Handle) -> C.Int32
  # Prepare is compute too: a big schema makes it slow. The probe is the same C function with an out pointer.
  compute def sqlite3_prepare_v2(db: Handle, sql: C.Pointer, bytes: C.Int32, out stmt: Stmt,
                                 out tail: C.Pointer) -> C.Int32
  compute def sqlite3_probe(db: Handle, sql: C.Pointer, bytes: C.Int32, out stmt: C.Pointer,
                            out tail: C.Pointer) -> C.Int32 = "sqlite3_prepare_v2"
  compute def sqlite3_step(stmt: Stmt) -> C.Int32
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

## Opens a database with `flags` (of `sqlite3_open_v2`).
export def open(path: String, flags: Int) -> Result[Handle]
  try load_library()
  opened = sqlite3_open_v2(path, flags, Native.pointer(0))
  if opened.result != SQLITE_OK
    # The handle may be NULL (out of memory), which errmsg cannot take, so the text comes from the code.
    Native.close(opened.db)
    return error("sqlite error #{opened.result}: #{sqlite3_errstr(opened.result)}")
  end

  return ok(opened.db)
end

## Runs one statement and gives its rows.
export def query(handle: Handle, wait: SqliteWait.Wait, sql: String, params: List[Value]) -> Result[List[Row]]
  return run_query(Conn(handle: handle, wait: wait), sql, params)
end

## Runs one statement for its effect and gives the number of rows it inserted, updated or deleted.
export def execute(handle: Handle, wait: SqliteWait.Wait, sql: String, params: List[Value]) -> Result[Int]
  return run_execute(Conn(handle: handle, wait: wait), sql, params)
end

def run_query(conn: Conn, sql: String, params: List[Value]) -> Result[List[Row]]
  stmt = try prepare(conn, sql, params)
  names = column_names(stmt)
  if names.uniq.size != names.size
    Native.close(stmt)
    return error("sqlite error: the result has the column #{repeated_name(names)} twice, alias one of them")
  end

  rows = collect(conn, stmt, names, true)
  Native.close(stmt)
  return rows
end

def run_execute(conn: Conn, sql: String, params: List[Value]) -> Result[Int]
  stmt = try prepare(conn, sql, params)
  before = sqlite3_total_changes(conn.handle)
  # A statement that returns rows is run for its effect: its rows are stepped over, not read.
  ran = collect(conn, stmt, [], false)
  Native.close(stmt)
  try ran
  return ok(changes_since(conn, before))
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

def changes_since(conn: Conn, before: Int) -> Int
  # sqlite3_changes keeps the count of the last row-changing statement, so a statement that changed nothing
  # (a CREATE TABLE after an INSERT) must not report it.
  if sqlite3_total_changes(conn.handle) == before
    return 0
  end

  return sqlite3_changes(conn.handle)
end

# The sql holds no NUL: the adapter refuses one before it gets here.
def prepare(conn: Conn, sql: String, params: List[Value]) -> Result[Stmt]
  # The sql goes through an owned buffer, not a C.String: SQLite points `tail` into its copy, and a C.String copy
  # lives only during the call.
  made: Result[Stmt] = Native.from_string(sql) do |buf| prepare_buffer(conn, buf) end
  stmt = try made
  bound = bind_all(conn, stmt, params)
  case bound
    ok(_) -> return ok(stmt)
    error(message) ->
      Native.close(stmt)
      return error(message)
  end
end

# Prepares the first statement in the buffer, waiting for a lock like a step does, and refuses a second one. SQLite
# gives a NULL statement for sql that holds only whitespace and comments, which an out resource shows as a closed one.
def prepare_buffer(conn: Conn, buf: C.Pointer) -> Result[Stmt]
  prepared = sqlite3_prepare_v2(conn.handle, buf, NUL_TERMINATED)
  if SqliteWait.lock_code?(prepared.result)
    started = Time.monotonic_ms()
    while lock_wait?(conn, prepared.result, started)
      SqliteWait.pause(conn.wait, started)
      prepared = sqlite3_prepare_v2(conn.handle, buf, NUL_TERMINATED)
    end
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
# C.Pointer is not freed on cancel, unlike an out resource). It is freed when the connection closes.
def no_more_statements(conn: Conn, tail: C.Pointer) -> Result[Void]
  if Native.get_string(tail, 0) == ""
    return ok()
  end

  more = sqlite3_probe(conn.handle, tail, NUL_TERMINATED)
  if SqliteWait.lock_code?(more.result)
    started = Time.monotonic_ms()
    while lock_wait?(conn, more.result, started)
      SqliteWait.pause(conn.wait, started)
      more = sqlite3_probe(conn.handle, tail, NUL_TERMINATED)
    end
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

def bind_all(conn: Conn, stmt: Stmt, params: List[Value]) -> Result[Void]
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

# The shared step loop: every row read with the given column names, or none when `keep` is false. A step that gives a
# row costs one comparison here; the clock and the lock rules are for the step that finds a lock.
def collect(conn: Conn, stmt: Stmt, names: List[String], keep: Bool) -> Result[List[Row]]
  # An interrupt that came between the prepare and the first step is lost (SQLite ignores one while no statement
  # runs), so the deadline is read here. Later steps are left to the interrupt: a statement that SQLite stopped is
  # rolled back by SQLite, which a return from here would skip (a write with RETURNING does its work in the
  # first step).
  if SqliteWait.expired?(conn.wait)
    return error(SqliteWait.INTERRUPTED)
  end

  rows: List[Row] = []
  while true
    code = sqlite3_step(stmt)
    # Written out here, not as a call: the check runs once per row, and a row fails its first comparison. Keep it in
    # sync with `SqliteWait.lock_code?`.
    if code != SQLITE_ROW and (code == SqliteLock.SQLITE_BUSY or code == SqliteWait.SQLITE_LOCKED)
      stepped = step_after_lock(conn, stmt, code)
      code = stepped.code
      # SQLite rolls a write back and runs it again after a wait (a commit refused in a rollback journal), so the
      # rows of the first run are dropped; a read goes on from where it stopped.
      if stepped.waited and sqlite3_stmt_readonly(stmt) == 0
        rows = []
      end
    end

    if code == SQLITE_ROW
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

# What is left of a step that found a lock (`code`), tried again while the database stays locked. SQLite documents a
# retry for a COMMIT, which stays open after SQLITE_BUSY, and for a statement outside a transaction. A write that a
# read transaction of this connection asks for is not tried again (`upgrade?`). The wait is counted from here, after
# the first refusal, which SQLite gives at once (its own busy timeout is 0), so the clock is read only on this path.
def step_after_lock(conn: Conn, stmt: Stmt, code: Int) -> Stepped
  started = Time.monotonic_ms()
  current = code
  waited = false
  while lock_wait?(conn, current, started) and not upgrade?(conn, stmt)
    SqliteWait.pause(conn.wait, started)
    waited = true
    current = sqlite3_step(stmt)
  end

  return Stepped(code: current, waited: waited)
end

# A statement that writes, in a connection that holds a read lock: SQLite does not wait for the lock of the writer
# (its busy handler is skipped, since the holder of the write lock may be waiting for our read lock, which we keep
# until the write is done), so waiting here would stall the other connection's COMMIT until `busy_timeout` is over,
# and then fail with the same error. `Db.transaction` begins with BEGIN IMMEDIATE, so its statements never get here.
def upgrade?(conn: Conn, stmt: Stmt) -> Bool
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

# Whether the wait for the lock that `code` reports goes on, asking SQLite for the extended code only for a lock.
def lock_wait?(conn: Conn, code: Int, started: Int) -> Bool
  if not SqliteWait.lock_code?(code)
    return false
  end

  return SqliteWait.lock_wait?(conn.wait, code, sqlite3_extended_errcode(conn.handle), started)
end

def column_names(stmt: Stmt) -> List[String]
  names: List[String] = []
  count = sqlite3_column_count(stmt)
  for col in 0...count
    names = names.push(sqlite3_column_name(stmt, col))
  end

  return names
end

# The type of each value is asked of SQLite every time, since a column of one statement can hold a different type in
# each row. The value is read in this loop, not in a function, because it runs for every column of every row.
def read_row(stmt: Stmt, names: List[String]) -> Row
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
def failure(conn: Conn, code: Int) -> String
  if code == SqliteWait.SQLITE_INTERRUPT
    return SqliteWait.INTERRUPTED
  end

  return "sqlite error #{code}: #{sqlite3_errmsg(conn.handle)}"
end

# A second block, because a probe statement is finalized through its pointer and the free function of the first
# block's Stmt cannot be declared there. The probe is finalized once, here, and never becomes a resource.
extern "sqlite3"
  def sqlite3_finalize_pointer(stmt: C.Pointer) -> C.Int32 = "sqlite3_finalize"
end
