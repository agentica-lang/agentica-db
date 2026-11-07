## The PostgreSQL adapter, through the system libpq.
##
## `open` gives a `Connection`, which the task that opened it owns. Close it with `close`, or the end of the task
## closes it (PQfinish, the free function of the connection resource). A closed handle gives
## `postgres error: the connection is closed`.
##
## Two drivers run the statements. The native one (`native.agc`, a native module built from `native/db_postgres.c`)
## keeps libpq in its non-blocking mode and waits on the socket, so a query parks only its task and takes no compute
## call; it keeps a cache of prepared statements per connection (`statement_cache`, 100 by default, 0 for none) and
## reads many rows per call (`batch_rows`, `batch_bytes`). The FFI one (`ffi.agc`) runs each statement by its text, one
## call per value. `open` takes the native driver when its library loads and the FFI one only when it does not
## (compiled bytecode run where the built library is gone); `AGENTICA_DB_POSTGRES_DRIVER=native` or `ffi` chooses one
## (with `native`, a library that does not load is an error). A cached statement is a named prepared statement of the
## session, which a pooler in transaction mode (PgBouncer before 1.21) does not keep: use `statement_cache=0` there.
##
## `timeout_ms` (a parameter of the url or key of the conninfo, which libpq never sees, and an argument of `query` and
## `execute`) is the `statement_timeout` of the session: a statement that runs longer fails with `postgres error 57014:
## canceling statement due to statement timeout`, and the connection works after it. A call with its own limit sets it
## before the statement and puts the limit of the connection back after it (the server's own when the url sets none),
## in two more round trips; a call that asks for the limit it has costs none, and so does a statement that begins or
## ends a transaction or is a SET, which runs under the limit of the session. A `timeout_ms` of 0 (`NO_TIMEOUT`) lifts
## the limit of the url, but not one that the server sets on its own when the url has none. A `SET statement_timeout`
## you run yourself is undone by the put-back of the next call that has its own limit, and so is a `SELECT
## set_config('statement_timeout', ...)`, which is a statement like any other. A `SET LOCAL statement_timeout` is lost
## the same way: the call's own limit replaces it for the rest of the transaction, and the put-back restores the limit
## of the connection, not yours.
##
## An engine failure is `postgres error <sqlstate>: <message>`, with the five character SQLSTATE of the server
## (`23505` for a unique violation) and its primary message. A failure without a SQLSTATE (the connection is lost,
## `open` fails) and a bad input are `postgres error: <message>`.

import PostgresFfi from "ffi"
import PostgresNative from "native"
import PostgresSql from "sql"
import PostgresUrl from "url"
import {Row, Value} from "../support/value"

## The statement that starts a transaction.
export BEGIN_SQL = "BEGIN"
CONNECTION_OK = 0
# PGTransactionStatusType: a transaction is open (INTRANS) or failed (INERROR), or the state is not known.
PQTRANS_INTRANS = 2
PQTRANS_INERROR = 3
PQTRANS_UNKNOWN = 4
# The verbs of the statements that begin, end or step inside a transaction, and `set` (`SET TRANSACTION` fails after
# any other statement of the transaction, 25001).
TRANSACTION_VERBS = Set.new(["begin", "start", "commit", "end", "rollback", "abort", "savepoint", "release", "set"])
SET_TIMEOUT_SQL = "SELECT set_config('statement_timeout', ?, false)"
DRIVER_VARIABLE = "AGENTICA_DB_POSTGRES_DRIVER"

## An open connection and the `statement_timeout` it was opened with (0: none). `link` is public because a struct
## has no private fields, but its type is not exported (a user cannot name it): treat it as opaque and pass the
## `Connection` around.
export struct Connection
  link: Link
  timeout_ms: Int = 0
end

# The connection of the driver that runs it.
enum Link
  Native(PostgresNative.Session)
  Ffi(PostgresFfi.Handle)
end

