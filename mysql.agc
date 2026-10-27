## The MySQL and MariaDB adapter, through the system MariaDB Connector/C (`libmariadb.so.3`), which speaks to MySQL
## and MariaDB servers alike.
##
## `open` gives a `Handle`, which the task that opened it owns. Close it with `close`, or the end of the task closes
## it (`mysql_close`, the free function of the connection resource), as in the other adapters. A closed handle gives
## `mysql error: the connection is closed`.
##
## Every statement goes through the prepared statement API (`mysql_stmt_*`): the sql is sent as it is, with its `?`
## placeholders, and the values are bound, never spliced.
##
## An engine failure is `mysql error <code>: <message>`, with the numeric code of the server (`1062` for a duplicate
## key) or of the client library (`2002` for a server that cannot be reached) and its message. A bad input is
## `mysql error: <message>`. A message never holds the url or the password.
##
## `MysqlBind` and `MysqlField` declare the C structs `MYSQL_BIND` and `MYSQL_FIELD` of MariaDB Connector/C 3.x, field
## by field: a struct of an extern block has the whole layout of the header (there are no partial structs), so the
## fields that this adapter never reads are there to give the right size and offsets (112 and 128 bytes on Linux
## x86-64). `Native.size_of`, `Native.get_struct` and `Native.put_struct` read and write them in the arrays that the
## library takes by pointer. `unsigned long` is a `C.Long`, which is 32 bits on Windows.

import MysqlSql from "mysql_sql"
import MysqlUrl from "mysql_url"
import {Row, Value} from "value"

## The statement that starts a transaction.
export BEGIN_SQL = "START TRANSACTION"
POINTER_SIZE = 8
BYTE_MAX = 255
CHARSET = "utf8mb4"
# The client flag CLIENT_FOUND_ROWS: an UPDATE counts the rows it matched, as in the other adapters, not only the
# rows it changed.
FOUND_ROWS = 2
# The mysql_option values of MYSQL_OPT_CONNECT_TIMEOUT and MYSQL_OPT_LOCAL_INFILE (off: a server cannot ask for a
# file of this machine), as numbered in MariaDB Connector/C 3.x.
OPT_CONNECT_TIMEOUT = 0
OPT_LOCAL_INFILE = 8
# MYSQL_OPT_SSL_VERIFY_SERVER_CERT, MYSQL_OPT_SSL_CA (the file of authorities) and MYSQL_OPT_SSL_ENFORCE (use TLS, or
# fail).
OPT_SSL_VERIFY_SERVER_CERT = 21
OPT_SSL_CA = 27
OPT_SSL_ENFORCE = 38
# mariadb_value MARIADB_CONNECTION_SERVER_STATUS, and its bit SERVER_STATUS_IN_TRANS.
INFO_SERVER_STATUS = 30
# STMT_ATTR_UPDATE_MAX_LENGTH: the result metadata then holds the longest value of each column.
ATTR_UPDATE_MAX_LENGTH = 0
# The error of a statement that the server does not prepare.
UNSUPPORTED_PREPARE = 1295
# The results of mysql_stmt_fetch.
FETCH_ERROR = 1
FETCH_NO_DATA = 100
FETCH_TRUNCATED = 101
UNSIGNED_FLAG = 32
BINARY_CHARSET = 63
# enum_field_types: the buffer types that this adapter binds, and the field types that it tells apart.
TYPE_DOUBLE = 5
TYPE_NULL = 6
TYPE_LONGLONG = 8
TYPE_BLOB = 252
TYPE_JSON = 245
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

