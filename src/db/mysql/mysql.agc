## The MySQL and MariaDB adapter, through the system MariaDB Connector/C (`libmariadb.so.3`), which speaks to MySQL
## and MariaDB servers alike.
##
## `open` gives a `Connection`, which the task that opened it owns. Close it with `close`, or the end of the task closes
## it (`mysql_close`, the free function of the connection resource), as in the other adapters. A closed connection
## gives `mysql error: the connection is closed`.
##
## Two drivers run the statements, with the same values and errors. The native one (`native.agc`, a native module built
## from `native/db_mysql.c`) runs the non-blocking calls of the library and waits on the socket, so a query parks only
## its task and takes no compute call; it keeps a cache of prepared statements per connection (`statement_cache`, 100
## by default, 0 for none) and reads many rows per call (`batch_rows`, `batch_bytes`). The FFI one (`ffi.agc`) prepares
## each statement again, waits on the compute pool and reads one value per call. `open` takes the native driver when
## it runs here, else the FFI one; `AGENTICA_DB_MYSQL_DRIVER=native` or `ffi` chooses one (with `native`, a driver that
## does not run here is an error).
##
## Every statement goes through the prepared statement API (`mysql_stmt_*`): the sql is sent as it is, with its `?`
## placeholders, and the values are bound, never spliced.
##
## `timeout_ms` (a parameter of the url, and an argument of `query` and `execute`) bounds a statement on the server.
## The adapter reads the flavor of the server from its version at `open`. MySQL gets `max_execution_time`, which limits
## only a SELECT: a statement that runs longer fails with `mysql error 3024`. A `DO` or an `INSERT` is not bounded on
## MySQL. MariaDB gets `max_statement_time`, in seconds, which limits every statement: `mysql error 1969`. An
## interrupted `SLEEP()` ends early without an error: `select sleep(5)` on MySQL 8.4, `DO SLEEP(20)` on MariaDB.
##
## A call with its own limit sets the variable before the statement and puts the limit of the connection back after it
## (the default of the server when the url sets none), in two more round trips; a call that asks for the limit it has
## costs none.
##
## A url with `timeout_ms` also sets the client read and write timeouts, in whole seconds, to that limit plus 10
## seconds, as a backstop for what the server does not time (a `DO` or an `INSERT` on MySQL, a lost network): a
## statement that hits it fails with `mysql error 2013` (lost connection) and the connection is gone. The backstop is
## fixed at `open`, so a call that asks for a limit longer than the one of the url, `NO_TIMEOUT` included, is cut at
## the backstop.
##
## An engine failure is `mysql error <code>: <message>`, with the numeric code of the server (`1062` for a duplicate
## key) or of the client library (`2002` for a server that cannot be reached) and its message. A bad input is
## `mysql error: <message>`. A message never holds the url or the password.

import MysqlFfi from "ffi"
import MysqlNative from "native"
import MysqlUrl from "url"
import {Row, Value} from "../support/value"

## The statement that starts a transaction.
BEGIN_SQL = "START TRANSACTION"

## The server software, which decides the variable that limits a statement.
enum Flavor
  MySql
  MariaDb
end

## An open connection, the server it talks to, the limit of a statement it was opened with (0: none) and who it is on
## the server, for `interrupt`. `link` is public because a struct has no private fields, but its type is not exported
## (a user cannot name it): treat it as opaque and pass the `Connection` around.
struct Connection
  link: Link
  flavor: Flavor
  timeout_ms: Int = 0
  identity: Identity
end

## The `CONNECTION_ID()` of a connection, the server that gave it (`@@server_id@@@hostname:@@port`; empty when not
## known) and when that server started, in Unix seconds.
struct Identity
  id: Int
  server: String
  started: Int
end

## Connects with a `mysql://` or `mariadb://` url (see `MysqlUrl`). The client character set is utf8mb4.
def open(url: String) -> Result[Connection]
  target = try MysqlUrl.parse(url)
  link = try connect(target)
  conn = Connection(
    link: link,
    flavor: flavor_of(server_version(link)),
    timeout_ms: target.timeout_ms,
    identity: identity_of(link),
  )

  limited = limit_session(conn)
  case limited
    ok(_) -> ok(conn)
    error(message) ->
      close(conn)
      error(message)
  end
end

## Closes the connection; closing it again does nothing.
def close(conn: Connection) -> Void
  close_link(conn.link)
end

## Stops the statement that runs on the connection, if any: `KILL QUERY` from a connection of its own to `url`, the
## url of this one, which connects within `connect_timeout` and at most 5 s. The kill is skipped when that connection
## reached another server (a load balancer), one that restarted since, or the identity is not known. The pool sends
## it when a block runs past `lease_ms`. Not for `Db`.
def interrupt(conn: Connection, url: String) -> Void
  return if closed?(conn.link) or conn.identity.server.empty?

  case MysqlUrl.parse(url)
    error(_) -> return
    ok(target) ->
      case connect(target.with(timeout: killer_timeout(target.timeout)))
        error(_) -> return
        ok(killer) ->
          # A cancel of this task leaves the killer to the end of the task, which frees it.
          kill_query(killer, conn.identity)
          close_link(killer)
      end
  end
