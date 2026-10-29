# agentica-db

Database package for [Agentica](https://github.com/agentica-lang/agentica): one API for SQLite, PostgreSQL and MySQL or
MariaDB, and a small typed ORM on top. Each database goes through its system client library by the C FFI.

Needs Agentica 0.15.0 or later. Documentation: https://agentica-lang.github.io/agentica-db/

## Install

In your `agentica.toml`:

```toml
[dependencies]
db = { git = "https://github.com/agentica-lang/agentica-db", tag = "v0.1.0" }
```

`v0.1.0` is a placeholder: there is no release yet, so pin a commit with `ref` until the first tag.

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

- [Getting started](https://agentica-lang.github.io/agentica-db/getting-started/): install and the system libraries.
- [Connecting](https://agentica-lang.github.io/agentica-db/guide/connecting/), [queries](https://agentica-lang.github.io/agentica-db/guide/queries/), [values](https://agentica-lang.github.io/agentica-db/guide/values/) and [transactions](https://agentica-lang.github.io/agentica-db/guide/transactions/).
- [SQLite](https://agentica-lang.github.io/agentica-db/guide/sqlite/), [PostgreSQL](https://agentica-lang.github.io/agentica-db/guide/postgresql/) and [MySQL and MariaDB](https://agentica-lang.github.io/agentica-db/guide/mysql/).
- The ORM: [schema](https://agentica-lang.github.io/agentica-db/guide/orm-schema/), [reads](https://agentica-lang.github.io/agentica-db/guide/orm-reads/), [query builder](https://agentica-lang.github.io/agentica-db/guide/orm-builder/) and [writes](https://agentica-lang.github.io/agentica-db/guide/orm-writes/).
- [Testing](https://agentica-lang.github.io/agentica-db/guide/testing/).
- [`examples/users.agc`](examples/users.agc): a users API on the ORM that runs against in-memory SQLite.
- [CHANGELOG](CHANGELOG.md).

## Development

```sh
make check
agentica test
```

The PostgreSQL and MySQL scenarios need a server; see [Testing](https://agentica-lang.github.io/agentica-db/guide/testing/) and `AGENTS.md`.

License: Apache-2.0.
