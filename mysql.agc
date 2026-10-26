## The MySQL and MariaDB adapter, through the system MariaDB Connector/C (`libmariadb.so.3`), which speaks to MySQL
## and MariaDB servers alike.
##
## `open` gives a `Handle`, which the task that opened it owns. Close it with `close`: the end of the task frees the
## handle (a cell that holds the connection pointer) but does not close the connection, as for PostgreSQL. The
## server session, its socket and the locks of an open transaction stay until `close` or the end of the process. The
## cell is what makes a closed handle give `mysql error: the connection is closed`, where a resource would halt the
## task.
##
## Every statement goes through the prepared statement API (`mysql_stmt_*`): the sql is sent as it is, with its `?`
## placeholders, and the values are bound, never spliced.
##
## An engine failure is `mysql error <code>: <message>`, with the numeric code of the server (`1062` for a duplicate
## key) or of the client library (`2002` for a server that cannot be reached) and its message. A bad input is
## `mysql error: <message>`. A message never holds the url or the password.
##
## The C structs `MYSQL_BIND` and `MYSQL_FIELD` are byte buffers with the offsets of MariaDB Connector/C 3.x: an
## extern block passes a struct by value only, and the library wants an array of binds by pointer, each pointing to
## buffers of its own (there is no pointer arithmetic to point into one buffer).

import MysqlSql from "mysql_sql"
import MysqlUrl from "mysql_url"
import {Row, Value} from "value"

## The statement that starts a transaction.
export BEGIN_SQL = "START TRANSACTION"
POINTER_SIZE = 8
CELL_OFFSET = 0
BYTE_MAX = 255
CHARSET = "utf8mb4"
# The client flag CLIENT_FOUND_ROWS: an UPDATE counts the rows it matched, as in the other adapters, not only the
# rows it changed.
FOUND_ROWS = 2
# The mysql_option values of MYSQL_OPT_CONNECT_TIMEOUT and MYSQL_OPT_LOCAL_INFILE (off: a server cannot ask for a
# file of this machine), as numbered in MariaDB Connector/C 3.x.
OPT_CONNECT_TIMEOUT = 0
OPT_LOCAL_INFILE = 8
# MYSQL_OPT_SSL_VERIFY_SERVER_CERT and MYSQL_OPT_SSL_ENFORCE (use TLS, or fail).
OPT_SSL_VERIFY_SERVER_CERT = 21
OPT_SSL_ENFORCE = 38
# mariadb_value MARIADB_CONNECTION_SERVER_STATUS, and its bit SERVER_STATUS_IN_TRANS.
INFO_SERVER_STATUS = 30
# STMT_ATTR_UPDATE_MAX_LENGTH: the result metadata then holds the longest value of each column.
ATTR_UPDATE_MAX_LENGTH = 0
# The results of mysql_stmt_fetch.
FETCH_ERROR = 1
FETCH_NO_DATA = 100
FETCH_TRUNCATED = 101
# The offsets in MYSQL_BIND (112 bytes): the pointers to the length and to the null flag, the buffer, its length,
# and the type of the buffer.
BIND_SIZE = 112
BIND_LENGTH = 0
BIND_IS_NULL = 8
BIND_BUFFER = 16
BIND_BUFFER_LENGTH = 64
BIND_BUFFER_TYPE = 96
# The offsets in MYSQL_FIELD (128 bytes).
FIELD_NAME = 0
FIELD_LENGTH = 56
FIELD_MAX_LENGTH = 64
FIELD_FLAGS = 100
FIELD_CHARSET = 108
FIELD_TYPE = 112
UNSIGNED_FLAG = 32
BINARY_CHARSET = 63
# enum_field_types: the buffer types that this adapter binds, and the field types that it tells apart.
TYPE_DOUBLE = 5
TYPE_NULL = 6
TYPE_LONGLONG = 8
TYPE_BLOB = 252
TYPE_VAR_STRING = 253
TYPE_STRING = 254
# Integer fields (also NULL, which is never read). A bigint unsigned past the range of an Int is the one exception.
INT_TYPES = Set.new([1, 2, 3, 6, 8, 9, 13])
FLOAT_TYPES = Set.new([4, 5])
# Fields that hold text, or bytes when their character set is binary: varchar, bit, json, the blobs, strings,
# geometry. Every other type (decimal, date, time, datetime, timestamp, enum, set) is read as text.
STRING_TYPES = Set.new([15, 16, 245, 249, 250, 251, 252, 253, 254, 255])
# What is read from a column, which sets the buffer that is bound to it.
KIND_INT = 0
KIND_FLOAT = 1
KIND_TEXT = 2
KIND_BLOB = 3
KIND_UNSIGNED = 4
# A type that is not a string is read as text into a buffer of its display width, at most this many bytes, plus
# some room (a signed decimal, or a datetime with microseconds).
TEXT_WIDTH_LIMIT = 256
TEXT_ROOM = 32
# The statements whose affected rows execute reports; every other one gives 0, a SELECT too.
COUNTING_VERBS = Set.new(["insert", "update", "delete", "replace"])

