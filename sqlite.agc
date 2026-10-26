## The SQLite adapter, through the system libsqlite3.
##
## `open` gives a `Handle`, which the task that opened it owns: close it with `close`, or the end of the task
## closes it. Using a closed handle is a runtime error (`RUNTIME-NATIVE-CLOSED`).

import {Row, Value} from "value"

SQLITE_OK = 0
SQLITE_ROW = 100
SQLITE_DONE = 101
SQLITE_INTEGER = 1
SQLITE_FLOAT = 2
SQLITE_TEXT = 3
SQLITE_BLOB = 4
BUSY_TIMEOUT_MS = 5_000
BYTE_MAX = 255

extern "sqlite3"
  export resource Handle, free: sqlite3_close_v2
  resource Stmt, free: sqlite3_finalize
  compute def sqlite3_open(filename: C.String, out db: Handle) -> C.Int32
  def sqlite3_busy_timeout(db: Handle, ms: C.Int32) -> C.Int32
  def sqlite3_errmsg(db: Handle) -> C.String
  def sqlite3_changes(db: Handle) -> C.Int32
  def sqlite3_total_changes(db: Handle) -> C.Int32
  def sqlite3_prepare_v2(db: Handle, sql: C.Pointer, bytes: C.Int32, out stmt: Stmt, out tail: C.Pointer) -> C.Int32
  compute def sqlite3_step(stmt: Stmt) -> C.Int32
  def sqlite3_bind_parameter_count(stmt: Stmt) -> C.Int32
  def sqlite3_bind_null(stmt: Stmt, index: C.Int32) -> C.Int32
  def sqlite3_bind_int64(stmt: Stmt, index: C.Int32, value: C.Int64) -> C.Int32
  def sqlite3_bind_double(stmt: Stmt, index: C.Int32, value: C.Double) -> C.Int32
  def sqlite3_bind_text(stmt: Stmt, index: C.Int32, text: C.String, bytes: C.Int32, destructor: C.Pointer) -> C.Int32
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

## Opens a database file, or `:memory:`; the file is created when it does not exist.
export def open(path: String) -> Result[Handle]
  if has_nul?(path)
    return error("sqlite error: the path contains a NUL character")
  end
  opened = sqlite3_open(path)
  if opened.result != SQLITE_OK
    message = failure(opened.db, opened.result)
    # A failed open may still give a live handle, which only this function sees.
    Native.close(opened.db)
    return error(message)
  end
  sqlite3_busy_timeout(opened.db, BUSY_TIMEOUT_MS)
  return ok(opened.db)
end

## Closes the handle; closing it again does nothing.
export def close(conn: Handle) -> Void
  Native.close(conn)
end

## Runs one statement with bound parameters and gives its rows, which are empty for a statement without a result.
export def query(conn: Handle, sql: String, params: List[Value]) -> Result[List[Row]]
  stmt = try prepare(conn, sql, params)
  rows = collect(conn, stmt)
  Native.close(stmt)
  return rows
end

## Runs one statement with bound parameters and gives the number of rows it inserted, updated or deleted.
export def execute(conn: Handle, sql: String, params: List[Value]) -> Result[Int]
  stmt = try prepare(conn, sql, params)
  before = sqlite3_total_changes(conn)
  done = run(conn, stmt)
  # sqlite3_changes keeps the count of the last row-changing statement, so a statement that changed nothing
  # (a CREATE TABLE after an INSERT) must not report it.
  changed = 0
  if sqlite3_total_changes(conn) != before
    changed = sqlite3_changes(conn)
  end
  Native.close(stmt)
  case done
    Result.Ok(_) -> return ok(changed)
    Result.Err(message) -> return error(message)
  end
end

def prepare(conn: Handle, sql: String, params: List[Value]) -> Result[Stmt]
  if has_nul?(sql)
    return error("sqlite error: the sql contains a NUL character")
  end
  if blank_sql?(sql)
    return error("sqlite error: the sql has no statement")
  end
  try check_params(params)
  # The sql goes through an owned buffer, not a C.String: SQLite points `tail` into its copy, and a C.String copy
  # lives only during the call.
  made: Result[Stmt] = Native.memory_pointer(sql.to_bytes.size + 1) do |buf|
    Native.put_string(buf, 0, sql)
    prepared = sqlite3_prepare_v2(conn, buf, -1)
    if prepared.result != SQLITE_OK
      return error(failure(conn, prepared.result))
    end
    if not blank_sql?(Native.get_string(prepared.tail, 0))
      Native.close(prepared.stmt)
      return error("sqlite error: the sql has more than one statement")
    end
    ok(prepared.stmt)
  end
  stmt = try made
  bound = bind_all(conn, stmt, params)
  case bound
    Result.Ok(_) -> return ok(stmt)
    Result.Err(message) ->
      Native.close(stmt)
      return error(message)
  end
