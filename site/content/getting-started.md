---
title: Getting started
weight: 1
description: Install the package, get the system library of your database and run a first program.
---

## Install

Install [Agentica](https://www.agentica-lang.com/agentica/getting-started/) 0.31.0 or later for the tag `0.13.0`, and a C compiler (`cc`, or `CC`; on Debian `gcc` and `libc6-dev`) where a program that imports a driver of the package first runs or is compiled: Agentica builds the native SQLite, PostgreSQL or MySQL module of each driver the program imports then (see [SQLite](/databases/sqlite/#drivers)). Without a compiler Agentica prints a warning (`warning: native module db_sqlite not built: ...`) and the program runs the FFI drivers, which are slower. agentica-db is a package: you add it to the `agentica.toml` of your project as a dependency on its git repository.

```toml
[dependencies]
db = { git = "https://github.com/agentica-lang/agentica-db", tag = "0.13.0" }
```

Or run `agentica add db https://github.com/agentica-lang/agentica-db --tag 0.13.0`, which writes that line and `agentica.lock` and puts the files in `deps/db/`. After you write or edit the dependencies by hand, run `agentica update`; `agentica install` puts back `deps/` from the `agentica.lock` you have, as in a fresh clone.

The package is the root of the repository from 0.13.0 on (and for `ref = "COMMIT"`, a commit of `main`), so the dependency takes no `subdir`. The releases 0.4.0 to 0.12.0 have it in the `src/db` folder: with those tags add `subdir = "src/db"`. The imports are the same in all of them.

Import the modules with `pkg/db/...`. `Db` is the API, `Orm` the typed layer, and `Sqlite`, `Postgres` and `Mysql` the drivers that `Db.open` takes: import only the ones the program uses (see [Connecting](/basics/connecting/#drivers)).

```agentica
import Db from "pkg/db/db"
import Orm from "pkg/db/orm"
import Sqlite from "pkg/db/sqlite"

struct Note
  id: Int = 0
  text: String
end

def main() -> Void
  notes = Orm.schema("notes", Note.codec)
  puts(Db.open("sqlite::memory:", [Sqlite.driver()]).ok?)
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
import Sqlite from "pkg/db/sqlite"

def save(conn: Db.Connection, name: String, age: Int) -> Result[Int]
  return Db.execute(conn, "insert into users (name, age) values (?, ?)", [Db.Value.Text(name), Db.Value.Int(age)])
end

def run() -> Result[Void]
  conn = try Db.open("sqlite::memory:", [Sqlite.driver()])
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

Every call gives a `Result`, so the program uses `try` to pass an `error` up, and `main` is the one place that looks at it. The next pages explain each call: [connecting](/basics/connecting/), [queries](/basics/queries/), [values](/basics/values/) and [transactions](/basics/transactions/).