# A column of a result: its name, what to read, and the size of its buffer.
struct Column
  name: String
  kind: Int
  size: Int
end

# The buffers of one bound column, owned by the reader: the value, its length and its null flag.
struct Slots
  data: C.Pointer
  length: C.Pointer
  null: C.Pointer
end

## An open connection: an owned cell that holds the MYSQL pointer, which `close` sets to NULL.
export type Handle = C.Pointer

# The names of the library start with `mysql_`, so a statement can be a resource that the end of the task frees.
extern "mariadb"
  resource Stmt, free: mysql_stmt_close
  def mysql_init(mysql: C.Pointer) -> C.Pointer
  compute def mysql_real_connect(mysql: C.Pointer, host: C.String, user: C.String, password: C.String,
                                 database: C.String, port: C.Int32, socket: C.Pointer,
                                 flags: C.Int64) -> C.Pointer
  def mysql_options(mysql: C.Pointer, option: C.Int32, value: C.Pointer) -> C.Int32
  compute def mysql_set_character_set(mysql: C.Pointer, name: C.String) -> C.Int32
  compute def mysql_close(mysql: C.Pointer) -> Void
  def mysql_errno(mysql: C.Pointer) -> C.Int32
  def mysql_error(mysql: C.Pointer) -> C.String
  def mariadb_get_info(mysql: C.Pointer, value: C.Int32, arg: C.Pointer) -> C.Bool
  def mysql_stmt_init(mysql: C.Pointer) -> Stmt
  compute def mysql_stmt_prepare(stmt: Stmt, sql: C.String, bytes: C.Int64) -> C.Int32
  def mysql_stmt_param_count(stmt: Stmt) -> C.Int64
  def mysql_stmt_bind_param(stmt: Stmt, binds: C.Pointer) -> C.Bool
  compute def mysql_stmt_execute(stmt: Stmt) -> C.Int32
  def mysql_stmt_attr_set(stmt: Stmt, attr: C.Int32, value: C.Pointer) -> C.Bool
  compute def mysql_stmt_store_result(stmt: Stmt) -> C.Int32
  def mysql_stmt_field_count(stmt: Stmt) -> C.Int32
  def mysql_stmt_affected_rows(stmt: Stmt) -> C.Int64
  def mysql_stmt_result_metadata(stmt: Stmt) -> C.Pointer
  def mysql_stmt_bind_result(stmt: Stmt, binds: C.Pointer) -> C.Bool
  def mysql_stmt_fetch(stmt: Stmt) -> C.Int32
  def mysql_stmt_errno(stmt: Stmt) -> C.Int32
  def mysql_stmt_error(stmt: Stmt) -> C.String
  def mysql_free_result(result: C.Pointer) -> Void
  def mysql_num_fields(result: C.Pointer) -> C.Int32
  def mysql_fetch_field_direct(result: C.Pointer, index: C.Int32) -> C.Pointer
end

## Connects with a `mysql://` or `mariadb://` url (see `MysqlUrl`). The client character set is utf8mb4.
export def open(url: String) -> Result[Handle]
  target = try MysqlUrl.parse(url)
  mysql = mysql_init(Native.null())
  if Native.null?(mysql)
    return error("mysql error: out of memory")
  end

  configure(mysql, target)
  connected = mysql_real_connect(mysql, target.host, target.user, target.password, target.database, target.port,
                                 Native.null(), FOUND_ROWS)
  if Native.null?(connected)
    return abandon(mysql)
  end

  if mysql_set_character_set(mysql, CHARSET) != 0
    return abandon(mysql)
  end

  handle = Native.memory_pointer(POINTER_SIZE)
  Native.put_pointer(handle, CELL_OFFSET, mysql)
  return ok(handle)
