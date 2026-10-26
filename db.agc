## One API over the databases of this package. A connection comes from `open`; `query`, `execute` and
## `transaction` take bound `Value` parameters (`?` placeholders), never values spliced into the sql.
##
## An error is `error(message)` in one of two shapes. An engine failure is `<adapter> error <code>: <message>`, as in
## `sqlite error 1: near "from": syntax error`; the code of PostgreSQL is its SQLSTATE, as in
## `postgres error 42601: syntax error at end of input`. A bad input, refused before the statement runs, is
## `<adapter> error: <message>`, as in `sqlite error: the sql has 1 parameter, got 0`. A failure of this module
## itself, such as an unknown url, is `db error: <message>`.

import Postgres from "postgres"
import Sqlite from "sqlite"
import {Row, Value} from "value"

SQLITE_PREFIX = "sqlite:"
POSTGRES_PREFIXES = ["postgres://", "postgresql://"]
MAX_SCHEME = 16

## An open connection, owned by the task that opened it. Close it with `close`. The end of the task closes a SQLite
## connection, but not a PostgreSQL one (it only frees the handle; the server session and its socket stay open): the
## caller must call `close`.
export enum Connection
  Sqlite(Sqlite.Handle)
  Postgres(Postgres.Handle)
end

## Opens the database a url names: `sqlite:PATH` (`sqlite::memory:` for a private in-memory database), or
## `postgres://` and `postgresql://` urls, which libpq parses.
export def open(url: String) -> Result[Connection]
  # Errors name the scheme only: a url can hold a password.
  if url.start_with?("sqlite://")
    return error("db error: unsupported database url with scheme sqlite://: write sqlite:PATH, without //")
  end

  if url.start_with?(SQLITE_PREFIX)
    path = url.slice(SQLITE_PREFIX.length, url.length - SQLITE_PREFIX.length)
    if path.empty?
      return error("db error: unsupported database url with scheme sqlite: the path is empty")
    end

    return open_sqlite(path)
  end

  if POSTGRES_PREFIXES.any? do |prefix| url.start_with?(prefix) end
    return open_postgres(url)
  end

  return error("db error: unsupported database url scheme #{scheme(url)}: expected sqlite:PATH, sqlite::memory: " +
               "or postgres://")
end

## Opens a SQLite database file, or `:memory:`.
export def open_sqlite(path: String) -> Result[Connection]
  handle = try Sqlite.open(path)
  return ok(Connection.Sqlite(handle))
end

## Opens a PostgreSQL database from a libpq url, or from a conninfo string (`host=localhost dbname=app`), which libpq
## also takes.
export def open_postgres(url: String) -> Result[Connection]
  handle = try Postgres.open(url)
  return ok(Connection.Postgres(handle))
end

## Closes the connection; closing it again does nothing.
export def close(conn: Connection) -> Void
  case conn
    Connection.Sqlite(handle) -> Sqlite.close(handle)
    Connection.Postgres(handle) -> Postgres.close(handle)
  end
end

## Runs a statement and gives its rows, in column order; a statement without a result gives none.
export def query(conn: Connection, sql: String, params: List[Value]) -> Result[List[Row]]
  case conn
    Connection.Sqlite(handle) -> return Sqlite.query(handle, sql, params)
    Connection.Postgres(handle) -> return Postgres.query(handle, sql, params)
  end
end

## Runs a statement and gives the number of rows it inserted, updated or deleted.
export def execute(conn: Connection, sql: String, params: List[Value]) -> Result[Int]
  case conn
    Connection.Sqlite(handle) -> return Sqlite.execute(handle, sql, params)
    Connection.Postgres(handle) -> return Postgres.execute(handle, sql, params)
  end
end

## Runs the block between the adapter's BEGIN and COMMIT. An `error` from the block, or a failed COMMIT, rolls back
## and gives that error (with the ROLLBACK failure appended, if it failed too). Transactions do not nest. A runtime
## error in the block stops the task and leaves the transaction open; closing the connection rolls it back (for
## PostgreSQL only `close` or the end of the process does).
export def transaction(conn: Connection, body: Fn[Connection, Result[Void]]) -> Result[Void]
  try execute(conn, begin_sql(conn), [])
  done = body.call(conn)
  case done
    ok(_) -> return commit(conn)
    error(message) -> return abandon(conn, message)
  end
end

def commit(conn: Connection) -> Result[Void]
  committed = execute(conn, "COMMIT", [])
  case committed
    ok(_) -> return ok()
    error(message) -> return abandon(conn, message)
  end
end

def begin_sql(conn: Connection) -> String
  case conn
    Connection.Sqlite(_) -> return Sqlite.BEGIN_SQL
    Connection.Postgres(_) -> return Postgres.BEGIN_SQL
  end
end

# The original error wins; a failed ROLLBACK is appended, since the transaction may still be open.
def abandon(conn: Connection, message: String) -> Result[Void]
  rolled = execute(conn, "ROLLBACK", [])
  case rolled
    ok(_) -> return error(message)
    error(rollback_message) -> return error("#{message}; rollback failed: #{rollback_message}")
  end
end

# The text before the first colon when it looks like a url scheme, else a fixed word: any other text (a conninfo
# string such as `password=a:b`) could hold a secret.
def scheme(url: String) -> String
  found = url.index_of(":")
  case found
    ok(at) ->
      name = url.slice(0, at)
      if at > 0 and at <= MAX_SCHEME and name.to_bytes.all? do |byte| scheme_byte?(byte) end
        return name
      end

      return "(none)"
    error(_) -> return "(none)"
  end
end

# A letter, a digit, `+`, `-` or `.`.
def scheme_byte?(byte: Int) -> Bool
  letter = (byte >= 97 and byte <= 122) or (byte >= 65 and byte <= 90)
  return letter or (byte >= 48 and byte <= 57) or byte == 43 or byte == 45 or byte == 46
end
