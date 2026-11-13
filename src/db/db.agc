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
## One import is enough: `Db.Value` and `Db.Row` are the types of `support/value.agc`.

import Mysql from "mysql/mysql"
import Postgres from "postgres/postgres"
import Sqlite from "sqlite/sqlite"
import V from "support/value"

export V.Row
export V.Value

## The `timeout_ms` of a call that takes the one of the connection.
CONNECTION_DEFAULT = -1
## The `timeout_ms` of a call that has no limit of its own. On MySQL and MariaDB a connection opened with a url
## `timeout_ms` still cuts it at the client backstop (see `mysql/mysql.agc`). On every database it lifts the limit of
## the url, but not one that the server sets for the session when the url has none.
NO_TIMEOUT = 0

## An open connection, owned by the task that opened it. Close it with `close`, or the end of the task closes it (the
## end of `main` closes one still open). Open it in the task that keeps it (usually `main`), or hand it over with
## `Task.spawn_owning(&f, conn)`.
enum Connection
  Sqlite(Sqlite.Connection)
  Postgres(Postgres.Connection)
  Mysql(Mysql.Connection)
end

## Opens the database a url names: `sqlite:PATH` (`sqlite::memory:` for a private in-memory database; the SQLite
## parameters follow a `?`, as in `sqlite:app.db?journal_mode=delete`), or
## `postgres://` and `postgresql://` urls, which libpq parses, or `mysql://` and `mariadb://` urls.
def open(url: String) -> Result[Connection]
  # Errors name the scheme only: a url can hold a password.
  if url.start_with?("sqlite://")
    return error("db error: unsupported database url with scheme sqlite://: write sqlite:PATH, without //")
  end

  if url.start_with?(SQLITE_PREFIX)
    path = url.slice(SQLITE_PREFIX.length, url.length - SQLITE_PREFIX.length)
    return error("db error: unsupported database url with scheme sqlite: the path is empty") if path.empty?

    return open_sqlite(path)
  end

  return open_postgres(url) if POSTGRES_PREFIXES.any? do |prefix| url.start_with?(prefix) end

  return open_mysql(url) if MYSQL_PREFIXES.any? do |prefix| url.start_with?(prefix) end

  error(
    "db error: unsupported database url scheme #{scheme(url)}: expected sqlite:PATH, sqlite::memory:, " +
    "postgres:// or mysql://",
  )
end

## Opens a SQLite database file, or `:memory:`. Parameters after a `?` set `journal_mode` (default `wal`),
## `foreign_keys` (default `on`), `busy_timeout` in milliseconds (default 5000), `timeout_ms` (default none),
## `synchronous`, `mmap_size`, `cache_size`, `journal_size_limit` and `fts5=required` (see `sqlite/sqlite.agc`).
def open_sqlite(path: String) -> Result[Connection]
  handle = try Sqlite.open(path)
  ok(Connection.Sqlite(handle))
end

## Opens a PostgreSQL database from a libpq url, or from a conninfo string (`host=localhost dbname=app`), which libpq
## also takes. `timeout_ms` is a parameter of the url, or a key of the conninfo, that this package reads and libpq
## never sees: it sets the `statement_timeout` of the session.
def open_postgres(url: String) -> Result[Connection]
  handle = try Postgres.open(url)
  ok(Connection.Postgres(handle))
end

## Opens a MySQL or MariaDB database from a `mysql://user:password@host:3306/database` url (also `mariadb://`).
## `timeout_ms` is a parameter of the url (see `mysql/mysql.agc`).
def open_mysql(url: String) -> Result[Connection]
  handle = try Mysql.open(url)
  ok(Connection.Mysql(handle))
end

## Closes the connection; closing it again does nothing.
def close(conn: Connection) -> Void
  case conn
    Connection.Sqlite(handle) -> Sqlite.close(handle)
    Connection.Postgres(handle) -> Postgres.close(handle)
    Connection.Mysql(handle) -> Mysql.close(handle)
  end
end

## Runs a statement and gives its rows, in column order; a statement without a result gives none. `timeout_ms` is the
## limit of this call: `CONNECTION_DEFAULT` (-1) takes the one of the connection, `NO_TIMEOUT` (0) has none (read the
## notes at `NO_TIMEOUT` and in the page of the database: MySQL limits only a SELECT, and a MariaDB or MySQL connection
## with a url `timeout_ms` cuts a longer call at the client backstop).
def query(
  conn: Connection,
  sql: String,
  params: List[V.Value],
  timeout_ms: Int = CONNECTION_DEFAULT,
) -> Result[List[V.Row]]
  case conn
    Connection.Sqlite(handle) -> Sqlite.query(handle, sql, params, timeout_ms)
    Connection.Postgres(handle) -> Postgres.query(handle, sql, params, timeout_ms)
    Connection.Mysql(handle) -> Mysql.query(handle, sql, params, timeout_ms)
  end
end

## Runs a statement and gives the number of rows it inserted, updated or deleted. `timeout_ms` is as in `query`.
def execute(conn: Connection, sql: String, params: List[V.Value], timeout_ms: Int = CONNECTION_DEFAULT) -> Result[Int]
  case conn
    Connection.Sqlite(handle) -> Sqlite.execute(handle, sql, params, timeout_ms)
    Connection.Postgres(handle) -> Postgres.execute(handle, sql, params, timeout_ms)
    Connection.Mysql(handle) -> Mysql.execute(handle, sql, params, timeout_ms)
  end
