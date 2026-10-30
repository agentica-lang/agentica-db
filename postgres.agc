## The PostgreSQL adapter, through the system libpq.
##
## `open` gives a `Handle`, which the task that opened it owns. Close it with `close`, or the end of the task closes
## it (PQfinish, the free function of the connection resource). A closed handle gives
## `postgres error: the connection is closed`.
##
## An engine failure is `postgres error <sqlstate>: <message>`, with the five character SQLSTATE of the server
## (`23505` for a unique violation) and its primary message. A failure without a SQLSTATE (the connection is lost,
## `open` fails) and a bad input are `postgres error: <message>`.

import PostgresSql from "postgres_sql"
import {Row, Value} from "value"

## The statement that starts a transaction.
export BEGIN_SQL = "BEGIN"
CONNECTION_OK = 0
PGRES_EMPTY_QUERY = 0
PGRES_COMMAND_OK = 1
PGRES_TUPLES_OK = 2
PGRES_COPY_OUT = 3
PGRES_COPY_IN = 4
# The field codes of PQresultErrorField: the characters 'C' and 'M'.
PG_DIAG_SQLSTATE = 67
PG_DIAG_MESSAGE_PRIMARY = 77
# Type oids of pg_type.h that have a Value variant; every other type comes back as text.
BOOL_OID = 16
BYTEA_OID = 17
INT8_OID = 20
INT2_OID = 21
INT4_OID = 23
FLOAT4_OID = 700
FLOAT8_OID = 701
POINTER_SIZE = 8
RESULT_AS_TEXT = 0
CLIENT_ENCODING_SET = 0
IS_NULL = 1
COPY_BLOCKING = 0
NO_MORE_COPY_DATA = 0
HEX_BASE = 16
# PGTransactionStatusType: a transaction is open (INTRANS) or failed (INERROR).
PQTRANS_INTRANS = 2
PQTRANS_INERROR = 3
ABORTED_COMMIT_SQLSTATE = "25P02"
ACTIVE_TRANSACTION_SQLSTATE = "25001"
# The statements whose command tag counts rows changed; a SELECT counts rows too, but execute does not report them.
COUNTING_TAGS = Set.new(["INSERT", "UPDATE", "DELETE", "MERGE"])
HEX_DIGITS = "0123456789abcdef"
# Far past the range of a double: a decimal string this long reads as infinity or zero.
EXPONENT_LIMIT = 400

# The libpq names start with a capital letter, which a def name cannot, so each def says its C name.
extern "pq"
  ## An open connection.
  export resource Handle, free: PQfinish
  compute def pq_connectdb(conninfo: C.String) -> Handle = "PQconnectdb"
  def pq_status(conn: Handle) -> C.Int32 = "PQstatus"
  def pq_transaction_status(conn: Handle) -> C.Int32 = "PQtransactionStatus"
  def pq_error_message(conn: Handle) -> C.String = "PQerrorMessage"
  # The two calls below wait for the server, so they are compute.
  compute def pq_set_client_encoding(conn: Handle, encoding: C.String) -> C.Int32 = "PQsetClientEncoding"
  compute def pq_exec_params(conn: Handle, command: C.String, count: C.Int32, types: C.Pointer,
                             values: C.Pointer, lengths: C.Pointer, formats: C.Pointer,
                             format: C.Int32) -> C.Pointer = "PQexecParams"
  def pq_clear(res: C.Pointer) -> Void = "PQclear"
  def pq_result_status(res: C.Pointer) -> C.Int32 = "PQresultStatus"
  def pq_result_error_field(res: C.Pointer, field: C.Int32) -> C.String = "PQresultErrorField"
  def pq_cmd_status(res: C.Pointer) -> C.String = "PQcmdStatus"
  def pq_cmd_tuples(res: C.Pointer) -> C.String = "PQcmdTuples"
  def pq_nfields(res: C.Pointer) -> C.Int32 = "PQnfields"
  def pq_ntuples(res: C.Pointer) -> C.Int32 = "PQntuples"
  def pq_fname(res: C.Pointer, col: C.Int32) -> C.String = "PQfname"
  # An Oid is unsigned 32 bits; read as C.Int32, one above 2^31 is negative and matches no type here, so it is text.
  def pq_ftype(res: C.Pointer, col: C.Int32) -> C.Int32 = "PQftype"
  def pq_getisnull(res: C.Pointer, row: C.Int32, col: C.Int32) -> C.Int32 = "PQgetisnull"
  def pq_getvalue(res: C.Pointer, row: C.Int32, col: C.Int32) -> C.Pointer = "PQgetvalue"
  def pq_unescape_bytea(text: C.Pointer, out length: C.Int64) -> C.Pointer = "PQunescapeBytea"
  def pq_freemem(memory: C.Pointer) -> Void = "PQfreemem"
  # The calls that leave a COPY that a statement started.
  def pq_put_copy_end(conn: Handle, message: C.String) -> C.Int32 = "PQputCopyEnd"
  compute def pq_get_copy_data(conn: Handle, out data: C.Pointer, async: C.Int32) -> C.Int32 = "PQgetCopyData"
  compute def pq_get_result(conn: Handle) -> C.Pointer = "PQgetResult"
