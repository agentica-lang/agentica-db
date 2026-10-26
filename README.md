# agentica-db

Database package for [Agentica](https://github.com/sonic182/agentica): one API for PostgreSQL, SQLite and MySQL,
with one adapter per database, all through the C FFI (no C code of ours).

| Database | Adapter | Status |
|---|---|---|
| SQLite | `sqlite.agc`, the system `libsqlite3` | available |
| PostgreSQL | `libpq` | planned |
| MySQL | `libmariadb` / `libmysqlclient` | planned |

Needs Agentica 0.10.0 or later and the system SQLite library (`libsqlite3.so.0` on Linux, `libsqlite3.dylib`
on macOS, `winsqlite3.dll` on Windows). CI runs on Linux only; the macOS and Windows library names are declared but
not tested yet.

## Install

In your `agentica.toml`:

```toml
[dependencies]
db = { git = "https://github.com/sonic182/agentica-db", tag = "v0.1.0" }
```

`v0.1.0` is a placeholder: there is no release yet, so pin a commit with `--ref COMMIT` until the first tag.
Then `agentica add db https://github.com/sonic182/agentica-db --tag v0.1.0` (or `agentica install` for a manifest
you edited) writes `agentica.lock` and `deps/db/`.

## Example

```ruby
import Db from "pkg/db/db"
import {Value} from "pkg/db/value"

def save(conn: Db.Connection, name: String, age: Int) -> Result[Int]
  return Db.execute(conn, "insert into users (name, age) values (?, ?)", [Value.Text(name), Value.Int(age)])
end

def run() -> Result[Void]
  conn = try Db.open("sqlite::memory:")
  try Db.execute(conn, "create table users (name text not null, age integer)", [])
  try Db.transaction(conn) do |tx|
    try save(tx, "Ana", 31)
    try save(tx, "Bob", 27)
    ok()
  end
  rows = try Db.query(conn, "select name, age from users where age > ?", [Value.Int(28)])
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

## API

`db.agc` (`import Db from "pkg/db/db"`):

| Function | Gives |
|---|---|
| `open(url)` | `Result[Connection]`; `sqlite:PATH` (`sqlite::memory:` for memory) |
| `open_sqlite(path)` | `Result[Connection]` |
| `query(conn, sql, params)` | `Result[List[Row]]`, a `Row` is `Map[String, Value]` in column order |
| `execute(conn, sql, params)` | `Result[Int]`, the rows inserted, updated or deleted |
| `transaction(conn) do \|tx\| ... end` | `Result[Void]`; BEGIN, then COMMIT on `ok`, ROLLBACK on `error` |
| `close(conn)` | `Void`; closing twice is safe |

`value.agc` (`import {Value} from "pkg/db/value"`): `Value.Null`, `Value.Int(Int)`, `Value.Float(Float)`,
`Value.Text(String)`, `Value.Blob(List[Int])`, `Value.Bool(Bool)`.

- Placeholders are `?`, always bound; values are never spliced into the sql. The sql text is a constant of your
  program. A list does not expand a placeholder: for `in (...)` build `?, ?, ?` from the list length yourself (only
  the placeholders, never the values) and pass the values as parameters.
- An error is `error(message)` in one of two shapes. An engine failure is `<adapter> error <code>: <message>`, as in
  `sqlite error 1: near "from": syntax error`. A bad input, refused before the statement runs (wrong parameter count, a
  NUL in text, a blob item outside 0..255, no statement, two statements, a repeated result column), is
  `<adapter> error: <message>`. An unknown url is `db error: <message>`.
- Only the first and only statement of the string runs; two statements are an error. A result with two columns of
  one name is an error: alias them.
- Types: a database type without a `Value` variant comes back as `Value.Text` (the contract for PostgreSQL and
  MySQL types such as numeric, date or uuid). SQLite has no boolean: `Value.Bool` is stored as 0 or 1 and reads
  back as `Value.Int`. NaN is stored as NULL.
- SQLite keeps its defaults: foreign keys are off until you run `PRAGMA foreign_keys = ON`.
- `transaction` starts with `BEGIN IMMEDIATE` on SQLite, which needs write access to the database (a read-only
  database cannot open a transaction). A runtime error (a halt) inside the body stops the task
  and leaves the transaction open until the task ends; closing the connection then rolls it back.
- A connection belongs to the task that opened it. `close` ends it; so does the end of the task. Using it after
  `close` is a runtime error (`RUNTIME-NATIVE-CLOSED`).

## Development

```sh
for file in *.agc test/*.agc; do agentica check "$file"; done
agentica test
```

SQLite needs no server. See `AGENTS.md`.

License: Apache-2.0.