end

## Runs one statement with bound parameters and gives its rows, which are empty for a statement without a result.
## Two columns with one name are an error: alias them. `timeout_ms` is the limit of this call: -1 takes the one of the
## connection, 0 is none. A statement without parameters that the server does not prepare (`START TRANSACTION`,
## `BEGIN`, `SAVEPOINT`, `USE` and `LOCK TABLES` on MySQL) goes through the text protocol, which is safe because there
## is nothing to bind.
def query(conn: Connection, sql: String, params: List[Value], timeout_ms: Int = -1) -> Result[List[Row]]
  limited(conn, timeout_ms) do run_query(conn.link, sql, params) end
end

## Runs one statement with bound parameters and gives the number of rows it inserted, updated (matched), deleted or
## replaced. The text protocol is used as for `query`, and `timeout_ms` is as there.
def execute(conn: Connection, sql: String, params: List[Value], timeout_ms: Int = -1) -> Result[Int]
  limited(conn, timeout_ms) do run_execute(conn.link, sql, params) end
end

## Whether the server says a transaction is open on the connection, from the status of its last reply: no round trip.
## A closed connection is not in one.
def in_transaction?(conn: Connection) -> Bool
  case conn.link
    Link.Native(session) -> MysqlNative.in_transaction?(session)
    Link.Ffi(handle) -> not Native.closed?(handle) and MysqlFfi.in_transaction?(handle)
  end
end

## Whether the connection is open and the client library still has its link to the server, with no round trip. The
## library closes the link when a call finds the server gone (error 2006 or 2013), so a connection the server ended
## shows here after the first call that fails on it; `healthy?` asks the server.
def connected?(conn: Connection) -> Bool
  case conn.link
    Link.Native(session) -> MysqlNative.connected?(session)
    Link.Ffi(handle) -> not Native.closed?(handle) and MysqlFfi.connected?(handle)
  end
end

## Whether the connection works: it is open and the server answers (a ping, or `SELECT 1` on the native driver).
def healthy?(conn: Connection) -> Bool
  case conn.link
    Link.Native(session) -> not MysqlNative.closed?(session) and MysqlNative.query(session, "SELECT 1", []).ok?
    Link.Ffi(handle) -> not Native.closed?(handle) and MysqlFfi.healthy?(handle)
  end
end

## The statement cache of a connection of the native driver; none for the FFI driver, which has none, and for a closed
## connection.
def statement_cache(conn: Connection) -> Optional[MysqlNative.CacheStats]
  case conn.link
    Link.Native(session) -> MysqlNative.stats(session)
    Link.Ffi(_) -> none
  end
end

private

MS_PER_SECOND = 1000
DRIVER_VARIABLE = "AGENTICA_DB_MYSQL_DRIVER"
IDENTITY_SQL = (
  "SELECT CONNECTION_ID() AS id, @@server_id AS server_id, @@hostname AS host, @@port AS port, UNIX_TIMESTAMP() AS now"
)
UPTIME_SQL = "SHOW GLOBAL STATUS LIKE 'Uptime'"
# Two reads of the start time of one server differ by the rounding of UNIX_TIMESTAMP() and Uptime.
START_SLACK_S = 2
UNKNOWN = Identity(id: 0, server: "", started: 0)
KILLER_CONNECT_S = 5
CLOSED = "mysql error: the connection is closed"

# The connection of the driver that runs it.
enum Link
  Native(MysqlNative.Session)
  Ffi(MysqlFfi.Handle)
end

# The driver that the variable names, else the native one when it runs here, else the FFI one.
def connect(target: MysqlUrl.Target) -> Result[Link]
  choice = System.env(DRIVER_VARIABLE).unwrap_or("")
  if choice == "ffi" or (choice == "" and not MysqlNative.available?())
    handle = try MysqlFfi.open(target)
    return ok(Link.Ffi(handle))
  end

  if choice != "" and choice != "native"
    return error("mysql error: #{DRIVER_VARIABLE} is #{choice}, expected native or ffi")
  end

  return error(MysqlNative.UNAVAILABLE) if not MysqlNative.available?()

  session = try MysqlNative.open(target)
  ok(Link.Native(session))
end

def identity_of(link: Link) -> Identity
  case read_identity(link)
    ok(found) -> found
    error(_) -> UNKNOWN
  end
end

def read_identity(link: Link) -> Result[Identity]
  rows = try run_once(link, IDENTITY_SQL)
  status = try run_once(link, UPTIME_SQL)
  return error("no identity") if rows.size != 1 or status.size != 1

  row = rows[0]
  id = try text_of(row["id"]).to_i
  now = try text_of(row["now"]).to_i
  uptime = try text_of(status[0]["Value"]).to_i
  server = "#{text_of(row["server_id"])}@#{text_of(row["host"])}:#{text_of(row["port"])}"
  ok(Identity(id: id, server: server, started: now - uptime))