end

## Connects with a `postgres://` or `postgresql://` url, which libpq parses (`?sslmode=disable`, `connect_timeout`
## and the other parameters of the url work as in libpq). The client encoding is set to UTF8.
export def open(url: String) -> Result[Handle]
  if has_nul?(url)
    return error("postgres error: the url contains a NUL character")
  end

  try load_library()
  case pq_connectdb(url)
    error(_) -> return error("postgres error: out of memory")
    ok(conn) ->
      try check_connection(conn)
      return ok(conn)
  end
end

## Closes the connection; closing it again does nothing.
export def close(handle: Handle) -> Void
  Native.close(handle)
end

## Runs one statement with bound parameters and gives its rows, which are empty for a statement without a result.
## Two columns with one name are an error: alias them.
export def query(handle: Handle, sql: String, params: List[Value]) -> Result[List[Row]]
  res = try run(handle, sql, params)
  names = column_names(res)
  if names.uniq.size != names.size
    pq_clear(res)
    return error("postgres error: the result has the column #{repeated_name(names)} twice, alias one of them")
  end

  rows = read_rows(res, names)
  pq_clear(res)
  return rows
end

## Runs one statement with bound parameters and gives the number of rows it inserted, updated or deleted.
export def execute(handle: Handle, sql: String, params: List[Value]) -> Result[Int]
  res = try run(handle, sql, params)
  changed = changed_rows(res)
  pq_clear(res)
  return changed
end

# A library that is missing is an error here, not a stop of the program at the first call.
def load_library() -> Result[Void]
  case Native.load("pq")
    error(message) -> return error("postgres error: cannot load the libpq library: #{message}")
    ok(_) -> return ok()
  end
end

# Frees the connection when it does not work: a failed connect still gives a PGconn that holds the error.
def check_connection(conn: Handle) -> Result[Void]
  if pq_status(conn) != CONNECTION_OK
    return abandon(conn)
  end

  # Text results are read as UTF-8 whatever the server or the environment default to.
  if pq_set_client_encoding(conn, "UTF8") != CLIENT_ENCODING_SET
    return abandon(conn)
  end

  return ok()
end

def abandon(conn: Handle) -> Result[Void]
  message = pq_error_message(conn).strip
  Native.close(conn)
  return error("postgres error: #{message}")
end

def repeated_name(names: List[String]) -> String
  counts = names.tally
  return names.find do |name| counts[name] > 1 end.unwrap_or("")
end

