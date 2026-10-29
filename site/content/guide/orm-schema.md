---
title: "ORM: schema"
weight: 8
description: Tie a struct to a table with Orm.schema, check it, and how fields map to columns.
---

`Orm` is a small typed layer over `Db`. A schema ties a plain struct to a table. Every function takes the `Db.Connection` and gives a new value: there is no global connection and no lazy loading. Import it with `import Orm from "pkg/db/orm"`.

```agentica
import Db from "pkg/db/db"
import Orm from "pkg/db/orm"

CREATE_USERS = "create table users (id integer primary key, name text not null, age integer)"

struct User
  id: Int = 0
  name: String
  age: JsonField[Int]
end

def run() -> Result[Void]
  conn = try Db.open("sqlite::memory:")
  try Db.execute(conn, CREATE_USERS, [])
  users = Orm.schema("users", User.members, JSON.codec(User))
  try Orm.check(conn, users)
  puts(users.table)
  puts(users.primary_key)
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
users
id
done
```

## The schema

`Orm.schema(table, T.members, JSON.codec(T))` gives an `Orm.Schema[T]`. It checks nothing. `Orm.check(conn, schema)` does, once, at start up, and reads no row:

- the table and column names are plain identifiers (a letter or `_`, then letters, digits or `_`);
- every field has a type a column can hold;
- the key is a field;
- the table has every column. A table or a column that is missing is the error of `Db`, unchanged.

The key is `id`, and the database generates it, unless `.with(...)` says otherwise:

```agentica
import Orm from "pkg/db/orm"

struct Tag
  code: String
  label: String
end

def main() -> Void
  tags = Orm.schema("tags", Tag.members, JSON.codec(Tag)).with(primary_key: "code", generated: false)
  puts(tags.primary_key)
  puts(tags.generated)
end
```

```output
code
false
```

A generated key must be an `Int`. The key of a table the database numbers is written `id: Int = 0`, so a value can be built before the database gives it its id.

## Fields and columns

- A column has the name of its field. The Orm quotes every name (double quotes for PostgreSQL, backticks for MySQL and SQLite), so a name is exact in PostgreSQL, which folds an unquoted name to lower case.
- A field is an `Int`, a `Float`, a `Bool` or a `String`, alone or inside a `JsonField`.
- A column that can be NULL is a `JsonField[T]`. NULL reads as `JsonField.Null`, and a column the query does not select is `JsonField.Absent`. A NULL in any other field is an error.
- A `Bool` column of SQLite and MySQL comes back from `Db` as 0 or 1, and the Orm reads it as a `Bool`.
- An `Int` column is read as a `Float` for a `Float` field, unless the `Int` is beyond 2^53, which could round: that is an error.
- A `numeric`, a date or a uuid arrives as `Text`: use a `String` field.

Errors of the Orm are `Result` failures, like those of `Db`. [ORM: errors](/guide/orm-errors/) tells the kinds apart.
