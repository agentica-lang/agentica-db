## The SQLite adapter, through the system libsqlite3.
##
## `open` gives a `Handle`, which the task that opened it owns: close it with `close`, or the end of the task
## closes it (a transaction still open is rolled back). Using a closed handle is a runtime error
## (`RUNTIME-NATIVE-CLOSED`).
##
## `open` sets up the connection for a web app, and the parameters after a `?` change it: `journal_mode` (`wal`,
## `delete`, `truncate`, `persist`, `memory` or `off`; default `wal`), `foreign_keys` (`on` or `off`; default `on`),
## `busy_timeout` (milliseconds, default 5000) and `fts5=required` (the open fails when this SQLite has no FTS5).
## `sqlite:app.db?journal_mode=delete&foreign_keys=off` is SQLite's own behavior.
##
## An engine failure is `sqlite error <code>: <message>`; a bad input is `sqlite error: <message>`.

import {Row, Value} from "value"

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
MAX_BUSY_TIMEOUT_DIGITS = 9
JOURNAL_MODES = ["wal", "delete", "truncate", "persist", "memory", "off"]
# The length argument that means "up to the NUL" for the sql.
NUL_TERMINATED = -1
# The destructor argument SQLITE_TRANSIENT, which makes SQLite copy the bound value.
TRANSIENT_DESTRUCTOR = -1

extern "sqlite3"
  ## An open database.
  export resource Handle, free: sqlite3_close_v2
  resource Stmt, free: sqlite3_finalize
  compute def sqlite3_open(filename: C.String, out db: Handle) -> C.Int32
  def sqlite3_busy_timeout(db: Handle, ms: C.Int32) -> C.Int32
  def sqlite3_errmsg(db: Handle) -> C.String
  def sqlite3_errstr(code: C.Int32) -> C.String
  def sqlite3_changes(db: Handle) -> C.Int32
  def sqlite3_total_changes(db: Handle) -> C.Int32
  # Prepare is compute too: a big schema makes it slow. The probe is the same C function with an out pointer.
  compute def sqlite3_prepare_v2(db: Handle, sql: C.Pointer, bytes: C.Int32, out stmt: Stmt,
                                 out tail: C.Pointer) -> C.Int32
  compute def sqlite3_probe(db: Handle, sql: C.Pointer, bytes: C.Int32, out stmt: C.Pointer,
                            out tail: C.Pointer) -> C.Int32 = "sqlite3_prepare_v2"
  compute def sqlite3_step(stmt: Stmt) -> C.Int32
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

## What a url sets besides the path. The defaults suit a web app: WAL lets readers run beside the one writer,
## foreign keys are checked, and a busy database is waited for, not failed at once.
struct Settings
  journal_mode: String = "wal"
  foreign_keys: Bool = true
  busy_timeout: Int = 5000
  fts5: Bool = false
end

struct Target
  path: String
  settings: Settings
end

## Opens a database file, or `:memory:`; the file is created when it does not exist. A `?` ends the path and starts
## the settings (see the top of this file); a path that holds a `?` cannot be opened by name.
export def open(path: String) -> Result[Handle]
  if has_nul?(path)
    return error("sqlite error: the path contains a NUL character")
  end

  target = try read_target(path)
  try load_library()
  opened = sqlite3_open(target.path)
  if opened.result != SQLITE_OK
    # The handle may be NULL (out of memory), which errmsg cannot take, so the text comes from the code.
    Native.close(opened.db)
    return error("sqlite error #{opened.result}: #{sqlite3_errstr(opened.result)}")
  end

  configured = configure(opened.db, target.settings)
  case configured
    ok(_) -> return ok(opened.db)
    error(message) ->
      Native.close(opened.db)
      return error(message)
  end
end

## Closes the handle; closing it again does nothing. Closing the last connection of a WAL database checkpoints
## it, which can take a while: this call blocks the task meanwhile.
export def close(conn: Handle) -> Void
  Native.close(conn)
end