# A call with a closed resource stops the program, so a closed handle is turned into an error first.
def check_open(handle: Handle) -> Result[Void]
  if Native.closed?(handle)
    return error("postgres error: the connection is closed")
  end

  return ok()
end

# The result of a statement that succeeded. The caller clears it.
def run(handle: Handle, sql: String, params: List[Value]) -> Result[C.Pointer]
  try check_open(handle)
  translated = try PostgresSql.translate(sql)
  if translated.count != params.size
    wanted = translated.count
    return error("postgres error: the sql has #{wanted} #{noun(wanted)}, got #{params.size}")
  end

  try check_params(params)
  verb = translated.verb
  try check_begin(handle, verb)
  res = exec_params(handle, translated.sql, params)
  if Native.null?(res)
    return error("postgres error: #{pq_error_message(handle).strip}")
  end

  return accept(handle, res, verb)
end

# PostgreSQL only warns about a BEGIN inside a transaction, and the inner COMMIT would then end the outer one:
# transactions do not nest here, as in the other adapters.
def check_begin(conn: Handle, verb: String) -> Result[Void]
  status = pq_transaction_status(conn)
  if (verb == "begin" or verb == "start") and (status == PQTRANS_INTRANS or status == PQTRANS_INERROR)
    return error("postgres error #{ACTIVE_TRANSACTION_SQLSTATE}: a transaction is already in progress")
  end

  return ok()
end

def noun(count: Int) -> String
  if count == 1
    return "parameter"
  end

  return "parameters"
end

def check_params(params: List[Value]) -> Result[Void]
  for param in params
    case param
      Value.Text(text) ->
        if has_nul?(text)
          return error("postgres error: a text parameter contains a NUL character")
        end

      Value.Null -> next
      Value.Int(_) -> next
      Value.Float(_) -> next
      Value.Bool(_) -> next
      Value.Blob(_) -> next
    end
  end

  return ok()
end

# Parameters travel as text and the server infers their types from the sql. A NULL entry of the value array is
# the SQL NULL. The value array goes away with its block, and the text buffers are freed right after the call, on
# every path: nothing between the allocation and the free can return.
def exec_params(conn: Handle, sql: String, params: List[Value]) -> C.Pointer
  null = Native.null()
  res: C.Pointer = Native.memory_pointer(max_one(params.size) * POINTER_SIZE) do |values|
    owned = fill_values(values, params)
    sent = pq_exec_params(conn, sql, params.size, null, values, null, null, RESULT_AS_TEXT)
    for buffer in owned
      Native.free(buffer)
    end

    sent
  end

  return res
end

def max_one(count: Int) -> Int
  if count < 1
    return 1
  end

  return count
end

def fill_values(values: C.Pointer, params: List[Value]) -> List[C.Pointer]
  owned: List[C.Pointer] = []
  index = 0
  for param in params
    case param
      Value.Null -> Native.put_pointer(values, index * POINTER_SIZE, Native.null())
      Value.Int(n) -> owned = owned.push(put_text(values, index, n.to_s))
      Value.Float(x) -> owned = owned.push(put_text(values, index, float_text(x)))
      Value.Text(text) -> owned = owned.push(put_text(values, index, text))
      Value.Blob(bytes) -> owned = owned.push(put_text(values, index, bytea_text(bytes)))
      Value.Bool(flag) -> owned = owned.push(put_text(values, index, bool_text(flag)))
    end

    index += 1
  end

  return owned
end

def put_text(values: C.Pointer, index: Int, text: String) -> C.Pointer
  buffer = Native.memory_pointer(text.bytesize + 1)
  Native.put_string(buffer, 0, text)
  Native.put_pointer(values, index * POINTER_SIZE, buffer)
  return buffer
end

def bool_text(flag: Bool) -> String
  if flag
    return "t"
  end

  return "f"
end

