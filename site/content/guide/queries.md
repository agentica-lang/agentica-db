---
title: Queries
weight: 2
description: Run sql with query and execute, and pass values as bound parameters.
---

Two functions run sql. Both take the connection, the sql and a list of parameters.

| Function | Gives |
|---|---|
| `Db.query(conn, sql, params)` | `Result[List[Db.Row]]`, the rows of the statement; a statement without a result gives none |
| `Db.execute(conn, sql, params)` | `Result[Int]`, the rows inserted, updated or deleted |

A `Db.Row` is a `Map[String, Db.Value]`, in column order. Read a column with `row["name"]` and look at the `Db.Value` with `case`.

```agentica
import Db from "pkg/db/db"

def run() -> Result[Void]
  conn = try Db.open("sqlite::memory:")
  try Db.execute(conn, "create table users (name text not null, age integer)", [])
  changed = try Db.execute(conn, "insert into users (name, age) values (?, ?), (?, ?)",
                           [Db.Value.Text("Ana"), Db.Value.Int(31), Db.Value.Text("Bob"), Db.Value.Null])
  puts(changed)
  rows = try Db.query(conn, "select name, age from users order by name", [])
  for row in rows
    case row["name"]
      Db.Value.Text(name) -> puts(name)
      _ -> puts("no name")
    end
  end

  Db.close(conn)
  return ok()
end

def main() -> Void
  case run()
    ok(_) -> puts("done")
    error(message) -> IO.warn(message)
  end
end
```

```output
2
Ana
Bob
done
```

## Parameters

A placeholder is `?`, and only `?`, on every database. The adapter turns it into what the database wants (`$1` for PostgreSQL) and always binds the value: a value is never put into the sql text. Write the sql as a constant of your program, and pass what comes from outside as parameters.

The number of parameters must match the number of placeholders, or the call is a bad input. A `?` inside a string, a quoted name or a comment is not a placeholder.

A list does not expand one placeholder. For `in (...)`, build the `?, ?, ?` from the length of the list, only the placeholders, and pass the values as parameters.

```agentica
import Db from "pkg/db/db"

def main() -> Void
  conn = Db.open("sqlite::memory:").unwrap!
  Db.execute(conn, "create table users (id integer primary key, name text not null)", []).unwrap!
  Db.execute(conn, "insert into users (name) values ('Ana'), ('Bob'), ('Cy'), ('Dee')", []).unwrap!
  ids = [1, 3, 4]
  marks = ids.map do |id| "?" end.join(", ")
  params = ids.map do |id| Db.Value.Int(id) end
  rows = Db.query(conn, "select name from users where id in (#{marks}) order by id", params).unwrap!
  puts(rows.size)
  Db.close(conn)
end
```

```output
3
```

## One statement

Only the first and only statement of the string runs. Two statements are an error, and so is a result with two columns of the same name: give them an alias.
