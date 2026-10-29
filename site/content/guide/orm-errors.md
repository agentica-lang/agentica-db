---
title: "ORM: errors"
weight: 12
description: Tell the failures of the Orm apart with Orm.classify, and map them to statuses.
---

An error is a text, since that is what a `Result` holds. A failure of the Orm is `orm error <code>: <table>: <message>`, and `Orm.classify(text)` gives its kind to `case` on, so a handler never matches message text.

| Kind | Means | Suggested status |
|---|---|---|
| `Orm.Error.BadRequest(message)` | a column, value or key the caller got wrong: a column that is not in the schema, a value of another kind, an unknown key in `patch`, no condition in `delete_all` | 400 |
| `Orm.Error.Conflict(message)` | a unique or foreign-key violation, on any of the three databases | 409 |
| `Orm.Error.NotDecodable(message)` | a row that does not fit its struct: a missing column, a NULL in a field that is not a `JsonField` | 500 |
| `Orm.Error.Schema(message)` | a schema that is not sound: a name that is not an identifier, a field type no column holds, a key that is not a field | 500 |
| `Orm.Error.Database(message)` | any other error of the database (a lost connection, a missing table, a not null), or of the Orm's own bookkeeping | 500 |

The Orm does not know about HTTP, so the statuses are only suggestions.

```agentica
import Db from "pkg/db/db"
import Orm from "pkg/db/orm"

struct User
  id: Int = 0
  name: String
  age: JsonField[Int]
end

def status(message: String) -> Int
  case Orm.classify(message)
    Orm.Error.BadRequest(_) -> return 400
    Orm.Error.Conflict(_) -> return 409
    _ -> return 500
  end
end

def run() -> Result[Void]
  conn = try Db.open("sqlite::memory:")
  try Db.execute(conn, "create table users (id integer primary key, name text not null unique, age integer)", [])
  users = Orm.schema("users", User.members, JSON.codec(User))
  try Orm.insert(conn, users, User(name: "Ana", age: JsonField.Absent))
  case Orm.insert(conn, users, User(name: "Ana", age: JsonField.Absent))
    ok(_) -> puts("inserted")
    error(message) -> puts(status(message))
  end

  case Orm.from(users) |> Orm.where_eq("nickname", Db.Value.Text("x")) |> Orm.all(conn)
    ok(_) -> puts("found")
    error(message) -> puts(status(message))
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
409
400
done
```

## Helpers

`Orm.kind(error)` gives the name of the kind as a text (`"Conflict"`), for logs and tests. `Orm.message(error)` gives the message for a log: `<table>: <message>` for a failure of the Orm, and the text of the database as it is for the others.

A text that no rule knows, such as a `db error: ...`, is `Database`. A failure that the database itself reports (not an Orm failure) keeps the text of `Db`: see [connecting](/guide/connecting/) for its shapes.

The databases are recognized by their codes: SQLite error 19 with `UNIQUE` or `FOREIGN KEY` in its message, PostgreSQL `23505` and `23503`, and MySQL `1062`, `1451` and `1452`. A not null or a check violation is not a `Conflict`.

The full list of changes is in the [changelog](https://github.com/agentica-lang/agentica-db/blob/main/CHANGELOG.md).
