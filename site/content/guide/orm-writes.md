---
title: "ORM: writes"
weight: 11
description: Insert, update, delete and patch one row, and update_all and delete_all for many.
---

The writes take the connection first. They bind every value and run the name, type and key rules of `check` before any sql.

| Function | Gives |
|---|---|
| `Orm.insert(conn, schema, value)` | `Result[T]`, the row as stored, with its generated key |
| `Orm.update(conn, schema, value)` | `Result[Int]`, the rows set (0: no row has the key of `value`) |
| `Orm.delete(conn, schema, id)` | `Result[Int]`, the rows removed; `id` is a `Db.Value` |
| `Orm.patch(conn, schema, id, changes)` | `Result[Int]`, the rows changed; `changes` is a `Json` object |

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
  users = Orm.schema("users", User.members, JSON.codec(User))
  ana = try Db.transaction(conn) do |tx|
    Orm.insert(tx, users, User(name: "Ana", age: JsonField.Absent))
  end

  puts(ana.id)
  puts(try Orm.update(conn, users, ana.with(name: "Anna", age: JsonField.Value(32))))
  changes = try JSON.parse("{\"age\": null}")
  puts(try Orm.patch(conn, users, Db.Value.Int(ana.id), changes))
  puts(try Orm.delete(conn, users, Db.Value.Int(ana.id)))
  puts(try Orm.delete(conn, users, Db.Value.Int(ana.id)))
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
1
1
1
1
0
done
```

## insert

`insert` leaves out a generated key (whatever the value holds) and a `JsonField` that is `Absent`, so the default of the database applies. It gives the row back read again by its key.

The key must be the one the database generates: the `INTEGER PRIMARY KEY` of SQLite, the `AUTO_INCREMENT` column of MySQL, a `serial` or identity column of PostgreSQL. PostgreSQL gets the key with `returning`; SQLite and MySQL with `last_insert_rowid()` and `last_insert_id()` on the same connection.

The insert and the read after it are two statements, so put them in a transaction (`Db.transaction`) when other writers matter. A key that is not generated (`.with(generated: false)`) is inserted as it is. A value with nothing to insert (a generated key and `Absent` fields only) is an error. The error of the database, such as a unique key or a not null, comes back unchanged.

## update

`update` sets every column but the key to the field, in the row with the key of the value. `Absent` keeps the column, and `Null` clears it. A value with only the key and `Absent` fields has nothing to set, which is an error.

## delete and patch

`delete` and `patch` take the key as a `Db.Value` of the kind of the key field (`Db.Value.Int(7)` for an `Int` key). Another kind is an error.

`patch` takes the changes as a `Json` object, such as the body of a request. A key that is a column sets it (`null` clears a `JsonField` column), and a column the object leaves out keeps its value. These are errors, before any sql runs: a key that is not a column, the primary key, a value of the wrong kind, a `null` for a field that is not a `JsonField`, and an object with no column to change.

## Many rows: update_all and delete_all

`Orm.update_all(query, conn, changes)` sets the columns of a `Json` object in every row the conditions keep, as `patch` does. `Orm.delete_all(query, conn)` removes them. Both give the number of rows.

They refuse two things, because not every database allows them and because a mistake here is costly:

- an `order_by`, a `limit` or an `offset`;
- a query with no condition. A pipeline whose optional filters were all skipped must not change the whole table.

When you do mean every row, say so with a condition that is always true: `Orm.where("1 = 1", [])`.

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
  try Db.execute(conn, "insert into users (name, age) values ('Ana', 31), ('Bob', 27), ('Cy', 40)", [])
  users = Orm.schema("users", User.members, JSON.codec(User))
  refused = Orm.from(users) |> Orm.delete_all(conn)
  puts(refused.ok?)
  old = try (Orm.from(users) |> Orm.where("age > ?", [Db.Value.Int(30)]) |> Orm.delete_all(conn))
  puts(old)
  everyone = try (Orm.from(users) |> Orm.where("1 = 1", []) |> Orm.delete_all(conn))
  puts(everyone)
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
false
2
1
done
```