end

def text_of(value: Value) -> String
  case value
    Value.Int(n) -> n.to_s
    Value.Text(text) -> text
    _ -> ""
  end
end

def kill_query(killer: Link, target: Identity) -> Void
  seen = identity_of(killer)
  return if seen.server != target.server or (seen.started - target.started).abs > START_SLACK_S

  _ = run_execute(killer, "KILL QUERY #{target.id}", [])
end

def killer_timeout(seconds: Int) -> Int
  return KILLER_CONNECT_S if seconds == 0 or seconds > KILLER_CONNECT_S

  seconds
end

def close_link(link: Link) -> Void
  case link
    Link.Native(session) -> Native.close(session.conn)
    Link.Ffi(handle) -> Native.close(handle)
  end
end

def server_version(link: Link) -> String
  case link
    Link.Native(session) -> MysqlNative.server_version(session)
    Link.Ffi(handle) -> MysqlFfi.server_info(handle)
  end
end

# MariaDB says so in its version, `11.4.2-MariaDB` (and `5.5.5-11.4.2-MariaDB` for an old client protocol).
def flavor_of(version: String) -> Flavor
  return Flavor.MariaDb if version.include?("MariaDB")

  Flavor.MySql
end

def closed?(link: Link) -> Bool
  case link
    Link.Native(session) -> MysqlNative.closed?(session)
    Link.Ffi(handle) -> Native.closed?(handle)
  end
end

# A call with a closed resource stops the program, so a closed connection is turned into an error first.
def run_query(link: Link, sql: String, params: List[Value]) -> Result[List[Row]]
  return error(CLOSED) if closed?(link)

  case link
    Link.Native(session) -> MysqlNative.query(session, sql, params)
    Link.Ffi(handle) -> MysqlFfi.query(handle, sql, params)
  end
end

# A statement of the adapter itself, which the statement cache of the native driver neither keeps nor counts.
def run_once(link: Link, sql: String) -> Result[List[Row]]
  return error(CLOSED) if closed?(link)

  case link
    Link.Native(session) -> MysqlNative.query_once(session, sql)
    Link.Ffi(handle) -> MysqlFfi.query(handle, sql, [])
  end
end

def run_execute(link: Link, sql: String, params: List[Value]) -> Result[Int]
  return error(CLOSED) if closed?(link)

  case link
    Link.Native(session) -> MysqlNative.execute(session, sql, params)
    Link.Ffi(handle) -> MysqlFfi.execute(handle, sql, params)
  end
end

# Runs `body` under the limit of the call. A limit other than the connection's is set before and put back after, also
# when the body failed. The put-back is not part of the result: the body's own result is what the caller asked for, and
# the put-back runs under the short limit of the call, so it can fail like any statement (a lost connection, which the
# next call reports, or a timeout of its own), and the connection then keeps the limit of the call until the next one.
def limited[R](conn: Connection, timeout_ms: Int, body: Fn[Result[R]]) -> Result[R]
  return body.call() if timeout_ms < 0 or timeout_ms == conn.timeout_ms

  try set_limit(conn, limit_sql(conn.flavor, timeout_ms))
  done = body.call()
  put_back_limit(conn)
  done
end

def limit_session(conn: Connection) -> Result[Void]
  return ok() if conn.timeout_ms == 0

  set_limit(conn, limit_sql(conn.flavor, conn.timeout_ms))
end

def set_limit(conn: Connection, sql: String) -> Result[Void]
  try run_execute(conn.link, sql, [])
  ok()
end

# The limit of the url, or, when the url sets none, the default of the server (its global value).
def put_back_limit(conn: Connection) -> Void
  if conn.timeout_ms > 0
    _ = set_limit(conn, limit_sql(conn.flavor, conn.timeout_ms))
  else
    _ = set_limit(conn, default_limit_sql(conn.flavor))
  end
end

# MySQL counts the limit in milliseconds and MariaDB in seconds, which may have a fraction: 2500 ms is 2.500.
def limit_sql(flavor: Flavor, ms: Int) -> String
  case flavor
    Flavor.MySql -> "SET SESSION max_execution_time = #{ms}"
    Flavor.MariaDb ->
      millis = (ms % MS_PER_SECOND).to_s
      padded = List.repeat("0", 3 - millis.length).join("") + millis
      "SET SESSION max_statement_time = #{ms / MS_PER_SECOND}.#{padded}"
  end
end

def default_limit_sql(flavor: Flavor) -> String
  case flavor
    Flavor.MySql -> "SET SESSION max_execution_time = DEFAULT"
    Flavor.MariaDb -> "SET SESSION max_statement_time = DEFAULT"
  end
end
