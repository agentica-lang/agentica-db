---
title: "ORM: reads"
weight: 9
description: Read rows into structs with Orm.query, Orm.query_as and Orm.find.
---

The reads take the connection first.

| Function | Gives |
|---|---|
| `Orm.query(conn, schema, sql, params)` | `Result[List[T]]`, each row read into a `T` |
| `Orm.query_as(conn, sql, params) do \|row\| ... end` | `Result[List[R]]`, each `Db.Row` read by your block |
| `Orm.find(conn, schema, id)` | `Result[Orm.Option[T]]`: `Option.Some(row)` or `Option.None` |

```agentica
import Db from "pkg/db/db"
import Orm from "pkg/db/orm"

struct User
  id: Int = 0
  name: String
  age: JsonField[Int]
end

def run() -> Result[Void]
  conn = try Db.open("sqlite::memory:")
  try Db.execute(conn, "create table users (id integer primary key, name text not null, age integer)", [])
  try Db.execute(conn, "insert into users (name, age) values ('Ana', 31), ('Bob', null)", [])
  users = Orm.schema("users", User.members, JSON.codec(User))
  found = try Orm.query(conn, users, "select id, name, age from users where age > ?", [Db.Value.Int(28)])
  puts(found)
  names = try Orm.query_as(conn, "select name from users order by id", []) do |row|
    case row["name"]
      Db.Value.Text(name) -> return ok(name)
      _ -> return error("no name")
    end
  end

  puts(names)
  case try Orm.find(conn, users, Db.Value.Int(2))
    Orm.Option.Some(user) -> puts(user.name)
    Orm.Option.None -> puts("no user")
  end

  case try Orm.find(conn, users, Db.Value.Int(9))
    Orm.Option.Some(user) -> puts(user.name)
    Orm.Option.None -> puts("no user")
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
[User(id: 1, name: "Ana", age: JsonField.Value(31))]
["Ana", "Bob"]
Bob
no user
done
```

## query

The sql is yours, with `?` for the parameters. The columns it returns are matched with the fields by name, in any order, and the case must be the same. The database decides the name of a result column (SQLite and MySQL give the case of the table), so use `as` to choose it. An extra column is ignored. A missing column is an error, unless its field is a `JsonField`.

Inside a transaction pass its connection: `Db.transaction(conn) do |tx| Orm.query(tx, users, sql, []) end`.

## query_as

Use `query_as` when a result is not one struct, such as a join or a count. Your block reads each `Db.Row`, and an `error` from the block is the error of the call.

## find

`find` is the row whose key is `id`, with `id` a `Db.Value` of the kind of the key field (`Db.Value.Int` for an `Int` key). A missing row is `Option.None`, not an error, so a web handler can answer a 404. A key of another kind is an error.
