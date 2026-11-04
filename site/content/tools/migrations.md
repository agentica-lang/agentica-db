---
title: Migrations
weight: 1
description: Apply ordered migrations with Migrate.up, which records them in a table and applies each once.
aliases:
  - /guide/migrations/
---

`Migrate` keeps the schema of a database in step with your code. A migration has a version, a name and an action: sql statements, or a function over the connection. `Migrate.up(conn, migrations)` applies the ones the database has not seen, in order, and records each in the table `schema_migrations`. Import it with `import Migrate from "pkg/db/migrate"`.

```ruby
Migrate.sql(version: Int, name: String, statements: List[String]) -> Migrate.Migration
Migrate.code(version: Int, name: String, body: Fn[Db.Connection, Result[Void]]) -> Migrate.Migration
Migrate.up(conn: Db.Connection, migrations: List[Migrate.Migration], table: String = "schema_migrations") -> Result[List[Int]]
```

```agentica
import Db from "pkg/db/db"
import Migrate from "pkg/db/migrate"

def migrations() -> List[Migrate.Migration]
  return [
    Migrate.sql(1, "users", ["create table users (id integer primary key, name text not null)"]),
    Migrate.sql(2, "index", ["create unique index users_name on users (name)"]),
    Migrate.code(3, "first user", &first_user),
  ]
end

def first_user(tx: Db.Connection) -> Result[Void]
  try Db.execute(tx, "insert into users (name) values (?)", [Db.Value.Text("ana")])
  return ok()
end

def run() -> Result[Void]
  conn = try Db.open("sqlite::memory:")
  puts(try Migrate.up(conn, migrations()))
  puts(try Migrate.up(conn, migrations()))
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
[1, 2, 3]
[]
done
```

`up` gives the versions it applied, and an empty list when the database was already up to date. Call it at startup, before the server listens.

## Lay out migrations

Give each migration its own file, numbered with zero-padded versions so that the folder lists them in order, like Rails: `migrations/m0001_create_users.agc`, `migrations/m0002_users_name_index.agc`... Each file exports one `migration()`, and a `code` migration keeps its function in the same file.

```agentica
import Db from "pkg/db/db"
import Migrate from "pkg/db/migrate"

export def migration() -> Migrate.Migration
  return Migrate.code(3, "first user", &first_user)
end

def first_user(tx: Db.Connection) -> Result[Void]
  try Db.execute(tx, "insert into users (name) values (?)", [Db.Value.Text("ana")])
  return ok()
end
```

`migrations.agc` only imports the files and returns the list in order (the two `ruby` blocks below mirror `src/db/examples/migrations.agc` and `src/db/test/migrations_layout_test.agc` of the repository, so a change to one updates the other). An import path is relative to the importing file, so the files of the folder are imported as `migrations/m0001_create_users` from the file next to the folder.

```ruby
import Migrate from "pkg/db/migrate"
import CreateUsers from "migrations/m0001_create_users"
import UsersNameIndex from "migrations/m0002_users_name_index"
import FirstUser from "migrations/m0003_first_user"

export def all() -> List[Migrate.Migration]
  return [CreateUsers.migration(), UsersNameIndex.migration(), FirstUser.migration()]
end
```

`up` does not see the folder, so a file that is missing from the list is never applied. Add a test for it: the versions go from 1 to N with no gap, and N is the number of `.agc` files in the folder (`Dir.list` is relative to the folder you run `agentica test` in).

```ruby
import Migrations from "../src/migrations"

def main() -> Void
  Test.run([
    Test.test("every migration file is in the list, numbered 1 to N") do
      versions = Migrations.all().map do |migration| migration.version end
      try Test.eq(versions, (1..versions.length).to_a)
      files = (try Dir.list("src/migrations")).select do |name| name.end_with?(".agc") end
      return Test.eq(files.length, versions.length)
    end,
  ])
end
```

With timestamp versions (see "What `up` refuses") the versions are not 1 to N, so keep only the count check. A runnable copy of this layout is in `src/db/examples/` of the repository (`migrations.agc`, `migrations/` and `migrate_layout.agc`, which the specs run).

## What `up` does

- It creates the history table when it is missing (`version`, `name` and `checksum`), then reads it.
- Each pending migration runs in its own transaction, together with the insert of its row in the history. A migration that fails (an `error` from a statement or from the function) rolls back, and `up` stops with `migrate error: migration 2 (index) failed: <the database message>`. The migrations before it stay applied, so fixing the migration and calling `up` again continues from there.
- The checksum is the SHA-256 of the statements. A function migration has the checksum of its name only, since a function has no text to compare: a change to its body is not noticed.

## What `up` refuses

`up` gives an `error` and runs no migration when the history does not fit the list. The message starts with `migrate error:`, as does an error of the database while `up` creates or reads the history table.

| Problem | Message |
|---|---|
| a version is not above the one before it in the list (versions are positive and ascend) | `migration 1 (b) must have a version above 2: ...` |
| an applied migration is not in the list | `migration 2 (b) is applied but not in the list` |
| an applied migration has other statements than when it ran | `migration 1 (users) was changed after it was applied` |
| an applied migration has another name than when it ran | `migration 1 (people) was renamed after it was applied, it was (users)` |
| a `name` that is empty or longer than 255 bytes | `migration 1 needs a name of 1 to 255 bytes` |
| a new migration has a lower version than an applied one | `migration 2 (b) is older than the applied migration 3, so it would run out of order` |
| `table` is not letters, digits and `_`, or starts with a digit | `the table name must be letters, digits and _, ...` |

Never edit or rename a migration that has been applied: add a new one. A version can be any increasing number, such as a timestamp (`20261103120000`), so that two people who add a migration on two branches do not pick the same number. The two migrations then both exist, but the one with the lower version is refused if the other one was applied first (the out-of-order row above). To recover, renumber the pending migration above the applied ones before you merge it; if it already ran somewhere, give it the same version there.

## Databases

The code is the same on SQLite, PostgreSQL and MySQL, and the statements are yours, so write sql the database takes. SQLite and PostgreSQL roll back a schema change that fails inside a migration. MySQL commits at once after a statement that changes the schema (`create table`, `alter table`...), so a failure between such a statement and the insert of its history row leaves it applied and unrecorded. On MySQL, put each schema change alone in its own migration and make a repeat harmless (`create table if not exists`, `drop table if exists`), so that running `up` again passes.

Run `up` from one process at a time. If two run together, one of them fails on the primary key of the history table. On PostgreSQL the first run of two can also fail in `create table if not exists` with a unique error on `pg_type`. On MySQL the schema change may already be done.

## Things to know

- There is no `down`. To undo a change, add a new migration that does it.
- A function migration runs inside the transaction of `up`: it must not start a transaction of its own (`Db.transaction` does not nest).
- On SQLite, `PRAGMA foreign_keys = off` does nothing inside a transaction, so it does nothing in a migration. Rebuild a table in the way the SQLite documentation describes, or run the pragma on the connection before `up`.
- `name` is 1 to 255 bytes, and it is recorded: renaming an applied migration is refused like changing its sql.

`table` names the history, so two lists of migrations can have two histories in one database (`Migrate.up(conn, plugin_migrations, "plugin_migrations")`).