## Runs one statement with bound parameters and gives its rows, which are empty for a statement without a result.
## Two columns with one name are an error: alias them.
export def query(conn: Handle, sql: String, params: List[Value]) -> Result[List[Row]]
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

## Runs one statement with bound parameters and gives the number of rows it inserted, updated or deleted.
export def execute(conn: Handle, sql: String, params: List[Value]) -> Result[Int]
  stmt = try prepare(conn, sql, params)
  before = sqlite3_total_changes(conn)
  # A statement that returns rows is run for its effect: its rows are stepped over, not read.
  ran = collect(conn, stmt, [], false)
  Native.close(stmt)
  try ran
  return ok(changes_since(conn, before))
end

# The text before the first `separator` and the text after it (empty when there is none).
def split_once(text: String, separator: String) -> List[String]
  found = text.index_of(separator)
  case found
    some(at) -> return [text.slice(0, at), text.slice(at + 1, text.length - at - 1)]
    none -> return [text, ""]
  end
end

def one_of?(choices: List[String], value: String) -> Bool
  return choices.any? do |choice| choice == value end
end

def read_target(text: String) -> Result[Target]
  halves = split_once(text, "?")
  if not text.include?("?")
    return ok(Target(path: text, settings: Settings()))
  end

  settings = try read_settings(halves[1])
  return ok(Target(path: halves[0], settings: settings))
end

def read_settings(query: String) -> Result[Settings]
  settings = Settings()
  if query.empty?
    return ok(settings)
  end

  for pair in query.split("&")
    halves = split_once(pair, "=")
    name = halves[0]
    value = halves[1]
    if name == "journal_mode" and one_of?(JOURNAL_MODES, value)
      settings = settings.with(journal_mode: value)
    elsif name == "foreign_keys" and one_of?(["on", "off"], value)
      settings = settings.with(foreign_keys: value == "on")
    elsif name == "busy_timeout"
      settings = settings.with(busy_timeout: try read_milliseconds(value))
    elsif name == "fts5" and value == "required"
      settings = settings.with(fts5: true)
    elsif one_of?(["journal_mode", "foreign_keys", "fts5"], name)
      return error("sqlite error: the url parameter #{name} has a value that is not allowed: #{value}")
    else
      return error("sqlite error: unknown url parameter #{name}, expected journal_mode, foreign_keys, busy_timeout " +
                   "or fts5")
    end
  end

  return ok(settings)
end

# A non-empty run of ASCII digits, short enough for the C int of sqlite3_busy_timeout.
def read_milliseconds(text: String) -> Result[Int]
  bytes = text.bytes.to_a
  if bytes.empty? or bytes.size > MAX_BUSY_TIMEOUT_DIGITS or bytes.any? do |byte| byte < 48 or byte > 57 end
    return error("sqlite error: the url busy_timeout is not a number of milliseconds")
  end

  return text.to_i
end

# The busy timeout goes first: changing the journal mode needs a lock that another connection may hold.
def configure(conn: Handle, settings: Settings) -> Result[Void]
  sqlite3_busy_timeout(conn, settings.busy_timeout)
  if settings.fts5 and not fts5?(conn)
    return error("sqlite error: this SQLite was built without FTS5 (fts5=required)")
  end

  # Set in both cases: a build can turn foreign keys on by default.
  try execute(conn, "PRAGMA foreign_keys = #{on_off(settings.foreign_keys)}", [])
  try set_journal_mode(conn, settings.journal_mode)
  return ok()
end

def on_off(flag: Bool) -> String
  if flag
    return "ON"
  end

  return "OFF"
end

# The pragma answers with the mode in force. A memory database stays in `memory` whatever is asked, which is fine;
# any other answer means the mode did not change (a file system without shared memory has no WAL).
def set_journal_mode(conn: Handle, mode: String) -> Result[Void]
  rows = try query(conn, "PRAGMA journal_mode = #{mode.upcase}", [])
  answer = ""
  if not rows.empty?
    case rows[0].get("journal_mode", Value.Null)
      Value.Text(text) -> answer = text
      _ -> answer = ""
    end
  end

  if answer != mode and answer != "memory"
    return error("sqlite error: journal_mode #{mode} could not be set, the database is in #{answer} mode")
  end

  return ok()
