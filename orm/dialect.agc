## What differs between the databases for the Orm: how an identifier is quoted.

import Db from "../db"

## The error of `insert_generated` when the database gave no key; the Orm adds the table to it.
export NO_KEY = "the database gave no generated key"

## Whether `name` is safe to use as a table or column name: a letter or `_`, then letters, digits or `_`. The Orm
## puts only such names in the sql it writes, so a name from a request cannot inject sql.
export def valid_name?(name: String) -> Bool
  bytes = name.to_bytes
  if bytes.empty? or digit?(bytes[0])
    return false
  end

  return bytes.all? do |byte| word_byte?(byte) end
end

## The name in the quotes of the database: double quotes for PostgreSQL, backticks for MySQL and SQLite (SQLite reads a
## double-quoted name that is no column as a string, so a missing column would pass unseen). A name that fails
## `valid_name?` is an error, so no sql is built from a name that could inject. A quoted name keeps its case:
## PostgreSQL folds an unquoted name to lower case, so a column it created that way is found by its lower case name
## only. SQLite and MySQL find a column in any case but give its name in the case of the table, and the Orm matches
## the fields with the names of the result exactly.
export def quote(conn: Db.Connection, name: String) -> Result[String]
  if not valid_name?(name)
    return error("the name #{name.inspect} is not a plain identifier")
  end

  case conn
    Db.Connection.Postgres(_) -> return ok("\"#{name}\"")
    _ -> return ok("`#{name}`")
  end
end

## Runs an insert whose key the database generates and gives that key. PostgreSQL says it with `returning`; SQLite and
## MySQL keep the key of the last insert of the connection, which the next statement reads. `key` is the quoted
## name of the key column. The errors are the ones of `Db`.
export def insert_generated(conn: Db.Connection, sql: String, params: List[Db.Value], key: String) -> Result[Int]
  case conn
    Db.Connection.Postgres(_) -> return generated(try Db.query(conn, "#{sql} returning #{key}", params))
    Db.Connection.Sqlite(_) ->
      try Db.execute(conn, sql, params)
      return generated(try Db.query(conn, "select last_insert_rowid() as id", []))
    Db.Connection.Mysql(_) ->
      try Db.execute(conn, sql, params)
      return generated(try Db.query(conn, "select last_insert_id() as id", []))
  end
end

def generated(rows: List[Db.Row]) -> Result[Int]
  if rows.empty? or rows[0].empty?
    return error(NO_KEY)
  end

  case rows[0].values[0]
    Db.Value.Int(id) -> return ok(id)
    _ -> return error(NO_KEY)
  end
end

def digit?(byte: Int) -> Bool
  return byte >= 48 and byte <= 57
end

def word_byte?(byte: Int) -> Bool
  letter = (byte >= 97 and byte <= 122) or (byte >= 65 and byte <= 90)
  return letter or digit?(byte) or byte == 95
end