# The names of the library start with `mysql_`, so a connection and a statement can be resources that the end of the
# task frees. `mysql_close` blocks while it says goodbye to the server, and a free runs on the scheduler.
extern "mariadb"
  ## An open connection (a `MYSQL *`).
  export resource Handle, free: mysql_close
  resource Stmt, free: mysql_stmt_close

  # MYSQL_BIND, in the order of mysql.h. The pointers and the callbacks after `buffer` are the library's own.
  struct MysqlBind
    length: C.Pointer
    is_null: C.Pointer
    buffer: C.Pointer
    error_flag: C.Pointer
    row_ptr: C.Pointer
    store_param_func: C.Pointer
    fetch_result: C.Pointer
    skip_result: C.Pointer
    buffer_length: C.Long
    offset: C.Long
    length_value: C.Long
    flags: C.UInt32
    pack_length: C.UInt32
    buffer_type: C.Int32
    error_value: C.UInt8
    is_unsigned: C.UInt8
    long_data_used: C.UInt8
    is_null_value: C.UInt8
    extension: C.Pointer
  end

  # One `unsigned long`, the type of a length: 4 bytes on Windows and 8 elsewhere. `Native.size_of` is the stride of
  # the arrays of lengths (`MYSQL_BIND.length` slots and `mysql_fetch_lengths`), so no code assumes 8 bytes.
  struct UnsignedLong
    value: C.Long
  end

  # MYSQL_FIELD, in the order of mariadb_com.h (`def` is a keyword, hence `def_value`).
  struct MysqlField
    name: C.Pointer
    org_name: C.Pointer
    table: C.Pointer
    org_table: C.Pointer
    db: C.Pointer
    catalog: C.Pointer
    def_value: C.Pointer
    length: C.Long
    max_length: C.Long
    name_length: C.UInt32
    org_name_length: C.UInt32
    table_length: C.UInt32
    org_table_length: C.UInt32
    db_length: C.UInt32
    catalog_length: C.UInt32
    def_length: C.UInt32
    flags: C.UInt32
    decimals: C.UInt32
    charsetnr: C.UInt32
    type: C.Int32
    extension: C.Pointer
  end

  def mysql_init(mysql: C.Pointer) -> Handle
  compute def mysql_real_connect(mysql: Handle, host: C.String, user: C.String, password: C.String,
                                 database: C.String, port: C.Int32, socket: C.Pointer,
                                 flags: C.Long) -> C.Pointer
  def mysql_options(mysql: Handle, option: C.Int32, value: C.Pointer) -> C.Int32
  def mysql_options_text(mysql: Handle, option: C.Int32, value: C.String) -> C.Int32 = "mysql_options"
  compute def mysql_set_character_set(mysql: Handle, name: C.String) -> C.Int32
  def mysql_errno(mysql: Handle) -> C.Int32
  def mysql_error(mysql: Handle) -> C.String
  def mariadb_get_info(mysql: Handle, value: C.Int32, arg: C.Pointer) -> C.Bool
  def mysql_stmt_init(mysql: Handle) -> Stmt
  compute def mysql_stmt_prepare(stmt: Stmt, sql: C.String, bytes: C.Long) -> C.Int32
  def mysql_stmt_param_count(stmt: Stmt) -> C.Long
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
  # The text protocol, for the statements that the server does not prepare.
  compute def mysql_real_query(mysql: Handle, sql: C.String, bytes: C.Long) -> C.Int32
  compute def mysql_store_result(mysql: Handle) -> C.Pointer
  def mysql_field_count(mysql: Handle) -> C.Int32
  def mysql_affected_rows(mysql: Handle) -> C.Int64
  def mysql_fetch_row(result: C.Pointer) -> C.Pointer
  def mysql_fetch_lengths(result: C.Pointer) -> C.Pointer
  def mysql_more_results(mysql: Handle) -> C.Bool
  compute def mysql_next_result(mysql: Handle) -> C.Int32
  def mysql_free_result(result: C.Pointer) -> Void
  def mysql_num_fields(result: C.Pointer) -> C.Int32
  def mysql_fetch_field_direct(result: C.Pointer, index: C.Int32) -> C.Pointer
end

## Connects with a `mysql://` or `mariadb://` url (see `MysqlUrl`). The client character set is utf8mb4.
export def open(url: String) -> Result[Handle]
  target = try MysqlUrl.parse(url)
  try load_library()
  mysql = try init()
  configured = configure(mysql, target)
  if not configured.ok?
    Native.close(mysql)
    return error(configured.message)
  end

  connected = mysql_real_connect(mysql, target.host, target.user, target.password, target.database, target.port,
                                 Native.null(), FOUND_ROWS)
  if Native.null?(connected)
    return abandon(mysql)
  end

  if mysql_set_character_set(mysql, CHARSET) != 0
    return abandon(mysql)
  end

  return ok(mysql)
end

## Closes the connection; closing it again does nothing.
export def close(handle: Handle) -> Void
  Native.close(handle)
end

## Runs one statement with bound parameters and gives its rows, which are empty for a statement without a result.
## Two columns with one name are an error: alias them. A statement without parameters that the server does not
## prepare (`START TRANSACTION`, `BEGIN`, `SAVEPOINT`, `USE` and `LOCK TABLES` on MySQL) goes through the text
## protocol, which is safe because there is nothing to bind.
export def query(handle: Handle, sql: String, params: List[Value]) -> Result[List[Row]]
  try check_open(handle)
  statement = try MysqlSql.inspect(sql)
  try check_params(params)
  try check_begin(handle, statement.verb)
  case start(handle, sql)
    error(message) if text_only?(message, params) -> return text_query(handle, sql)
    error(message) -> return error(message)
    ok(stmt) ->
      rows = launch_query(stmt, params)
      Native.close(stmt)
      return rows
  end