end

## Whether a transaction is open on the connection (also one that failed and waits for its ROLLBACK). The adapter
## reads it from the state of the connection, without a round trip. A closed connection is not in one.
def in_transaction?(conn: Connection) -> Bool
  case conn
    Connection.Sqlite(handle) -> Sqlite.in_transaction?(handle)
    Connection.Postgres(handle) -> Postgres.in_transaction?(handle)
    Connection.Mysql(handle) -> Mysql.in_transaction?(handle)
  end
end

## Whether the connection is open and not known to be lost, from what the client library keeps and with no round trip.
## A closed connection is not connected; a connection the server ended shows here once a call has failed on it
## (`healthy?` asks the server). A pool checks it after a block, since a block can close or lose its connection.
def connected?(conn: Connection) -> Bool
  case conn
    Connection.Sqlite(handle) -> Sqlite.connected?(handle)
    Connection.Postgres(handle) -> Postgres.connected?(handle)
    Connection.Mysql(handle) -> Mysql.connected?(handle)
  end
end

## Whether the connection works: it is open and the server answers (SQLite and MySQL: a query or a ping; PostgreSQL:
## `SELECT 1` under the session's `statement_timeout`). It does not mean that a statement can run: a PostgreSQL
## connection in a failed transaction is healthy but refuses statements until the ROLLBACK, so a pool rolls back (see
## `in_transaction?`) before it reuses a connection. A closed or lost connection is not healthy.
def healthy?(conn: Connection) -> Bool
  case conn
    Connection.Sqlite(handle) -> Sqlite.healthy?(handle)
    Connection.Postgres(handle) -> Postgres.healthy?(handle)
    Connection.Mysql(handle) -> Mysql.healthy?(handle)
  end
end

## Whether the failure message is the one of a statement that ran over its `timeout_ms`.
def timeout?(message: String) -> Bool = TIMEOUT_PREFIXES.any? do |prefix| message.start_with?(prefix) end

## Runs the block between the adapter's BEGIN and COMMIT and gives the value of the block's `ok`. An `error` from the
## block, or a failed COMMIT, rolls back and gives that error (with the ROLLBACK failure appended, if it failed too).
## Transactions do not nest. A runtime error in the block stops the task and leaves the transaction open; closing the
## connection rolls it back (for MySQL only `close` or the end of the process does).
def transaction[R](conn: Connection, body: Fn[Connection, Result[R]]) -> Result[R]
  # A nested call is refused by the BEGIN; it must not wait in line behind its own transaction.
  return run_transaction(conn, conn, body) if in_transaction?(conn)

  opener = enter_gate(conn)
  done = run_transaction(opener, conn, body)
  leave_gate(conn)
  done
end

private

SQLITE_PREFIX = "sqlite:"
POSTGRES_PREFIXES = ["postgres://", "postgresql://"]
MYSQL_PREFIXES = ["mysql://", "mariadb://"]
MAX_SCHEME = 16
# The failures of a statement that ran over its `timeout_ms`: SQLite interrupted it, the SQLSTATE query_canceled of
# PostgreSQL, and the errors of MySQL (max_execution_time) and MariaDB (max_statement_time).
TIMEOUT_PREFIXES = ["sqlite error 9:", "postgres error 57014:", "mysql error 3024:", "mysql error 1969:"]

# A SQLite connection of a pool waits for its turn among the writers of the pool (see db_pool.agc); the connection for
# its BEGIN.
def enter_gate(conn: Connection) -> Connection
  case conn
    Connection.Sqlite(handle) -> Connection.Sqlite(Sqlite.enter_gate(handle))
    _ -> conn
  end
end

def leave_gate(conn: Connection) -> Void
  case conn
    Connection.Sqlite(handle) -> Sqlite.leave_gate(handle)
    _ -> return
  end
end

# BEGIN runs on `opener`, the connection itself or a copy that does not wait for SQLite's lock (see enter_gate).
def run_transaction[R](opener: Connection, conn: Connection, body: Fn[Connection, Result[R]]) -> Result[R]
  try execute(opener, begin_sql(conn), [])
  done = body.call(conn)
  case done
    ok(value) -> commit(conn, value)
    error(e) -> abandon(conn, e)
  end
end

def commit[R](conn: Connection, value: R) -> Result[R]
  committed = execute(conn, "COMMIT", [])
  case committed
    ok(_) -> ok(value)
    error(e) -> abandon(conn, e)
  end
end

def begin_sql(conn: Connection) -> String
  case conn
    Connection.Sqlite(_) -> Sqlite.BEGIN_SQL
    Connection.Postgres(_) -> Postgres.BEGIN_SQL
    Connection.Mysql(_) -> Mysql.BEGIN_SQL
  end
end

# The original error wins; a failed ROLLBACK is appended, since the transaction may still be open. A connection that is
# no longer in a transaction is left alone: the engine ended it already (SQLite rolls back a write it interrupted), and
# a ROLLBACK would fail with a message that hides the real error.
def abandon[R](conn: Connection, failure: Error) -> Result[R]
  return error(failure) if not in_transaction?(conn)

  rolled = execute(conn, "ROLLBACK", [])
  case rolled
    ok(_) -> error(failure)
    error(rollback) -> error(failure.with(message: "#{failure.message}; rollback failed: #{rollback.message}"))
  end
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
