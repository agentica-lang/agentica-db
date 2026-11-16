# agentica-db

Database package for [Agentica](https://github.com/agentica-lang/agentica): one API for SQLite, PostgreSQL and MySQL or
MariaDB, and a small typed ORM on top. Each database goes through its system client library by the C FFI; SQLite and
PostgreSQL also have a native driver (a statement cache, many rows per call), the default; MySQL's runs on Linux.

agentica-db 0.13.0 needs Agentica 0.31.0 or later (0.9.0 needs 0.30.0). Where a program that imports its SQLite,
PostgreSQL or MySQL driver first runs or is compiled, Agentica builds the native module of each driver the program
imports into its package cache with the C compiler (`cc`, or `CC`; on Debian `gcc` and `libc6-dev`). Without a
compiler it prints a warning and the program runs the FFI drivers.
Documentation: https://www.agentica-lang.com/agentica-db/

## Install

In your `agentica.toml`:

```toml
[dependencies]
db = { git = "https://github.com/agentica-lang/agentica-db", tag = "0.13.0" }
```

Or run `agentica add db https://github.com/agentica-lang/agentica-db --tag 0.13.0`, which writes that line,
`agentica.lock` and `deps/db/`. After you write or edit the dependencies by hand, run `agentica update`;
`agentica install` puts back `deps/` from the `agentica.lock` you have, as in a fresh clone.

The package is the root of the repository from 0.13.0 on, so the dependency takes no `subdir`. The releases 0.4.0 to
0.12.0 have it in the `src/db` folder: with those tags, and with a `ref = "COMMIT"` of `main` older than 0.13.0, add
`subdir = "src/db"`. The imports (`pkg/db/db`, `pkg/db/orm`) are the same in all of them.

## Example

```ruby
import Db from "pkg/db/db"
import Sqlite from "pkg/db/sqlite"

def run() -> Result[Void]
  conn = try Db.open("sqlite::memory:", [Sqlite.driver()])
  try Db.execute(conn, "create table users (name text not null, age integer)", [])
  try Db.transaction(conn) do |tx|
    try Db.execute(tx, "insert into users (name, age) values (?, ?)", [Db.Value.Text("Ana"), Db.Value.Int(31)])
    ok()
  end

  rows = try Db.query(conn, "select name, age from users where age > ?", [Db.Value.Int(28)])
  puts(rows)   # [{"name": Value.Text("Ana"), "age": Value.Int(31)}]
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

## Documentation

- [Getting started][getting-started]: install and the system libraries.
- Basics: [connecting][connecting], [queries][queries], [values][values] and [transactions][transactions].
- The ORM: [schema][orm-schema], [reads][orm-reads], [query builder][orm-builder], [writes][orm-writes] and
  [errors][orm-errors].
- Production: [timeouts][timeouts] and the [generic pool][generic-pool].
- Tools: [migrations][migrations] and [testing][testing].
- The databases: [SQLite][sqlite], [PostgreSQL][postgresql] and [MySQL and MariaDB][mysql].
- [`examples/users.agc`](examples/users.agc): a users API on the ORM that runs against in-memory SQLite.
- [CHANGELOG](CHANGELOG.md).

## Development

```sh
make check
agentica test --jobs 4
```

Developing the package needs 0.31.0 or later; using it needs the version above.

The PostgreSQL and MySQL scenarios need a server; see [Testing][testing] and
`AGENTS.md`. CI runs the SQLite suite on Linux, macOS and Windows, and the whole suite on Linux.

License: Apache-2.0.

[getting-started]: https://www.agentica-lang.com/agentica-db/getting-started/
[connecting]: https://www.agentica-lang.com/agentica-db/basics/connecting/
[queries]: https://www.agentica-lang.com/agentica-db/basics/queries/
[values]: https://www.agentica-lang.com/agentica-db/basics/values/
[transactions]: https://www.agentica-lang.com/agentica-db/basics/transactions/
[sqlite]: https://www.agentica-lang.com/agentica-db/databases/sqlite/
[postgresql]: https://www.agentica-lang.com/agentica-db/databases/postgresql/
[mysql]: https://www.agentica-lang.com/agentica-db/databases/mysql/
[orm-schema]: https://www.agentica-lang.com/agentica-db/orm/schema/
[orm-reads]: https://www.agentica-lang.com/agentica-db/orm/reads/
[orm-builder]: https://www.agentica-lang.com/agentica-db/orm/builder/
[orm-writes]: https://www.agentica-lang.com/agentica-db/orm/writes/
[orm-errors]: https://www.agentica-lang.com/agentica-db/orm/errors/
[timeouts]: https://www.agentica-lang.com/agentica-db/production/timeouts/
[generic-pool]: https://www.agentica-lang.com/agentica-db/production/generic-pool/
[migrations]: https://www.agentica-lang.com/agentica-db/tools/migrations/
[testing]: https://www.agentica-lang.com/agentica-db/tools/testing/