# libpq's PQstatus and PQtransactionStatus of a connection.
struct Status
  connection: Int
  transaction: Int
end

## Connects with a `postgres://` or `postgresql://` url, which libpq parses (`?sslmode=disable`, `connect_timeout`
## and the other parameters of the url work as in libpq), or with a conninfo string. `timeout_ms`, `statement_cache`,
## `batch_rows` and `batch_bytes` are read here, not by libpq. The client encoding is set to UTF8.
export def open(url: String) -> Result[Connection]
  if has_nul?(url)
    return error("postgres error: the url contains a NUL character")
  end

  target = try PostgresUrl.parse(url)
  link = try connect(target)
  conn = Connection(link: link, timeout_ms: target.timeout_ms)
  try limit_session(conn)
  return ok(conn)
end

## Closes the connection; closing it again does nothing.
export def close(conn: Connection) -> Void
  case conn.link
    Link.Native(session) -> Native.close(session.conn)
    Link.Ffi(handle) -> Native.close(handle)
  end
end

## Runs one statement with bound parameters and gives its rows, which are empty for a statement without a result.
## Two columns with one name are an error: alias them. `timeout_ms` is the limit of this call: -1 takes the one of
## the connection, 0 is none.
export def query(conn: Connection, sql: String, params: List[Value], timeout_ms: Int = -1) -> Result[List[Row]]
  return limited(conn, timeout_ms, sql) do run_query(conn.link, sql, params) end
end

## Runs one statement with bound parameters and gives the number of rows it inserted, updated or deleted.
## `timeout_ms` is as in `query`.
export def execute(conn: Connection, sql: String, params: List[Value], timeout_ms: Int = -1) -> Result[Int]
  return limited(conn, timeout_ms, sql) do run_execute(conn.link, sql, params) end
end

## Whether a transaction is open or failed and waits for its ROLLBACK, as libpq knows it: no round trip. A closed
## connection is not in one.
export def in_transaction?(conn: Connection) -> Bool
  if closed?(conn.link)
    return false
  end

  status = status_of(conn.link).transaction
  return status == PQTRANS_INTRANS or status == PQTRANS_INERROR
end

## Whether libpq still has the connection up, from its own state and with no round trip: it is open, its status is OK
## and the transaction status is known. A connection the server ended shows here after the first call that fails on it.
export def connected?(conn: Connection) -> Bool
  if closed?(conn.link)
    return false
  end

  status = status_of(conn.link)
  return status.connection == CONNECTION_OK and status.transaction != PQTRANS_UNKNOWN
end

## Whether the connection works: libpq says it is up and the server answers `SELECT 1`. A failed transaction is
## healthy, since the connection is.
export def healthy?(conn: Connection) -> Bool
  if closed?(conn.link)
    return false
  end

  status = status_of(conn.link)
  if status.connection != CONNECTION_OK or status.transaction == PQTRANS_UNKNOWN
    return false
  end

  if status.transaction == PQTRANS_INERROR
    return true
  end

  return run_query(conn.link, "SELECT 1", []).ok?
end

## The statement cache of a connection of the native driver; none for the FFI driver, which has none, and for a closed
## connection.
export def statement_cache(conn: Connection) -> Optional[PostgresNative.CacheStats]
  case conn.link
    Link.Native(session) -> return PostgresNative.stats(session)
    Link.Ffi(_) -> return none
  end
end

# The driver that the variable names, else the native one when its library loads, else the FFI one.
def connect(target: PostgresUrl.Target) -> Result[Link]
  choice = System.env(DRIVER_VARIABLE).unwrap_or("")
  if choice == "ffi" or (choice == "" and not PostgresNative.available?())
    handle = try PostgresFfi.open(target.conninfo)
    return ok(Link.Ffi(handle))
  end

  if choice != "" and choice != "native"
    return error("postgres error: #{DRIVER_VARIABLE} is #{choice}, expected native or ffi")
  end

  if not PostgresNative.available?()
    return error("postgres error: the native driver is not built (#{DRIVER_VARIABLE}=native)")
  end

  options = PostgresNative.Options(rows: target.batch_rows, bytes: target.batch_bytes)
  session = try PostgresNative.open(target.conninfo, target.statement_cache, options)
  return ok(Link.Native(session))