end

## Closes the connection; closing it again does nothing.
export def close(handle: Handle) -> Void
  mysql = Native.get_pointer(handle, CELL_OFFSET)
  if not Native.null?(mysql)
    mysql_close(mysql)
    Native.put_pointer(handle, CELL_OFFSET, Native.null())
  end
end

## Runs one statement with bound parameters and gives its rows, which are empty for a statement without a result.
## Two columns with one name are an error: alias them.
export def query(handle: Handle, sql: String, params: List[Value]) -> Result[List[Row]]
  conn = try live(handle)
  statement = try MysqlSql.inspect(sql)
  stmt = try prepared(conn, statement, sql, params)
  rows = read_rows(stmt)
  Native.close(stmt)
  return rows
end

## Runs one statement with bound parameters and gives the number of rows it inserted, updated (matched) or deleted.
export def execute(handle: Handle, sql: String, params: List[Value]) -> Result[Int]
  conn = try live(handle)
  statement = try MysqlSql.inspect(sql)
  stmt = try prepared(conn, statement, sql, params)
  drained = drain(stmt)
  changed = 0
  if COUNTING_VERBS.include?(statement.verb)
    changed = mysql_stmt_affected_rows(stmt)
  end

  Native.close(stmt)
  try drained
  return ok(changed)
end

# Options set before the connection: the connect timeout (0 keeps the library's), the TLS mode (the library's own
# when the url sets none), and no LOCAL INFILE.
def configure(mysql: C.Pointer, target: MysqlUrl.Target) -> Void
  Native.memory_pointer(POINTER_SIZE) do |value|
    if target.timeout > 0
      Native.put_int32(value, 0, target.timeout)
      mysql_options(mysql, OPT_CONNECT_TIMEOUT, value)
    end


    Native.put_int32(value, 0, 0)
    mysql_options(mysql, OPT_LOCAL_INFILE, value)
  end

  case target.tls
    MysqlUrl.Tls.Default -> return
    MysqlUrl.Tls.Required -> require_tls(mysql, false)
    MysqlUrl.Tls.Verify -> require_tls(mysql, true)
  end
end

# Both TLS options take a my_bool, one byte.
def require_tls(mysql: C.Pointer, verify: Bool) -> Void
  Native.memory_pointer(1) do |flag|
    Native.put_int8(flag, 0, 1)
    mysql_options(mysql, OPT_SSL_ENFORCE, flag)
    if verify
      mysql_options(mysql, OPT_SSL_VERIFY_SERVER_CERT, flag)
    end
  end
end

# Frees the connection when it does not work: a failed connect still holds the error.
def abandon(mysql: C.Pointer) -> Result[Handle]
  message = failure(mysql_errno(mysql), mysql_error(mysql))
  mysql_close(mysql)
  return error(message)
end

# The code is the one of the server or the library; a failure without one has no code.
def failure(code: Int, message: String) -> String
  if code == 0
    return "mysql error: #{message.strip}"
  end

  return "mysql error #{code}: #{message.strip}"
end

def stmt_failure(stmt: Stmt) -> String
  return failure(mysql_stmt_errno(stmt), mysql_stmt_error(stmt))
end

def live(handle: Handle) -> Result[C.Pointer]
  mysql = Native.get_pointer(handle, CELL_OFFSET)
  if Native.null?(mysql)
    return error("mysql error: the connection is closed")
  end

  return ok(mysql)
end

def noun(count: Int) -> String
  if count == 1
    return "parameter"
  end

  return "parameters"
end

# MySQL has no error for a BEGIN inside a transaction: it commits the open one without a word. Transactions do not
# nest here, as in the other adapters, so a BEGIN or START TRANSACTION is refused while the server says that one is
# open.
def check_begin(mysql: C.Pointer, verb: String) -> Result[Void]
  if (verb == "begin" or verb == "start") and in_transaction?(mysql)
    return error("mysql error: a transaction is already in progress")
  end

  return ok()
end

