---
title: Getting started
weight: 1
description: Install the package, get the system library of your database and run a first program.
---

## Install

Install [Agentica](https://agentica-lang.github.io/agentica/getting-started/) 0.17.0 or later. agentica-db is a package: you add it to the `agentica.toml` of your project as a dependency on its git repository.

```toml
[dependencies]
db = { git = "https://github.com/agentica-lang/agentica-db", tag = "0.2.0" }
```

Or run `agentica add db https://github.com/agentica-lang/agentica-db --tag 0.2.0`. Both (and `agentica install` for a manifest you edited) write `agentica.lock` and put the files in `deps/db/`.

Import the modules with `pkg/db/...`. `Db` is enough for most programs, and `Orm` is the typed layer.

```agentica
import Db from "pkg/db/db"
import Orm from "pkg/db/orm"

struct Note
  id: Int = 0
  text: String
end

def main() -> Void
  notes = Orm.schema("notes", Note.members, JSON.codec(Note))
  puts(Db.open("sqlite::memory:").ok?)
  puts(notes.table)
end
```

```output
true
notes
```

## System libraries

You need the client library of each database you open. A library loads when the first call needs it, so SQLite alone works without libpq or libmariadb.

| Database | Library | Package on Debian and Ubuntu |
|---|---|---|
| SQLite | `libsqlite3.so.0` | `libsqlite3-0` |
| PostgreSQL 12 or later | `libpq.so.5` | `libpq5` |
| MySQL, MariaDB | `libmariadb.so.3` | `libmariadb3` |

macOS and Windows names are declared (`libsqlite3.dylib`, `libpq.5.dylib`, `libmariadb.3.dylib`, `winsqlite3.dll`, `libpq.dll`, `libmariadb.dll`), but CI runs the SQLite suite on macOS and Windows, and the whole suite on Linux. On macOS the manifest cannot name an absolute path, so run with Homebrew's libraries, as in `DYLD_LIBRARY_PATH="$(brew --prefix libpq)/lib" agentica app.agc` (for MySQL, `mariadb-connector-c`). On Windows the DLLs are looked up next to `agentica.exe` and in System32, never in `PATH`, and so are the DLLs they need.

A library that is missing does not stop the program: `open` gives an `error` that says so, as in `sqlite error: cannot load the SQLite library: ...`.

## A first program

Save this as `app.agc` and run it with `agentica app.agc`. It opens a database, makes a table, writes in a transaction and reads back.

```agentica
import Db from "pkg/db/db"

def save(conn: Db.Connection, name: String, age: Int) -> Result[Int]
  return Db.execute(conn, "insert into users (name, age) values (?, ?)", [Db.Value.Text(name), Db.Value.Int(age)])
end

def run() -> Result[Void]
  conn = try Db.open("sqlite::memory:")
  try Db.execute(conn, "create table users (name text not null, age integer)", [])
  try Db.transaction(conn) do |tx|
    try save(tx, "Ana", 31)
    try save(tx, "Bob", 27)
    ok()
  end

  rows = try Db.query(conn, "select name from users order by name", [])
  puts(rows.size)
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
done
```

Every call gives a `Result`, so the program uses `try` to pass an `error` up, and `main` is the one place that looks at it. The next pages explain each call: [connecting](/guide/connecting/), [queries](/guide/queries/), [values](/guide/values/) and [transactions](/guide/transactions/).