end

## Runs one statement with bound parameters and gives the number of rows it inserted, updated (matched), deleted or
## replaced. The text protocol is used as for `query`.
export def execute(handle: Handle, sql: String, params: List[Value]) -> Result[Int]
  try check_open(handle)
  statement = try MysqlSql.inspect(sql)
  try check_params(params)
  try check_begin(handle, statement.verb)
  case start(handle, sql)
    error(message) if text_only?(message, params) -> return text_execute(handle, sql, statement.verb)
    error(message) -> return error(message)
    ok(stmt) ->
      changed = launch_execute(stmt, params, statement.verb)
      Native.close(stmt)
      return changed
  end
end

# A library that is missing is an error here, not a stop of the program at the first call.
def load_library() -> Result[Void]
  case Native.load("mariadb")
    error(message) -> return error("mysql error: cannot load the client library: #{message}")
    ok(_) -> return ok()
  end
end

def init() -> Result[Handle]
  case mysql_init(Native.null())
    error(_) -> return error("mysql error: out of memory")
    ok(mysql) -> return ok(mysql)
  end
end

# Options set before the connection: the connect timeout (0 keeps the library's), no LOCAL INFILE, and the TLS mode
# (the library's own when the url sets none). The library says whether it took an option, and a refused one stops
# the connection: a TLS option that did nothing would connect without the check that was asked for.
def configure(mysql: Handle, target: MysqlUrl.Target) -> Result[Void]
  if target.timeout > 0
    try set_number(mysql, OPT_CONNECT_TIMEOUT, target.timeout)
  end

  try set_number(mysql, OPT_LOCAL_INFILE, 0)
  case target.tls
    MysqlUrl.Tls.Default -> return ok()
    MysqlUrl.Tls.Required -> return require_tls(mysql, "")
    MysqlUrl.Tls.Verify -> return require_tls(mysql, target.ca)
  end
end

# `ca` is empty to accept any certificate, else the PEM file of authorities that the certificate is checked against.
def require_tls(mysql: Handle, ca: String) -> Result[Void]
  try set_flag(mysql, OPT_SSL_ENFORCE)
  if not ca.empty?
    try set_flag(mysql, OPT_SSL_VERIFY_SERVER_CERT)
    if mysql_options_text(mysql, OPT_SSL_CA, ca) != 0
      return error("mysql error: the client library refused the ssl_ca option")
    end
  end

  return ok()
end

def set_number(mysql: Handle, option: Int, n: Int) -> Result[Void]
  refused: Bool = Native.memory_pointer(POINTER_SIZE) do |value|
    Native.put_int32(value, 0, n)
    mysql_options(mysql, option, value) != 0
  end

  if refused
    return error("mysql error: the client library refused a connection option")
  end

  return ok()
end

# A my_bool option set to true: one byte.
def set_flag(mysql: Handle, option: Int) -> Result[Void]
  refused: Bool = Native.memory_pointer(1) do |flag|
    Native.put_int8(flag, 0, 1)
    mysql_options(mysql, option, flag) != 0
  end

  if refused
    return error("mysql error: the client library refused a TLS option")
  end

  return ok()
end

# Frees the connection when it does not work: a failed connect still holds the error.
def abandon(mysql: Handle) -> Result[Handle]
  message = failure(mysql_errno(mysql), mysql_error(mysql))
  Native.close(mysql)
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

# A call with a closed resource stops the program, so a closed handle is turned into an error first.
def check_open(handle: Handle) -> Result[Void]
  if Native.closed?(handle)
    return error("mysql error: the connection is closed")
  end

  return ok()
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
def check_begin(mysql: Handle, verb: String) -> Result[Void]
  if (verb == "begin" or verb == "start") and in_transaction?(mysql)
    return error("mysql error: a transaction is already in progress")
  end

  return ok()
end

def in_transaction?(mysql: Handle) -> Bool
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

# A statement that is prepared. The caller closes it.
def start(mysql: Handle, sql: String) -> Result[Stmt]
  made = mysql_stmt_init(mysql)
  if not made.ok?
    return error("mysql error: out of memory")
  end

  stmt = try made
  # The length is given, so the sql needs no NUL at its end.
  if mysql_stmt_prepare(stmt, sql, sql.bytesize) != 0
    return refuse(stmt, stmt_failure(stmt))
  end

  return ok(stmt)
end