end

# Tries to create an FTS5 table in the temp schema, which no file keeps.
def fts5?(conn: Handle) -> Bool
  made = execute(conn, "CREATE VIRTUAL TABLE temp.agentica_fts5_probe USING fts5(x)", [])
  if not made.ok?
    return false
  end

  execute(conn, "DROP TABLE temp.agentica_fts5_probe", [])
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

def changes_since(conn: Handle, before: Int) -> Int
  # sqlite3_changes keeps the count of the last row-changing statement, so a statement that changed nothing
  # (a CREATE TABLE after an INSERT) must not report it.
  if sqlite3_total_changes(conn) == before
    return 0
  end

  return sqlite3_changes(conn)
end

def prepare(conn: Handle, sql: String, params: List[Value]) -> Result[Stmt]
  if has_nul?(sql)
    return error("sqlite error: the sql contains a NUL character")
  end

  # The sql goes through an owned buffer, not a C.String: SQLite points `tail` into its copy, and a C.String copy
  # lives only during the call.
  made: Result[Stmt] = Native.from_string(sql) do |buf|
    try single_statement(conn, buf)
    prepared = sqlite3_prepare_v2(conn, buf, NUL_TERMINATED)
    if prepared.result != SQLITE_OK
      return error(failure(conn, prepared.result))
    end

    ok(prepared.stmt)
  end

  stmt = try made
  bound = bind_all(conn, stmt, params)
  case bound
    ok(_) -> return ok(stmt)
    error(message) ->
      Native.close(stmt)
      return error(message)
  end
end

# SQLite gives a NULL statement for sql that holds only whitespace and comments, which an out resource cannot
# show (it is a closed resource, and any call on it stops the program). So the sql is prepared first with an out
# pointer, where NULL can be tested, and the tail is tried the same way to refuse a second statement.
# A probe is finalized by hand right after its call. The call is a compute def: if the task is cancelled during
# the parse, the C call still finishes but its result is dropped, so that one probe statement is never finalized
# (an out C.Pointer is not freed on cancel, unlike an out resource). It is freed when the connection closes.
def single_statement(conn: Handle, buf: C.Pointer) -> Result[Void]
  probe = sqlite3_probe(conn, buf, NUL_TERMINATED)
  if probe.result != SQLITE_OK
    return error(failure(conn, probe.result))
  end

  if Native.null?(probe.stmt)
    return error("sqlite error: the sql has no statement")
  end

  sqlite3_finalize_pointer(probe.stmt)
  if Native.get_string(probe.tail, 0) == ""
    return ok()
  end

  more = sqlite3_probe(conn, probe.tail, NUL_TERMINATED)
  # Text after the first statement that is only comments gives a NULL statement: still one statement.
  if more.result == SQLITE_OK and Native.null?(more.stmt)
    return ok()
  end

  if more.result == SQLITE_OK
    sqlite3_finalize_pointer(more.stmt)
  end

  return error("sqlite error: the sql has more than one statement")
end

def bind_all(conn: Handle, stmt: Stmt, params: List[Value]) -> Result[Void]
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
  code: Int = Native.from_string(text) do |buf|
    sqlite3_bind_text(stmt, index, buf, text.bytesize, transient())
  end

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
def collect(conn: Handle, stmt: Stmt, names: List[String], keep: Bool) -> Result[List[Row]]
  rows: List[Row] = []
  while true
    code = sqlite3_step(stmt)
    if code == SQLITE_DONE
      return ok(rows)
    end

    if code != SQLITE_ROW
      return error(failure(conn, code))
    end

    if keep
      rows = rows.push(read_row(stmt, names))
    end
  end

  return ok(rows)
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
def failure(conn: Handle, code: Int) -> String
  return "sqlite error #{code}: #{sqlite3_errmsg(conn)}"
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
