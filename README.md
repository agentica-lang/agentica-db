# agentica-db

Database package for [Agentica](https://github.com/agentica-lang/agentica): one API for SQLite, PostgreSQL and MySQL or
MariaDB, and a small typed ORM on top. Each database goes through its system client library by the C FFI; SQLite and
PostgreSQL also have a native driver (a statement cache, many rows per call), the default.

agentica-db 0.10.0-alpha.1 needs Agentica 0.31.0 or later, and a C compiler (`cc`, or `CC`; on
Debian `gcc` and `libc6-dev`) where a program that imports it first runs or is compiled: Agentica then builds the
native SQLite and PostgreSQL drivers into its package cache. Documentation: https://agentica-lang.github.io/agentica-db/

## Install

In your `agentica.toml`:

```toml
[dependencies]
db = { git = "https://github.com/agentica-lang/agentica-db", tag = "0.10.0-alpha.1", subdir = "src/db" }
```

Or run `agentica add db https://github.com/agentica-lang/agentica-db --tag 0.10.0-alpha.1 --subdir src/db`. Both (and
`agentica install` for a manifest you edited) write `agentica.lock` and `deps/db/`.

The package is the `src/db` folder of the repository, so the dependency needs `subdir = "src/db"`, for every release
after 0.3.0 and for `ref = "COMMIT"` (a commit of `main`). 0.3.0 and earlier have the package at the root of the
repository, so with those tags leave `subdir` out. The imports (`pkg/db/db`, `pkg/db/orm`) are the same in both.

## Example

```ruby
import Db from "pkg/db/db"

def run() -> Result[Void]
  conn = try Db.open("sqlite::memory:")
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
- [`src/db/examples/users.agc`](src/db/examples/users.agc): a users API on the ORM that runs against in-memory SQLite.
- [CHANGELOG](CHANGELOG.md).

## Development

```sh
make check
cd src/db && agentica test --jobs 4
```

Developing and using the package need Agentica 0.31.0 or later and a C compiler.

The PostgreSQL and MySQL scenarios need a server; see [Testing][testing] and
`AGENTS.md`. CI runs the SQLite suite on Linux, macOS and Windows, and the whole suite on Linux.

License: Apache-2.0.

[getting-started]: https://agentica-lang.github.io/agentica-db/getting-started/
[connecting]: https://agentica-lang.github.io/agentica-db/basics/connecting/
[queries]: https://agentica-lang.github.io/agentica-db/basics/queries/
[values]: https://agentica-lang.github.io/agentica-db/basics/values/
[transactions]: https://agentica-lang.github.io/agentica-db/basics/transactions/
[sqlite]: https://agentica-lang.github.io/agentica-db/databases/sqlite/
[postgresql]: https://agentica-lang.github.io/agentica-db/databases/postgresql/
[mysql]: https://agentica-lang.github.io/agentica-db/databases/mysql/
[orm-schema]: https://agentica-lang.github.io/agentica-db/orm/schema/
[orm-reads]: https://agentica-lang.github.io/agentica-db/orm/reads/
[orm-builder]: https://agentica-lang.github.io/agentica-db/orm/builder/
[orm-writes]: https://agentica-lang.github.io/agentica-db/orm/writes/
[orm-errors]: https://agentica-lang.github.io/agentica-db/orm/errors/
[timeouts]: https://agentica-lang.github.io/agentica-db/production/timeouts/
[generic-pool]: https://agentica-lang.github.io/agentica-db/production/generic-pool/
[migrations]: https://agentica-lang.github.io/agentica-db/tools/migrations/
[testing]: https://agentica-lang.github.io/agentica-db/tools/testing/