# True when the server refused to prepare a statement that has nothing to bind (error 1295, "This command is not
# supported in the prepared statement protocol yet"): it runs through the text protocol. A statement with
# parameters never does, since its values must be bound.
def text_only?(message: String, params: List[Value]) -> Bool
  return params.empty? and message.start_with?("mysql error #{UNSUPPORTED_PREPARE}:")
end

# Binds and runs a prepared statement, then reads its rows.
def launch_query(stmt: Stmt, params: List[Value]) -> Result[List[Row]]
  try launch(stmt, params)
  return read_rows(stmt)
end

# Binds and runs a prepared statement, then gives the rows it counts.
def launch_execute(stmt: Stmt, params: List[Value], verb: String) -> Result[Int]
  try launch(stmt, params)
  try drain(stmt)
  if COUNTING_VERBS.include?(verb)
    return ok(mysql_stmt_affected_rows(stmt))
  end

  return ok(0)
end

def launch(stmt: Stmt, params: List[Value]) -> Result[Void]
  wanted = mysql_stmt_param_count(stmt)
  if wanted != params.size
    return error("mysql error: the sql has #{wanted} #{noun(wanted)}, got #{params.size}")
  end

  if not send(stmt, params)
    return error(stmt_failure(stmt))
  end

  return ok()
end

# Closes the statement and gives the error.
def refuse(stmt: Stmt, message: String) -> Result[Stmt]
  Native.close(stmt)
  return error(message)
end

# True when the statement ran. The bind array and the buffers it points to must stay until the execute returns, so
# they are freed right after it, and nothing between the allocation and the free can return.
def send(stmt: Stmt, params: List[Value]) -> Bool
  sent: Bool = Native.memory_pointer(max_one(params.size) * Native.size_of(MysqlBind)) do |binds|
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
    case param
      Value.Null -> put_bind(binds, index, bind_at(binds, index).with(buffer_type: TYPE_NULL))
      Value.Int(n) -> owned = owned.push(bind_int(binds, index, n))
      Value.Bool(flag) -> owned = owned.push(bind_int(binds, index, bool_int(flag)))
      Value.Float(x) -> owned = owned.push(bind_float(binds, index, x))
      Value.Text(text) -> owned = owned.push(bind_text(binds, index, text))
      Value.Blob(bytes) -> owned = owned.push(bind_blob(binds, index, bytes))
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

# The bind at `index` of the array, which starts zeroed: every pointer in it is NULL until a field is set.
def bind_at(binds: C.Pointer, index: Int) -> MysqlBind
  return Native.get_struct(binds, index * Native.size_of(MysqlBind), MysqlBind)
end

def put_bind(binds: C.Pointer, index: Int, bind: MysqlBind) -> Void
  Native.put_struct(binds, index * Native.size_of(MysqlBind), bind)
end

# Points the bind at `index` to `buffer`, with the given type and `length` bytes.
def bind_buffer(binds: C.Pointer, index: Int, buffer: C.Pointer, type: Int, length: Int) -> C.Pointer
  put_bind(binds, index, bind_at(binds, index).with(buffer: buffer, buffer_type: type, buffer_length: length))
  return buffer
end

def bind_int(binds: C.Pointer, index: Int, n: Int) -> C.Pointer
  buffer = Native.memory_pointer(8)
  Native.put_int64(buffer, 0, n)
  return bind_buffer(binds, index, buffer, TYPE_LONGLONG, 8)
end

def bind_float(binds: C.Pointer, index: Int, x: Float) -> C.Pointer
  buffer = Native.memory_pointer(8)
  Native.put_float64(buffer, 0, x)
  return bind_buffer(binds, index, buffer, TYPE_DOUBLE, 8)
end

def bind_text(binds: C.Pointer, index: Int, text: String) -> C.Pointer
  return bind_buffer(binds, index, Native.from_string(text), TYPE_VAR_STRING, text.bytesize)
end

# A buffer holds at least one byte, so an empty blob still has a pointer.
def bind_blob(binds: C.Pointer, index: Int, bytes: List[Int]) -> C.Pointer
  buffer = Native.memory_pointer(max_one(bytes.size))
  if not bytes.empty?
    Native.put_bytes(buffer, 0, bytes)
  end

  return bind_buffer(binds, index, buffer, TYPE_BLOB, bytes.size)
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
  try distinct(columns)
  return fetch_all(stmt, columns)
end

def distinct(columns: List[Column]) -> Result[Void]
  names = columns.map do |column| column.name end
  if names.uniq.size != names.size
    return error("mysql error: the result has the column #{repeated_name(names)} twice, alias one of them")
  end

  return ok()
end