end

def closed?(link: Link) -> Bool
  case link
    Link.Native(session) -> return PostgresNative.closed?(session)
    Link.Ffi(handle) -> return Native.closed?(handle)
  end
end

def status_of(link: Link) -> Status
  both = 0
  case link
    Link.Native(session) -> both = PostgresNative.link_status(session)
    Link.Ffi(handle) -> both = PostgresFfi.status(handle)
  end

  return Status(connection: both / 16, transaction: both % 16)
end

def run_query(link: Link, sql: String, params: List[Value]) -> Result[List[Row]]
  try check_open(link)
  case link
    Link.Native(session) -> return PostgresNative.query(session, sql, params)
    Link.Ffi(handle) -> return PostgresFfi.query(handle, sql, params)
  end
end

def run_execute(link: Link, sql: String, params: List[Value]) -> Result[Int]
  try check_open(link)
  case link
    Link.Native(session) -> return PostgresNative.execute(session, sql, params)
    Link.Ffi(handle) -> return PostgresFfi.execute(handle, sql, params)
  end
end

# A call with a closed resource stops the program, so a closed handle is turned into an error first.
def check_open(link: Link) -> Result[Void]
  if closed?(link)
    return error("postgres error: the connection is closed")
  end

  return ok()
end

# Runs `body` under the limit of the call. A limit other than the session's is set before and put back after, also
# when the body failed. A statement that controls a transaction runs under the limit of the session: a SET before a
# BEGIN would stay out of the transaction while its put-back went in, and a ROLLBACK of an aborted transaction cannot
# be preceded by any other statement. The put-back is not part of the result. It runs under the short limit of the
# call, so it can fail like any statement: on a lost connection (the next call says so), in a transaction that the
# body's failure aborted (the rollback undoes the SET too), or on a timeout of its own; the connection then keeps the
# limit of the call until the next put-back.
def limited[R](conn: Connection, timeout_ms: Int, sql: String, body: Fn[Result[R]]) -> Result[R]
  if timeout_ms < 0 or timeout_ms == conn.timeout_ms or controls_transaction?(sql)
    return body.call()
  end

  try set_statement_timeout(conn.link, timeout_ms)
  done = body.call()
  put_back_statement_timeout(conn)
  return done
end

def controls_transaction?(sql: String) -> Bool
  case PostgresSql.translate(sql)
    error(_) -> return false
    ok(translated) -> return TRANSACTION_VERBS.include?(translated.verb)
  end
end

def limit_session(conn: Connection) -> Result[Void]
  if conn.timeout_ms == 0
    return ok()
  end

  set = set_statement_timeout(conn.link, conn.timeout_ms)
  case set
    ok(_) -> return ok()
    error(message) ->
      close(conn)
      return error(message)
  end
end

# `set_config` takes the value as a parameter, which `SET` does not.
def set_statement_timeout(link: Link, ms: Int) -> Result[Void]
  try run_query(link, SET_TIMEOUT_SQL, [Value.Text(ms.to_s)])
  return ok()
end

# The limit of the url, or, when the url sets none, whatever the server gives the session (a role or database setting,
# or the `options` of the url): a NULL value resets the variable to that.
def put_back_statement_timeout(conn: Connection) -> Void
  if conn.timeout_ms > 0
    _ = set_statement_timeout(conn.link, conn.timeout_ms)
  else
    _ = run_query(conn.link, SET_TIMEOUT_SQL, [Value.Null])
  end
end

# A NUL ends a C.String early, and the VM stops the program at the call (RUNTIME-INVALID-CHARACTER).
def has_nul?(text: String) -> Bool
  return text.include?(String.from_code(0))
end
