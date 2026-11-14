## One API over the databases of this package. A connection comes from `open`; `query`, `execute` and
## `transaction` take bound `Value` parameters (`?` placeholders), never values spliced into the sql.
##
## An error is `error(message)` in one of two shapes. An engine failure is `<adapter> error <code>: <message>`, as in
## `sqlite error 1: near "from": syntax error`; the code of PostgreSQL is its SQLSTATE, as in
## `postgres error 42601: syntax error at end of input`. A bad input, refused before the statement runs, is
## `<adapter> error: <message>`, as in `sqlite error: the sql has 1 parameter, got 0`. A failure of this module
## itself, such as an unknown url, is `db error: <message>`.
##
## `timeout_ms` bounds the time of a statement: a url parameter (`sqlite:app.db?timeout_ms=2000`, none by default) and
## an argument of `query` and `execute`. A statement that runs longer fails, and `timeout?` knows its message. The
## connection works after it.
##
## `Db.Value` and `Db.Row` are the types of `support/value.agc`, and `Db.Connection` and `Db.Driver` the ones of
## `support/connection.agc`. A driver comes from the module of its database (`sqlite.agc`, `postgres.agc`,
## `mysql.agc`): import only the ones the app uses, since each one that a program imports builds its native module.
##
##     import Db from "pkg/db/db"
##     import Sqlite from "pkg/db/sqlite"
##
##     conn = Db.open("sqlite:app.db", [Sqlite.driver()]).unwrap!

import C from "support/connection"
import V from "support/value"

export C.Adapter
export C.CacheStats
export C.Connection
export C.Driver
export C.Pooling
export C.PoolSettings
export V.Row
export V.Value

## The `timeout_ms` of a call that takes the one of the connection.
CONNECTION_DEFAULT = -1
## The `timeout_ms` of a call that has no limit of its own. On MySQL and MariaDB a connection opened with a url
## `timeout_ms` still cuts it at the client backstop (see `mysql/mysql.agc`). On every database it lifts the limit of
## the url, but not one that the server sets for the session when the url has none.
NO_TIMEOUT = 0

## Opens the database a url names with the driver of `drivers` that takes its scheme: `sqlite:PATH`
## (`sqlite::memory:` for a private in-memory database; the SQLite parameters follow a `?`, as in
## `sqlite:app.db?journal_mode=delete`) with `Sqlite.driver()`, `postgres://` and `postgresql://` urls with
## `Postgres.driver()` (a libpq conninfo string has no scheme: open it with `Postgres.open`), `mysql://` and
## `mariadb://` urls with `Mysql.driver()`. The connection is owned by the task that opened it: close it with `close`,
## or the end of the task closes it (the end of `main` closes one still open). Open it in the task that keeps it,
## usually `main`; a pool (`DbPool`) shares connections between tasks.
def open(url: String, drivers: List[C.Driver]) -> Result[C.Connection]
  driver = try driver_for(url, drivers)
  driver.open.call(url)
end

## The driver of `drivers` that takes the url, by the url's scheme.
def driver_for(url: String, drivers: List[C.Driver]) -> Result[C.Driver]
  found = drivers.find do |driver| driver.schemes.any? do |prefix| url.start_with?(prefix) end end
  case found
    ok(driver) -> ok(driver)
    # Errors name the scheme only: a url can hold a password.
    error(_) -> error(no_driver(url, drivers))
  end
end

## Closes the connection; closing it again does nothing.
def close(conn: C.Connection) -> Void
  conn.close.call()
end

## Runs a statement and gives its rows, in column order; a statement without a result gives none. `timeout_ms` is the
## limit of this call: `CONNECTION_DEFAULT` (-1) takes the one of the connection, `NO_TIMEOUT` (0) has none (read the
## notes at `NO_TIMEOUT` and in the page of the database: MySQL limits only a SELECT, and a MariaDB or MySQL connection
## with a url `timeout_ms` cuts a longer call at the client backstop).
def query(
  conn: C.Connection,
  sql: String,
  params: List[V.Value],
  timeout_ms: Int = CONNECTION_DEFAULT,
) -> Result[List[V.Row]]
  conn.query.call(sql, params, timeout_ms)
end

## Runs a statement and gives the number of rows it inserted, updated or deleted. `timeout_ms` is as in `query`.
def execute(
  conn: C.Connection,
  sql: String,
  params: List[V.Value],
  timeout_ms: Int = CONNECTION_DEFAULT,
) -> Result[Int]
  conn.execute.call(sql, params, timeout_ms)
end

## Whether a transaction is open on the connection (also one that failed and waits for its ROLLBACK). The adapter
## reads it from the state of the connection, without a round trip. A closed connection is not in one.
def in_transaction?(conn: C.Connection) -> Bool = conn.in_transaction.call()

## Whether the connection is open and not known to be lost, from what the client library keeps and with no round trip.
## A closed connection is not connected; a connection the server ended shows here once a call has failed on it
## (`healthy?` asks the server). A pool checks it after a block, since a block can close or lose its connection.
def connected?(conn: C.Connection) -> Bool = conn.connected.call()

