## What differs between the databases for the Orm: how an identifier is quoted.

import Db from "../db"

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
## double-quoted name that is no column as a string, so a missing column would pass unseen). The name must pass
## `valid_name?`, so it holds nothing to escape. A quoted name is exact: PostgreSQL folds an unquoted name to lower
## case, so a column it created that way is found by its lower case name only.
export def quote(conn: Db.Connection, name: String) -> String
  case conn
    Db.Connection.Postgres(_) -> return "\"#{name}\""
    _ -> return "`#{name}`"
  end
end

def digit?(byte: Int) -> Bool
  return byte >= 48 and byte <= 57
end

def word_byte?(byte: Int) -> Bool
  letter = (byte >= 97 and byte <= 122) or (byte >= 65 and byte <= 90)
  return letter or digit?(byte) or byte == 95
end
