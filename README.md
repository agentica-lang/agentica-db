# agentica-db

Database package for [Agentica](https://github.com/agentica-lang/agentica): one API for SQLite, PostgreSQL and MySQL or
MariaDB, and a small typed ORM on top. Each database goes through its system client library by the C FFI.

agentica-db 0.1.0 needs Agentica 0.16.0 or later. Documentation: https://agentica-lang.github.io/agentica-db/

## Install

In your `agentica.toml`:

```toml
[dependencies]
db = { git = "https://github.com/agentica-lang/agentica-db", tag = "0.1.0" }
```

Or run `agentica add db https://github.com/agentica-lang/agentica-db --tag 0.1.0`. Both (and `agentica install`
for a manifest you edited) write `agentica.lock` and `deps/db/`.

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
- [Connecting][connecting], [queries][queries], [values][values] and [transactions][transactions].
- [SQLite][sqlite], [PostgreSQL][postgresql] and [MySQL and MariaDB][mysql].
- The ORM: [schema][orm-schema], [reads][orm-reads], [query builder][orm-builder], [writes][orm-writes] and
  [errors][orm-errors].
- [Testing][testing].
- [`examples/users.agc`](examples/users.agc): a users API on the ORM that runs against in-memory SQLite.
- [CHANGELOG](CHANGELOG.md).

## Development

```sh
make check
agentica test
```

The PostgreSQL and MySQL scenarios need a server; see [Testing][testing] and
`AGENTS.md`. CI runs the SQLite suite on Linux, macOS and Windows, and the whole suite on Linux.

License: Apache-2.0.

[getting-started]: https://agentica-lang.github.io/agentica-db/getting-started/
[connecting]: https://agentica-lang.github.io/agentica-db/guide/connecting/
[queries]: https://agentica-lang.github.io/agentica-db/guide/queries/
[values]: https://agentica-lang.github.io/agentica-db/guide/values/
[transactions]: https://agentica-lang.github.io/agentica-db/guide/transactions/
[sqlite]: https://agentica-lang.github.io/agentica-db/guide/sqlite/
[postgresql]: https://agentica-lang.github.io/agentica-db/guide/postgresql/
[mysql]: https://agentica-lang.github.io/agentica-db/guide/mysql/
[orm-schema]: https://agentica-lang.github.io/agentica-db/guide/orm-schema/
[orm-reads]: https://agentica-lang.github.io/agentica-db/guide/orm-reads/
[orm-builder]: https://agentica-lang.github.io/agentica-db/guide/orm-builder/
[orm-writes]: https://agentica-lang.github.io/agentica-db/guide/orm-writes/
[orm-errors]: https://agentica-lang.github.io/agentica-db/guide/orm-errors/
[testing]: https://agentica-lang.github.io/agentica-db/guide/testing/