## Whether the connection works: it is open and the server answers (SQLite and MySQL: a query or a ping; PostgreSQL:
## `SELECT 1` under the session's `statement_timeout`). It does not mean that a statement can run: a PostgreSQL
## connection in a failed transaction is healthy but refuses statements until the ROLLBACK, so a pool rolls back (see
## `in_transaction?`) before it reuses a connection. A closed or lost connection is not healthy.
def healthy?(conn: C.Connection) -> Bool = conn.healthy.call()

## Whether the failure message is the one of a statement that ran over its `timeout_ms`.
def timeout?(message: String) -> Bool = TIMEOUT_PREFIXES.any? do |prefix| message.start_with?(prefix) end

## Runs the block between the adapter's BEGIN and COMMIT and gives the value of the block's `ok`. An `error` from the
## block, or a failed COMMIT, rolls back and gives that error (with the ROLLBACK failure appended, if it failed too).
## Transactions do not nest. A runtime error in the block stops the task and leaves the transaction open; closing the
## connection rolls it back (for MySQL only `close` or the end of the process does).
def transaction[R](conn: C.Connection, body: Fn[C.Connection, Result[R]]) -> Result[R]
  # A nested call is refused by the BEGIN; it must not wait in line behind its own transaction.
  return run_transaction(conn, conn, body) if in_transaction?(conn)

  # A SQLite connection of a pool waits for its turn among the writers of the pool (see db_pool.agc); `opener` is
  # the connection for its BEGIN.
  opener = conn.enter_gate.call()
  done = run_transaction(opener, conn, body)
  conn.leave_gate.call()
  done
end

## The counters of the statement cache of the connection's native driver; none on a driver without one (the FFI
## drivers, MySQL).
def statement_cache(conn: C.Connection) -> Optional[C.CacheStats] = conn.statement_cache.call()

private

MAX_SCHEME = 16

# The drivers of this package by their schemes, for the failure of a url whose driver the app did not pass.
KNOWN_DRIVERS = {
  "Sqlite.driver()": ["sqlite:"],
  "Postgres.driver()": ["postgres://", "postgresql://"],
  "Mysql.driver()": ["mysql://", "mariadb://"],
}
# The failures of a statement that ran over its `timeout_ms`: SQLite interrupted it, the SQLSTATE query_canceled of
# PostgreSQL, and the errors of MySQL (max_execution_time) and MariaDB (max_statement_time).
TIMEOUT_PREFIXES = ["sqlite error 9:", "postgres error 57014:", "mysql error 3024:", "mysql error 1969:"]

# BEGIN runs on `opener`, the connection itself or a copy that does not wait for SQLite's lock (see enter_gate).
def run_transaction[R](opener: C.Connection, conn: C.Connection, body: Fn[C.Connection, Result[R]]) -> Result[R]
  try execute(opener, conn.begin_sql, [])
  done = body.call(conn)
  case done
    ok(value) -> commit(conn, value)
    error(e) -> abandon(conn, e)
  end
end

def commit[R](conn: C.Connection, value: R) -> Result[R]
  committed = execute(conn, "COMMIT", [])
  case committed
    ok(_) -> ok(value)
    error(e) -> abandon(conn, e)
  end
end

# The original error wins; a failed ROLLBACK is appended, since the transaction may still be open. A connection that is
# no longer in a transaction is left alone: the engine ended it already (SQLite rolls back a write it interrupted), and
# a ROLLBACK would fail with a message that hides the real error.
def abandon[R](conn: C.Connection, failure: Error) -> Result[R]
  return error(failure) if not in_transaction?(conn)

  rolled = execute(conn, "ROLLBACK", [])
  case rolled
    ok(_) -> error(failure)
    error(rollback) -> error(failure.with(message: "#{failure.message}; rollback failed: #{rollback.message}"))
  end
end

# The failure of a url that no driver of `drivers` takes. A scheme of a driver of this package that the app did not
# pass names that driver.
def no_driver(url: String, drivers: List[C.Driver]) -> String
  for name in KNOWN_DRIVERS.keys
    if KNOWN_DRIVERS[name].any? do |prefix| url.start_with?(prefix) end
      return "db error: no driver for the url scheme #{scheme(url)}: pass #{name} to Db.open or DbPool.Options"
    end
  end

  schemes = drivers.flat_map do |driver| driver.schemes end
  return "db error: unsupported database url scheme #{scheme(url)}: no driver was given" if schemes.empty?

  "db error: unsupported database url scheme #{scheme(url)}: expected #{schemes.join(", ")}"
end

# The text before the first colon when it looks like a url scheme, else a fixed word: any other text (a conninfo
# string such as `password=a:b`) could hold a secret.
def scheme(url: String) -> String
  found = url.index_of(":")
  case found
    some(at) ->
      name = url.slice(0, at)
      return name if at > 0 and at <= MAX_SCHEME and name.bytes.to_a.all? do |byte| scheme_byte?(byte) end

      "(none)"
    none -> "(none)"
  end
end

# A letter, a digit, `+`, `-` or `.`.
def scheme_byte?(byte: Int) -> Bool
  letter = (byte >= 97 and byte <= 122) or (byte >= 65 and byte <= 90)
  letter or (byte >= 48 and byte <= 57) or byte == 43 or byte == 45 or byte == 46
end