def repeated_name(names: List[String]) -> String
  counts = names.tally
  return names.find do |name| counts[name] > 1 end.unwrap_or("")
end

def describe(meta: C.Pointer) -> List[Column]
  columns: List[Column] = []
  for index in 0...mysql_num_fields(meta)
    field = Native.get_struct(mysql_fetch_field_direct(meta, index), 0, MysqlField)
    name = Native.get_string(field.name, 0)
    columns = columns.push(column_of(name, field.type, field.flags, field.charsetnr, field.max_length, field.length))
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
  elsif type == TYPE_JSON
    # MySQL gives a json column the binary character set, but it holds text.
    return Column(name: name, kind: KIND_TEXT, size: longest)
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
  read: Result[List[Row]] = Native.memory_pointer(columns.size * Native.size_of(MysqlBind)) do |binds|
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
    lengths = Native.memory_pointer(Native.size_of(UnsignedLong))
    slot = Slots(data: Native.memory_pointer(max_one(column.size)), length: lengths, null: Native.memory_pointer(8))
    put_bind(binds, index, bind_at(binds, index).with(length: slot.length, is_null: slot.null, buffer: slot.data,
                                                      buffer_length: column.size,
                                                      buffer_type: buffer_type(column.kind)))
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

# The length at `index` of an array of `unsigned long`, which C wrote.
def read_length(lengths: C.Pointer, index: Int) -> Int
  return Native.get_struct(lengths, index * Native.size_of(UnsignedLong), UnsignedLong).value
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

  length = read_length(slot.length, 0)
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

# The text protocol. One statement is sent as it is, and every value comes back as text, which is read by the kind
# of its column. It is for statements without parameters only.
def text_result(mysql: Handle, sql: String) -> Result[C.Pointer]
  if mysql_real_query(mysql, sql, sql.bytesize) != 0
    return error(failure(mysql_errno(mysql), mysql_error(mysql)))
  end

  # NULL is no result, or a failure when the statement should have had one.
  res = mysql_store_result(mysql)
  if Native.null?(res) and mysql_field_count(mysql) > 0
    return error(failure(mysql_errno(mysql), mysql_error(mysql)))
  end

  return ok(res)
end

# A statement that gives several results (a CALL) keeps the connection busy until they are read: the first is the
# answer, the rest are dropped.
def drop_results(mysql: Handle) -> Void
  while mysql_more_results(mysql) and mysql_next_result(mysql) == 0
    res = mysql_store_result(mysql)
    if not Native.null?(res)
      mysql_free_result(res)
    end
  end
end

def text_query(mysql: Handle, sql: String) -> Result[List[Row]]
  res = try text_result(mysql, sql)
  if Native.null?(res)
    drop_results(mysql)
    return ok([])
  end

  columns = describe(res)
  checked = distinct(columns)
  rows: List[Row] = []
  if checked.ok?
    rows = text_rows(res, columns)
  end

  mysql_free_result(res)
  drop_results(mysql)
  try checked
  return ok(rows)
end

def text_execute(mysql: Handle, sql: String, verb: String) -> Result[Int]
  res = try text_result(mysql, sql)
  if not Native.null?(res)
    mysql_free_result(res)
  end

  changed = 0
  if COUNTING_VERBS.include?(verb)
    changed = mysql_affected_rows(mysql)
  end

  drop_results(mysql)
  return ok(changed)
end

def text_rows(res: C.Pointer, columns: List[Column]) -> List[Row]
  rows: List[Row] = []
  fetched = mysql_fetch_row(res)
  while not Native.null?(fetched)
    lengths = mysql_fetch_lengths(res)
    row: Row = {}
    for index in 0...columns.size
      cell = Native.get_pointer(fetched, index * POINTER_SIZE)
      length = read_length(lengths, index)
      row = row.put(columns[index].name, text_value(columns[index], cell, length))
    end

    rows = rows.push(row)
    fetched = mysql_fetch_row(res)
  end

  return rows
end

# A number that does not read as one (a float with an exponent) stays text.
def text_value(column: Column, cell: C.Pointer, length: Int) -> Value
  if Native.null?(cell)
    return Value.Null
  elsif column.kind == KIND_BLOB
    return Value.Blob(Native.get_bytes(cell, 0, length))
  end

  text = Native.get_string(cell, 0, length)
  if column.kind == KIND_INT or column.kind == KIND_UNSIGNED
    return unsigned_value(text)
  elsif column.kind == KIND_FLOAT
    case text.to_f
      ok(x) -> return Value.Float(x)
      error(_) -> return Value.Text(text)
    end
  end

  return Value.Text(text)
end