end

def check_params(params: List[Value]) -> Result[Void]
  for param in params
    case param
      Value.Text(text) ->
        if has_nul?(text)
          return error("sqlite error: a text parameter contains a NUL character")
        end
      Value.Blob(bytes) ->
        if bytes.any? do |byte| byte < 0 or byte > BYTE_MAX end
          return error("sqlite error: a blob parameter has an item outside 0..255")
        end
      Value.Null -> next
      Value.Int(_) -> next
      Value.Float(_) -> next
      Value.Bool(_) -> next
    end
  end
  return ok()
end

def bind_all(conn: Handle, stmt: Stmt, params: List[Value]) -> Result[Void]
  wanted = sqlite3_bind_parameter_count(stmt)
  if wanted != params.size
    return error("sqlite error: the sql has #{wanted} parameters, got #{params.size}")
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

def bind_value(stmt: Stmt, index: Int, value: Value) -> Int
  transient = Native.pointer(-1)
  case value
    Value.Null -> return sqlite3_bind_null(stmt, index)
    Value.Int(n) -> return sqlite3_bind_int64(stmt, index, n)
    Value.Float(x) -> return sqlite3_bind_double(stmt, index, x)
    Value.Text(text) -> return sqlite3_bind_text(stmt, index, text, -1, transient)
    Value.Blob(bytes) -> return bind_blob(stmt, index, bytes)
    Value.Bool(flag) -> return sqlite3_bind_int64(stmt, index, bool_int(flag))
  end
end

def bind_blob(stmt: Stmt, index: Int, bytes: List[Int]) -> Int
  # Binding a NULL pointer would store NULL, so an empty blob has its own call.
  if bytes.empty?
    return sqlite3_bind_zeroblob(stmt, index, 0)
  end
  return sqlite3_bind_blob(stmt, index, bytes, bytes.size, Native.pointer(-1))
end

def bool_int(flag: Bool) -> Int
  if flag
    return 1
  end
  return 0
end

def collect(conn: Handle, stmt: Stmt) -> Result[List[Row]]
  names = column_names(stmt)
  rows: List[Row] = []
  while true
    code = sqlite3_step(stmt)
    if code == SQLITE_DONE
      return ok(rows)
    end
    if code != SQLITE_ROW
      return error(failure(conn, code))
    end
    rows = rows.push(read_row(stmt, names))
  end
  return ok(rows)
end

def run(conn: Handle, stmt: Stmt) -> Result[Void]
  while true
    code = sqlite3_step(stmt)
    if code == SQLITE_DONE
      return ok()
    end
    # A statement that returns rows is run for its effect: the rows are dropped.
    if code != SQLITE_ROW
      return error(failure(conn, code))
    end
  end
  return ok()
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

# SQLite gives no statement (a NULL out resource, which a program cannot test) for text that holds only
# whitespace, semicolons and comments, so those are refused before the call.
def blank_sql?(sql: String) -> Bool
  size = sql.length
  i = 0
  while i < size
    c = sql.at(i)
    if c == " " or c == "\t" or c == "\n" or c == "\r" or c == ";" or c == String.from_code(12)
      i += 1
    elsif c == "-" and i + 1 < size and sql.at(i + 1) == "-"
      i = line_comment_end(sql, i + 2)
    elsif c == "/" and i + 1 < size and sql.at(i + 1) == "*"
      i = block_comment_end(sql, i + 2)
    else
      return false
    end
  end
  return true
end

def line_comment_end(sql: String, from: Int) -> Int
  i = from
  while i < sql.length and sql.at(i) != "\n"
    i += 1
  end
  return i
end

def block_comment_end(sql: String, from: Int) -> Int
  i = from
  while i < sql.length
    if sql.at(i) == "*" and i + 1 < sql.length and sql.at(i + 1) == "/"
      return i + 2
    end
    i += 1
  end
  return i
end