# The spellings of the server for the values that Float#to_s writes as +inf.0, -inf.0 and +nan.0.
def float_text(x: Float) -> String
  text = x.to_s
  if text == "+inf.0"
    return "Infinity"
  elsif text == "-inf.0"
    return "-Infinity"
  elsif text == "+nan.0"
    return "NaN"
  end

  return text
end

# The hex input form of bytea: a backslash, an x and two digits per byte.
def bytea_text(bytes: Bytes) -> String
  digits = HEX_DIGITS.split("")
  pairs = bytes.to_a.map do |byte| digits[byte / HEX_BASE] + digits[byte % HEX_BASE] end
  return "\\x" + pairs.join("")
end

# Gives the result of a statement that succeeded; any other result is cleared and becomes the error.
def accept(conn: Handle, res: C.Pointer, verb: String) -> Result[C.Pointer]
  status = pq_result_status(res)
  if status == PGRES_COMMAND_OK or status == PGRES_TUPLES_OK
    return check_commit(res, verb)
  end

  if status == PGRES_EMPTY_QUERY
    pq_clear(res)
    return error("postgres error: the sql has no statement")
  end

  if status == PGRES_COPY_IN or status == PGRES_COPY_OUT
    pq_clear(res)
    leave_copy(conn, status)
    return error("postgres error: COPY is not supported")
  end

  message = failure(conn, res)
  pq_clear(res)
  return error(message)
end

# A COMMIT of a transaction that failed does not fail: the server rolls it back and says ROLLBACK. The data is
# lost, so the call must not look like a commit.
def check_commit(res: C.Pointer, verb: String) -> Result[C.Pointer]
  if pq_cmd_status(res) == "ROLLBACK" and (verb == "commit" or verb == "end")
    pq_clear(res)
    return error("postgres error #{ABORTED_COMMIT_SQLSTATE}: the transaction failed, COMMIT rolled it back")
  end

  return ok(res)
end

# The code is the SQLSTATE of the server; a failure that libpq makes itself has none.
def failure(conn: Handle, res: C.Pointer) -> String
  code = pq_result_error_field(res, PG_DIAG_SQLSTATE)
  message = pq_result_error_field(res, PG_DIAG_MESSAGE_PRIMARY)
  if code == ""
    return "postgres error: #{pq_error_message(conn).strip}"
  end

  return "postgres error #{code}: #{message}"
end

# A statement that starts a COPY leaves the connection in copy mode: end it, then read the results that follow.
def leave_copy(conn: Handle, status: Int) -> Void
  if status == PGRES_COPY_IN
    pq_put_copy_end(conn, "copy is not supported")
  else
    skip_copy_data(conn)
  end

  res = pq_get_result(conn)
  while not Native.null?(res)
    pq_clear(res)
    res = pq_get_result(conn)
  end
end

def skip_copy_data(conn: Handle) -> Void
  while true
    read = pq_get_copy_data(conn, COPY_BLOCKING)
    if read.result <= NO_MORE_COPY_DATA
      return
    end

    pq_freemem(read.data)
  end
end

# The rows an INSERT, UPDATE, DELETE or MERGE changed; anything else changed none.
def changed_rows(res: C.Pointer) -> Result[Int]
  verb = pq_cmd_status(res).split(" ")[0]
  if not COUNTING_TAGS.include?(verb)
    return ok(0)
  end

  counted = pq_cmd_tuples(res)
  if counted == ""
    return ok(0)
  end

  return counted.to_i
end

def column_names(res: C.Pointer) -> List[String]
  names: List[String] = []
  for col in 0...pq_nfields(res)
    names = names.push(pq_fname(res, col))
  end

  return names
end

def column_types(res: C.Pointer) -> List[Int]
  types: List[Int] = []
  for col in 0...pq_nfields(res)
    types = types.push(pq_ftype(res, col))
  end

  return types
end

