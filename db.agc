## One API over the databases of this package. A connection comes from `open`; `query`, `execute` and
## `transaction` take bound `Value` parameters (`?` placeholders), never values spliced into the sql.
##
## An error is `error(message)`, and the message starts with the adapter and its code, as in
## `sqlite error 1: near "from": syntax error`.

import Sqlite from "sqlite"
import {Row, Value} from "value"

SQLITE_PREFIX = "sqlite:"

## An open connection. Its task owns it: close it with `close`, or the end of the task closes it.
export enum Connection
  Sqlite(Sqlite.Handle)
end

## Opens the database a url names: `sqlite:PATH` (`sqlite::memory:` for a private in-memory database).
export def open(url: String) -> Result[Connection]
  if url.start_with?(SQLITE_PREFIX)
    return open_sqlite(url.slice(SQLITE_PREFIX.length, url.length - SQLITE_PREFIX.length))
  end
  return error("unsupported database url #{url}: expected sqlite:PATH")
end

## Opens a SQLite database file, or `:memory:`.
export def open_sqlite(path: String) -> Result[Connection]
  handle = try Sqlite.open(path)
  return ok(Connection.Sqlite(handle))
end

## Closes the connection; closing it again does nothing.
export def close(conn: Connection) -> Void
  case conn
    Connection.Sqlite(handle) -> Sqlite.close(handle)
  end
end

## Runs a statement and gives its rows, in column order; a statement without a result gives none.
export def query(conn: Connection, sql: String, params: List[Value]) -> Result[List[Row]]
  case conn
    Connection.Sqlite(handle) -> return Sqlite.query(handle, sql, params)
  end
end

## Runs a statement and gives the number of rows it inserted, updated or deleted.
export def execute(conn: Connection, sql: String, params: List[Value]) -> Result[Int]
  case conn
    Connection.Sqlite(handle) -> return Sqlite.execute(handle, sql, params)
  end
end

## Runs the block between BEGIN and COMMIT. An `error` from the block, or a failed COMMIT, rolls back and gives
## that error. Transactions do not nest.
export def transaction(conn: Connection, body: Fn[Connection, Result[Void]]) -> Result[Void]
  try execute(conn, "BEGIN", [])
  done = body.call(conn)
  case done
    Result.Ok(_) -> return commit(conn)
    Result.Err(message) -> return abandon(conn, message)
  end
end

def commit(conn: Connection) -> Result[Void]
  committed = execute(conn, "COMMIT", [])
  case committed
    Result.Ok(_) -> return ok()
    Result.Err(message) -> return abandon(conn, message)
  end
end

# The original error wins over a failed ROLLBACK, which only says the transaction is already gone.
def abandon(conn: Connection, message: String) -> Result[Void]
  _ = execute(conn, "ROLLBACK", [])
  return error(message)
end
