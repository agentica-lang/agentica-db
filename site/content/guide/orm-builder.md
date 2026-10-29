---
title: "ORM: query builder"
weight: 10
description: Build a query with from, where_eq, where_in, order_by, limit and offset, and end it with all, one or count.
---

`Orm.from(schema)` starts a query. The steps take the query first and give a new one, so they chain with `|>`. The query ends in `all`, `one`, `count`, `update_all` or `delete_all`. A query is a value: every step gives a new one.

| Step | Does |
|---|---|
| `Orm.where(query, sql, params)` | adds sql of your program, with `?` for the params |
| `Orm.where_eq(query, column, value)` | `column = ?`; `Db.Value.Null` is `column is null` |
| `Orm.where_in(query, column, values)` | `column in (?, ...)`; no value keeps no row |
| `Orm.order_by(query, column)`, `Orm.order_by_desc(query, column)` | order by a column, after the ones already given |
| `Orm.limit(query, n)`, `Orm.offset(query, n)` | page the rows; an offset with no limit works on every database |

| End | Gives |
|---|---|
| `Orm.all(query, conn)` | `Result[List[T]]` |
| `Orm.one(query, conn)` | `Result[Orm.Option[T]]`, the first row or `Option.None` |
| `Orm.count(query, conn)` | `Result[Int]`, the rows the conditions keep (order and page do not count) |
| `Orm.update_all(query, conn, changes)` and `Orm.delete_all(query, conn)` | see [writes](/guide/orm-writes/) |

```agentica
import Db from "pkg/db/db"
import Orm from "pkg/db/orm"

struct User
  id: Int = 0
  name: String
  age: JsonField[Int]
  admin: Bool
end

def run() -> Result[Void]
  conn = try Db.open("sqlite::memory:")
  try Db.execute(conn, "create table users (id integer primary key, name text not null, age integer, admin integer not null)", [])
  try Db.execute(conn, "insert into users (name, age, admin) values ('Ana', 31, 1), ('Bob', 27, 0), ('Cy', 40, 1), ('Dee', null, 1)", [])
  users = Orm.schema("users", User.members, JSON.codec(User))
  admins = try (Orm.from(users)
    |> Orm.where_eq("admin", Db.Value.Bool(true))
    |> Orm.where("age > ?", [Db.Value.Int(28)])
    |> Orm.order_by_desc("age")
    |> Orm.limit(10)
    |> Orm.all(conn))
  for user in admins
    puts(user.name)
  end

  total = try (Orm.from(users) |> Orm.where_in("name", [Db.Value.Text("Ana"), Db.Value.Text("Bob")]) |> Orm.count(conn))
  puts(total)
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
Cy
Ana
2
done
```

A line cannot start with `|>` unless the chain is in parentheses, as above.

## Conditions

- All the conditions must hold (`and`).
- A column that is not in the schema, or a value of another kind than its column (`age` is an `Int`, so `Db.Value.Text` is wrong), is not an error of the step. The query keeps the first problem, and the call that ends it gives the error, before any sql runs. So a column name from a request is safe in `where_eq`, `where_in` and `order_by`.
- The sql of `where` is yours, so keep it a constant of your program and pass values as params. Do not build it from a request.
- `where_eq` and `where_in` refuse a `Float` that is NaN or an infinity.
- `where_in` takes no `Null` item, since an `in` list never matches NULL: use `where_eq(column, Db.Value.Null)`. A very long list may pass the limit of placeholders of the database, which is an error of the database.

## Order and page

Rows come in the order of the database unless `order_by` says otherwise, for `all` and `one` alike. Where NULLs sort differs between the databases (SQLite and MySQL: first when ascending; PostgreSQL: last), so do not count on it, or order by a column that is never NULL. `limit` and `offset` take a count of zero or more.

`one` keeps a limit smaller than 1, so a limit of 0 gives `None`. `Orm.find` is `where_eq` on the key plus `one`.