def read_rows(res: C.Pointer, names: List[String]) -> Result[List[Row]]
  types = column_types(res)
  rows: List[Row] = []
  for line in 0...pq_ntuples(res)
    row: Row = {}
    for col in 0...names.size
      value = try read_value(res, line, col, types[col])
      row = row.put(names[col], value)
    end

    rows = rows.push(row)
  end

  return ok(rows)
end

def read_value(res: C.Pointer, line: Int, col: Int, oid: Int) -> Result[Value]
  if pq_getisnull(res, line, col) == IS_NULL
    return ok(Value.Null)
  end

  cell = pq_getvalue(res, line, col)
  if oid == BYTEA_OID
    bytes = try read_bytea(cell)
    return ok(Value.Blob(bytes))
  end

  text = Native.get_string(cell, 0)
  if oid == INT2_OID or oid == INT4_OID or oid == INT8_OID
    n = try text.to_i
    return ok(Value.Int(n))
  elsif oid == FLOAT4_OID or oid == FLOAT8_OID
    x = try parse_float(text)
    return ok(Value.Float(x))
  elsif oid == BOOL_OID
    return ok(Value.Bool(text == "t"))
  end

  return ok(Value.Text(text))
end

# pq_unescape_bytea reads the hex form and the older escape form.
def read_bytea(cell: C.Pointer) -> Result[Bytes]
  unescaped = pq_unescape_bytea(cell)
  if Native.null?(unescaped.result)
    return error("postgres error: out of memory")
  end

  bytes = Native.get_bytes(unescaped.result, 0, unescaped.length)
  pq_freemem(unescaped.result)
  return ok(bytes)
end

# The server writes a float as shortest digits that read back exactly, with an exponent for large and small
# values (`1e+20`, `-1.5e-07`), and Infinity, -Infinity and NaN. String#to_f takes none of those, so the exponent
# is moved into the digits as text (exact: no arithmetic) and the decimal string is read whole.
def parse_float(text: String) -> Result[Float]
  if text == "Infinity"
    return ok(infinity())
  elsif text == "-Infinity"
    return ok(0.0 - infinity())
  elsif text == "NaN"
    return ok(infinity() - infinity())
  end

  parts = text.downcase.split("e")
  if parts.size == 1
    return read_decimal(text)
  end

  exponent = try parts[1].to_i
  return read_decimal(shift_point(parts[0], exponent))
end

# String#to_f reads integer text such as `-0` as 0.0; with a fraction it keeps the sign of zero.
def read_decimal(text: String) -> Result[Float]
  if text.include?(".")
    return text.to_f
  end

  return "#{text}.0".to_f
end

def infinity() -> Float
  return ("1" + List.repeat("0", EXPONENT_LIMIT).join("")).to_f!
end

def shift_point(mantissa: String, exponent: Int) -> String
  negative = mantissa.start_with?("-")
  unsigned = mantissa.replace("-", "").replace("+", "")
  halves = unsigned.split(".")
  whole = halves[0]
  fraction = ""
  if halves.size > 1
    fraction = halves[1]
  end

  digits = whole + fraction
  point = clamp(whole.length + exponent, 0 - EXPONENT_LIMIT, EXPONENT_LIMIT)
  shifted = place_point(digits, point)
  if negative
    return "-" + shifted
  end

  return shifted
end

def clamp(n: Int, low: Int, high: Int) -> Int
  if n < low
    return low
  elsif n > high
    return high
  end

  return n
end

# The digits with the decimal point `point` places from their start; a point outside them pads with zeros.
def place_point(digits: String, point: Int) -> String
  if point <= 0
    return "0." + List.repeat("0", 0 - point).join("") + digits
  elsif point >= digits.length
    return digits + List.repeat("0", point - digits.length).join("") + ".0"
  end

  return digits.slice(0, point) + "." + digits.slice(point, digits.length - point)
end

# A NUL ends a C.String early, and the VM stops the program at the call (RUNTIME-INVALID-CHARACTER).
def has_nul?(text: String) -> Bool
  return text.include?(String.from_code(0))
end
