---
title: Reads
weight: 2
description: Read rows into structs with Orm.query, Orm.query_as, Orm.decode_row and Orm.find.
aliases:
  - /guide/orm-reads/
---

The reads take the connection first.

| Function | Gives |
|---|---|
| `Orm.query(conn, schema, sql, params)` | `Result[List[T]]`, each row read into a `T` |
| `Orm.query_as(conn, sql, params) do \|row\| ... end` | `Result[List[R]]`, each `Db.Row` read by your block |
| `Orm.decode_row(row, T.codec)` | `Result[T]`: one `Db.Row` read into a `T`, in your `query_as` block |
| `Orm.find(conn, schema, id)` | `Result[Optional[T]]`: `some(row)` or `none` |

```agentica
import Db from "pkg/db/db"
import Orm from "pkg/db/orm"
import Sqlite from "pkg/db/sqlite"

struct User
  id: Int = 0
  name: String
  age: Optional[Int] = none
end

def run() -> Result[Void]
  conn = try Db.open("sqlite::memory:", [Sqlite.driver()])
  try Db.execute(conn, "create table users (id integer primary key, name text not null, age integer)", [])
  try Db.execute(conn, "insert into users (name, age) values ('Ana', 31), ('Bob', null)", [])
  users = Orm.schema("users", User.codec)
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
    some(user) -> puts(user.name)
    none -> puts("no user")
  end

  case try Orm.find(conn, users, Db.Value.Int(9))
    some(user) -> puts(user.name)
    none -> puts("no user")
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
[User(id: 1, name: "Ana", age: some(31))]
["Ana", "Bob"]
Bob
no user
done
```

## query

The sql is yours, with `?` for the parameters. The columns it returns are matched with the fields by name, in any order, and the case must be the same. The database decides the name of a result column (SQLite and MySQL give the case of the table), so use `as` to choose it. An extra column is ignored. A missing column is an error, even for an `Optional` field (select its column, NULL or not), unless the field is a `JSON.Field`, which reads it as `Absent`.

Inside a transaction pass its connection: `Db.transaction(conn) do |tx| Orm.query(tx, users, sql, []) end`.

## query_as

Use `query_as` when a result is not one struct, such as a join or a count. Your block reads each `Db.Row`, and an `error` from the block is the error of the call.

## find

`find` is the row whose key is `id`, with `id` a `Db.Value` of the kind of the key field (`Db.Value.Int` for an `Int` key). A missing row is `none`, not an error, so a web handler can answer a 404. A key of another kind is an error.

## decode_row

`Orm.decode_row(row, T.codec)` reads one `Db.Row` into a `T` with the rules of `query`: the columns are matched with the fields by name, a NULL is `none` for an `Optional` field, and an extra column is ignored. It needs no schema or table, so it fits a join or a select whose columns you named with `as`, inside the block of `query_as`.

```agentica
import Db from "pkg/db/db"
import Orm from "pkg/db/orm"
import Sqlite from "pkg/db/sqlite"

struct Member
  id: Int
  name: String
  team: String
  age: Optional[Int] = none
end

struct Wrong
  age: String
end

def run() -> Result[Void]
  conn = try Db.open("sqlite::memory:", [Sqlite.driver()])
  try Db.execute(conn, "create table users (id integer primary key, name text not null, age integer)", [])
  try Db.execute(conn, "create table teams (user_id integer not null, name text not null)", [])
  try Db.execute(conn, "insert into users (name, age) values ('Ana', 31), ('Bob', null)", [])
  try Db.execute(conn, "insert into teams (user_id, name) values (1, 'red'), (2, 'blue')", [])
  sql = "select u.id as id, u.name as name, t.name as team, u.age as age from users u join teams t on t.user_id = u.id order by u.id"
  members = try Orm.query_as(conn, sql, []) do |row| Orm.decode_row(row, Member.codec) end
  puts(members)
  rows = try Db.query(conn, "select age from users where id = 1", [])
  case Orm.decode_row(rows[0], Wrong.codec)
    ok(_) -> puts("decoded")
    error(message) -> puts(message)
  end

  case Orm.decode_row(rows[0], Member.codec)
    ok(_) -> puts("decoded")
    error(message) -> puts(message)
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
[Member(id: 1, name: "Ana", team: "red", age: some(31)), Member(id: 2, name: "Bob", team: "blue", age: none)]
orm error decode: age: expected String
orm error decode: id: missing column
done
```

A field with no column, or of another type, is `error("orm error decode: <field>: <what is wrong>")`, so the message names the column, and `Orm.classify` gives `NotDecodable`.