def in_transaction?(mysql: C.Pointer) -> Bool
  open: Bool = Native.memory_pointer(POINTER_SIZE) do |status|
    failed = mariadb_get_info(mysql, INFO_SERVER_STATUS, status)
    (not failed) and Native.get_uint32(status, 0) % 2 == 1
  end

  return open
end

def check_params(params: List[Value]) -> Result[Void]
  for param in params
    case param
      Value.Text(text) ->
        if text.include?(String.from_code(0))
          return error("mysql error: a text parameter contains a NUL character")
        end

      Value.Blob(bytes) ->
        if bytes.any? do |byte| byte < 0 or byte > BYTE_MAX end
          return error("mysql error: a blob parameter has an item outside 0..255")
        end

      Value.Float(x) ->
        # x - x is 0.0 for every finite x, and NaN for a NaN and for an infinity.
        if x - x != 0.0
          return error("mysql error: a float parameter is NaN or infinite, which MySQL cannot store")
        end

      Value.Null -> next
      Value.Int(_) -> next
      Value.Bool(_) -> next
    end
  end

  return ok()
end

# A statement that is prepared, bound and executed. The caller closes it.
def prepared(mysql: C.Pointer, statement: MysqlSql.Statement, sql: String, params: List[Value]) -> Result[Stmt]
  try check_params(params)
  try check_begin(mysql, statement.verb)
  made = mysql_stmt_init(mysql)
  if not made.ok?
    return error("mysql error: out of memory")
  end

  stmt = try made
  # The length is given, so the sql needs no NUL at its end.
  if mysql_stmt_prepare(stmt, sql, sql.to_bytes.size) != 0
    return refuse(stmt, stmt_failure(stmt))
  end

  wanted = mysql_stmt_param_count(stmt)
  if wanted != params.size
    return refuse(stmt, "mysql error: the sql has #{wanted} #{noun(wanted)}, got #{params.size}")
  end

  if not send(stmt, params)
    return refuse(stmt, stmt_failure(stmt))
  end

  return ok(stmt)
end

# Closes the statement and gives the error.
def refuse(stmt: Stmt, message: String) -> Result[Stmt]
  Native.close(stmt)
  return error(message)
end

# True when the statement ran. The bind array and the buffers it points to must stay until the execute returns, so
# they are freed right after it, and nothing between the allocation and the free can return.
def send(stmt: Stmt, params: List[Value]) -> Bool
  sent: Bool = Native.memory_pointer(max_one(params.size) * BIND_SIZE) do |binds|
    owned = fill_binds(binds, params)
    bound = params.empty? or (not mysql_stmt_bind_param(stmt, binds))
    ran = bound and mysql_stmt_execute(stmt) == 0
    for buffer in owned
      Native.free(buffer)
    end

    ran
  end

  return sent
end

def max_one(count: Int) -> Int
  if count < 1
    return 1
  end

  return count
end

def fill_binds(binds: C.Pointer, params: List[Value]) -> List[C.Pointer]
  owned: List[C.Pointer] = []
  index = 0
  for param in params
    base = index * BIND_SIZE
    case param
      Value.Null -> Native.put_int32(binds, base + BIND_BUFFER_TYPE, TYPE_NULL)
      Value.Int(n) -> owned = owned.push(bind_int(binds, base, n))
      Value.Bool(flag) -> owned = owned.push(bind_int(binds, base, bool_int(flag)))
      Value.Float(x) -> owned = owned.push(bind_float(binds, base, x))
      Value.Text(text) -> owned = owned.push(bind_text(binds, base, text))
      Value.Blob(bytes) -> owned = owned.push(bind_blob(binds, base, bytes))
    end

    index += 1
  end

  return owned
end

def bool_int(flag: Bool) -> Int
  if flag
    return 1
  end

  return 0
end

# Points the bind at `base` to a new buffer of `size` bytes (at least one) with the given type, and gives it.
def bind_buffer(binds: C.Pointer, base: Int, type: Int, size: Int) -> C.Pointer
  buffer = Native.memory_pointer(max_one(size))
  Native.put_pointer(binds, base + BIND_BUFFER, buffer)
  Native.put_int32(binds, base + BIND_BUFFER_TYPE, type)
  Native.put_int64(binds, base + BIND_BUFFER_LENGTH, size)
  return buffer
end

def bind_int(binds: C.Pointer, base: Int, n: Int) -> C.Pointer
  buffer = bind_buffer(binds, base, TYPE_LONGLONG, 8)
  Native.put_int64(buffer, 0, n)
  return buffer
end

def bind_float(binds: C.Pointer, base: Int, x: Float) -> C.Pointer
  buffer = bind_buffer(binds, base, TYPE_DOUBLE, 8)
  Native.put_float64(buffer, 0, x)
  return buffer
end

def bind_text(binds: C.Pointer, base: Int, text: String) -> C.Pointer
  # The buffer holds one byte more than the text, for the NUL that put_string writes.
  buffer = bind_buffer(binds, base, TYPE_VAR_STRING, text.to_bytes.size + 1)
  Native.put_string(buffer, 0, text)
  Native.put_int64(binds, base + BIND_BUFFER_LENGTH, text.to_bytes.size)
  return buffer
end

def bind_blob(binds: C.Pointer, base: Int, bytes: List[Int]) -> C.Pointer
  buffer = bind_buffer(binds, base, TYPE_BLOB, bytes.size)
  if not bytes.empty?
    Native.put_bytes(buffer, 0, bytes)
  end

  return buffer
end

# A statement run for its effect: a result set it makes is stored and dropped, because the connection takes no new
# command while one is waiting.
def drain(stmt: Stmt) -> Result[Void]
  if mysql_stmt_field_count(stmt) > 0 and mysql_stmt_store_result(stmt) != 0
    return error(stmt_failure(stmt))
  end

  return ok()
end

def store(stmt: Stmt) -> Result[Void]
  set: Bool = Native.memory_pointer(1) do |flag|
    Native.put_int8(flag, 0, 1)
    not mysql_stmt_attr_set(stmt, ATTR_UPDATE_MAX_LENGTH, flag)
  end

  if not set or mysql_stmt_store_result(stmt) != 0
    return error(stmt_failure(stmt))
  end

  return ok()
end

def read_rows(stmt: Stmt) -> Result[List[Row]]
  if mysql_stmt_field_count(stmt) == 0
    return ok([])
  end

  try store(stmt)
  meta = mysql_stmt_result_metadata(stmt)
  if Native.null?(meta)
    return error(stmt_failure(stmt))
  end

  columns = describe(meta)
  mysql_free_result(meta)
  names = columns.map do |column| column.name end
  if names.uniq.size != names.size
    return error("mysql error: the result has the column #{repeated_name(names)} twice, alias one of them")
  end

  return fetch_all(stmt, columns)
end

def repeated_name(names: List[String]) -> String
  counts = names.tally
  return names.find do |name| counts[name] > 1 end.unwrap_or("")
end

def describe(meta: C.Pointer) -> List[Column]
  columns: List[Column] = []
  for index in 0...mysql_num_fields(meta)
    field = mysql_fetch_field_direct(meta, index)
    name = Native.get_string(Native.get_pointer(field, FIELD_NAME), 0)
    type = Native.get_int32(field, FIELD_TYPE)
    flags = Native.get_uint32(field, FIELD_FLAGS)
    charset = Native.get_uint32(field, FIELD_CHARSET)
    longest = Native.get_int64(field, FIELD_MAX_LENGTH)
    width = Native.get_int64(field, FIELD_LENGTH)
    columns = columns.push(column_of(name, type, flags, charset, longest, width))
  end

  return columns
end

# What to read from a column, and how big a buffer holds its longest value.
def column_of(name: String, type: Int, flags: Int, charset: Int, longest: Int, width: Int) -> Column
  unsigned = flags % (UNSIGNED_FLAG * 2) >= UNSIGNED_FLAG
  if type == TYPE_LONGLONG and unsigned
    return Column(name: name, kind: KIND_UNSIGNED, size: TEXT_ROOM)
  elsif INT_TYPES.include?(type)
    return Column(name: name, kind: KIND_INT, size: 8)
  elsif FLOAT_TYPES.include?(type)
    return Column(name: name, kind: KIND_FLOAT, size: 8)
  elsif STRING_TYPES.include?(type) and charset == BINARY_CHARSET
    return Column(name: name, kind: KIND_BLOB, size: longest)
  elsif STRING_TYPES.include?(type)
    return Column(name: name, kind: KIND_TEXT, size: longest)
  end

  return Column(name: name, kind: KIND_TEXT, size: max_of(longest, min_of(width, TEXT_WIDTH_LIMIT)) + TEXT_ROOM)
end

def max_of(a: Int, b: Int) -> Int
  if a > b
    return a
  end

  return b
end

def min_of(a: Int, b: Int) -> Int
  if a < b
    return a
  end

  return b
end

# Binds a buffer to every column and reads the stored rows. The bind array lives for the whole read; the buffers of
# the columns are freed after it, and nothing between their allocation and the free can return.
def fetch_all(stmt: Stmt, columns: List[Column]) -> Result[List[Row]]
  read: Result[List[Row]] = Native.memory_pointer(columns.size * BIND_SIZE) do |binds|
    slots = bind_columns(binds, columns)
    rows = read_bound(stmt, binds, columns, slots)
    for slot in slots
      Native.free(slot.data)
      Native.free(slot.length)
      Native.free(slot.null)
    end

    rows
  end

  return read
end

def bind_columns(binds: C.Pointer, columns: List[Column]) -> List[Slots]
  slots: List[Slots] = []
  index = 0
  for column in columns
    base = index * BIND_SIZE
    slot = Slots(data: Native.memory_pointer(max_one(column.size)), length: Native.memory_pointer(8),
                 null: Native.memory_pointer(8))
    Native.put_pointer(binds, base + BIND_BUFFER, slot.data)
    Native.put_pointer(binds, base + BIND_LENGTH, slot.length)
    Native.put_pointer(binds, base + BIND_IS_NULL, slot.null)
    Native.put_int64(binds, base + BIND_BUFFER_LENGTH, column.size)
    Native.put_int32(binds, base + BIND_BUFFER_TYPE, buffer_type(column.kind))
    slots = slots.push(slot)
    index += 1
  end

  return slots
end

def buffer_type(kind: Int) -> Int
  if kind == KIND_INT
    return TYPE_LONGLONG
  elsif kind == KIND_FLOAT
    return TYPE_DOUBLE
  elsif kind == KIND_BLOB
    return TYPE_BLOB
  end

  return TYPE_STRING
end

def read_bound(stmt: Stmt, binds: C.Pointer, columns: List[Column], slots: List[Slots]) -> Result[List[Row]]
  if mysql_stmt_bind_result(stmt, binds)
    return error(stmt_failure(stmt))
  end

  rows: List[Row] = []
  while true
    code = mysql_stmt_fetch(stmt)
    if code == FETCH_NO_DATA
      return ok(rows)
    elsif code == FETCH_ERROR
      return error(stmt_failure(stmt))
    elsif code == FETCH_TRUNCATED
      return error("mysql error: a value is longer than its buffer")
    end

    rows = rows.push(try read_row(columns, slots))
  end

  return ok(rows)
end

def read_row(columns: List[Column], slots: List[Slots]) -> Result[Row]
  row: Row = {}
  for index in 0...columns.size
    value = try read_value(columns[index], slots[index])
    row = row.put(columns[index].name, value)
  end

  return ok(row)
end

def read_value(column: Column, slot: Slots) -> Result[Value]
  if Native.get_uint8(slot.null, 0) != 0
    return ok(Value.Null)
  end

  length = Native.get_int64(slot.length, 0)
  if length > column.size
    return error("mysql error: a value is longer than its buffer")
  end

  if column.kind == KIND_INT
    return ok(Value.Int(Native.get_int64(slot.data, 0)))
  elsif column.kind == KIND_FLOAT
    # The 8 bytes of a double are read as they are: the sign of a zero and the exact digits survive.
    return ok(Value.Float(Native.get_float64(slot.data, 0)))
  elsif column.kind == KIND_BLOB
    return ok(Value.Blob(Native.get_bytes(slot.data, 0, length)))
  elsif column.kind == KIND_UNSIGNED
    return ok(unsigned_value(Native.get_string(slot.data, 0, length)))
  end

  return ok(Value.Text(Native.get_string(slot.data, 0, length)))
end

# A bigint unsigned is an Int when it fits, else its digits as text.
def unsigned_value(digits: String) -> Value
  parsed = digits.to_i
  case parsed
    ok(n) -> return Value.Int(n)
    error(_) -> return Value.Text(digits)
  end
end
