# agentica-db

Database package for [Agentica](https://github.com/sonic182/agentica): one API for PostgreSQL, SQLite and MySQL,
with one adapter per database, all through the C FFI (no C code of ours).

| Database | Adapter | Status |
|---|---|---|
| SQLite | `sqlite.agc`, the system `libsqlite3` | available |
| PostgreSQL | `postgres.agc`, the system `libpq` | available |
| MySQL, MariaDB | `mysql.agc`, the system `libmariadb` | available |

Needs Agentica 0.11.0 or later and the system library of the database you open: SQLite (`libsqlite3.so.0` on
Linux, `libsqlite3.dylib` on macOS, `winsqlite3.dll` on Windows), libpq (`libpq.so.5`, `libpq.5.dylib`,
`libpq.dll`; PostgreSQL 12 or later) or MariaDB Connector/C (`libmariadb.so.3`, `libmariadb.3.dylib`,
`libmariadb.dll`; package `libmariadb3` on Debian and Ubuntu). A library is loaded when the first call needs it, so
SQLite alone works without libpq or libmariadb. CI runs on Linux only; the macOS and Windows library names are
declared but not tested yet. On macOS the manifest cannot name an absolute path, so run with Homebrew's libraries as
`DYLD_LIBRARY_PATH="$(brew --prefix libpq)/lib" agentica ...` (for MySQL, `mariadb-connector-c`). On Windows,
`libpq.dll` and `libmariadb.dll` are looked up next to `agentica.exe` and in System32, never in `PATH`, and so are
the DLLs they need (`libssl`, `libcrypto`, `libintl`, ... for libpq; `libcrypto` and `libssl` for libmariadb):
copy them there.

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

## API

`db.agc` (`import Db from "pkg/db/db"`) is the whole API, types included:

| Function | Gives |
|---|---|
| `open(url)` | `Result[Connection]`; `sqlite:PATH` (`sqlite::memory:`), `postgres[ql]://`, `mysql://`, `mariadb://` |
| `open_sqlite(path)` | `Result[Connection]` |
| `open_postgres(url)` | `Result[Connection]`, a libpq url or a conninfo string (`host=localhost dbname=app`) |
| `open_mysql(url)` | `Result[Connection]`, a `mysql://` or `mariadb://` url |
| `query(conn, sql, params)` | `Result[List[Db.Row]]`, a `Db.Row` is `Map[String, Db.Value]` in column order |
| `execute(conn, sql, params)` | `Result[Int]`, the rows inserted, updated or deleted |
| `transaction(conn) do \|tx\| ... end` | `Result[Void]`; BEGIN, then COMMIT on `ok`, ROLLBACK on `error` |
| `close(conn)` | `Void`; closing twice is safe |

`Db` also re-exports the types of `value.agc`, so one import is enough: `Db.Value` (`Db.Value.Null`,
`Db.Value.Int(Int)`, `Db.Value.Float(Float)`, `Db.Value.Text(String)`, `Db.Value.Blob(List[Int])`,
`Db.Value.Bool(Bool)`) and `Db.Row`.

- Placeholders are `?`, always bound (PostgreSQL gets `$1..$n`, MySQL takes `?` as it is; see below); values are
  never spliced into the sql.
  The sql text is a constant of your program. A list does not expand a placeholder: for `in (...)` build `?, ?, ?`
  from the list length yourself (only the placeholders, never the values) and pass the values as parameters.
- An error is `error(message)` in one of two shapes. An engine failure is `<adapter> error <code>: <message>`, as in
  `sqlite error 1: near "from": syntax error`. A bad input, refused before the statement runs (wrong parameter count, a
  NUL in text, a blob item outside 0..255, no statement, two statements, a repeated result column), is
  `<adapter> error: <message>`. An unknown url is `db error: <message>`. The code of PostgreSQL is its five character
  SQLSTATE, the code of MySQL is the number of the server or the client library (see below).
- Only the first and only statement of the string runs; two statements are an error. A result with two columns of
  one name is an error: alias them.
- Types: a database type without a `Value` variant comes back as `Db.Value.Text` (the contract for PostgreSQL and
  MySQL types such as numeric, date or uuid). SQLite has no boolean: `Db.Value.Bool` is stored as 0 or 1 and reads
  back as `Db.Value.Int`. NaN is stored as NULL.
- SQLite keeps its defaults: foreign keys are off until you run `PRAGMA foreign_keys = ON`.
- `transaction` starts with `BEGIN IMMEDIATE` on SQLite, which needs write access to the database (a read-only
  database cannot open a transaction). A runtime error (a halt) inside the body stops the task
  and leaves the transaction open; closing the connection rolls it back. For SQLite and PostgreSQL the end of the
  task closes it; for MySQL the transaction and its locks stay until `Db.close` or the end of the process.
- A connection belongs to the task that opened it, and one task uses it at a time. `close` ends it; for SQLite and
  PostgreSQL so does the end of the task, but for MySQL only `Db.close` does (see below). Using a SQLite connection
  after `close` is a runtime error (`RUNTIME-NATIVE-CLOSED`).

## PostgreSQL

```ruby
conn = try Db.open("postgres://user:pass@localhost:5432/app?sslmode=disable")
rows = try Db.query(conn, "select id, name from users where age > ?::int", [Db.Value.Int(28)])
```

- The url goes to libpq as it is, so every libpq parameter works (`sslmode`, `connect_timeout`, `application_name`,
  `options`). Set `connect_timeout` (seconds): without it an unreachable host waits as long as the
  operating system does. The client encoding is always UTF8.
  A connection that cannot open, or a url libpq cannot parse, is `postgres error: <libpq message>`. For a url libpq
  cannot parse, its message may quote the url, password included: do not log it blindly.
- Types, read and written (parameters travel as text, and the server infers their types from the sql):

  | PostgreSQL | `Value` |
  |---|---|
  | `smallint`, `integer`, `bigint` | `Int` |
  | `real`, `double precision` (also `Infinity`, `-Infinity`, `NaN`) | `Float` |
  | `boolean` | `Bool` (a real boolean, so it reads back as `Bool`) |
  | `bytea` | `Blob` |
  | NULL | `Null` |
  | `text`, `varchar`, `char`, `name`, and the rest: `numeric`, `date`, `timestamp`, `uuid`, `json`, arrays | `Text` |

  A `Text` parameter goes into a column of any of those types (`'12.50'` into `numeric`, `'2024-02-29'` into `date`).
  The server takes the type of a placeholder from its context (`where id = ?` takes the type of `id`). Where the
  context gives none (`select ? is null`) it is an error (`42P18`): cast it, `?::int` or `cast(? as text)`. A cast
  also picks a type where several fit, as in `?::numeric`.
- The placeholder `?` is rewritten to `$n` outside string literals (`'?'`, `E'...'`), quoted identifiers (`"a?"`),
  dollar quotes (`$$ ? $$`) and comments (`-- ?`, nested `/* ? */`). The operators `?`, `?|` and `?&` of `jsonb` are
  not available: use `jsonb_exists`, `jsonb_exists_any` and `jsonb_exists_all`. Write `?`, never `$1`.
- Errors: an engine failure is `postgres error <SQLSTATE>: <primary message>`, as in
  `postgres error 23505: duplicate key value violates unique constraint "users_name_key"` (`42601` syntax, `23505`
  unique, `23503` foreign key, `23502` not null, `42P01` missing table; the full list is in the PostgreSQL manual,
  appendix A). The message is the server's, in the language of its `lc_messages`. A failure without a SQLSTATE (the
  connection dropped) is `postgres error: <message>`.
- `execute` counts the rows of `INSERT`, `UPDATE`, `DELETE` and `MERGE` (also with `RETURNING`); other statements,
  `SELECT` too, give 0.
- `COPY` is not supported: the server starts the copy before the adapter sees it, so the adapter ends it, reads the
  rest of the results (for `COPY ... TO STDOUT` all the data, which can take long for a big table) and gives
  `postgres error: COPY is not supported`. The connection keeps working.
- `transaction` starts with `BEGIN`. Transactions do not nest (`postgres error 25001`; PostgreSQL itself only warns).
  A statement that fails inside a transaction aborts it: a `COMMIT` after that does not fail on the server (it rolls
  back), so this package turns it into `postgres error 25P02`, and `transaction` gives that error.
- The end of the task that opened the connection closes it (the connection is a native resource freed by `PQfinish`),
  or call `Db.close` earlier. Using a connection after `close` is `postgres error: the connection is closed`.
- `open`, `query` and `execute` run on the compute pool: other tasks keep running while the server works.
- Use a connection from one task at a time, and never `close` it while a query runs. If a task is cancelled, or
  `Task.await(task, ms)` times out, while a query is running, the libpq call still runs to its end and its result is
  dropped, so the connection may be left in the middle of a query (and that one result is not freed). Close that
  connection and open a new one.

## MySQL and MariaDB

```ruby
conn = try Db.open("mysql://user:pass@127.0.0.1:3306/app")
rows = try Db.query(conn, "select id, name from users where age > ?", [Db.Value.Int(28)])
```

- The url is `mysql://user:password@host:port/database?parameter=value` (`mariadb://` is the same). The user, the
  password and the database are percent-decoded, so write `p%40ss` for `p@ss`. The host is required, the port is 3306
  by default, an IPv6 host is `[::1]`, and the database is optional. Use an address: the host `localhost` makes
  the client library use the local socket, which is not where a container listens. The parameters are
  `connect_timeout` (seconds; set it, since an unreachable host otherwise waits as long as the operating system
  does) and `ssl_mode` (below); any other parameter is an error. A bad url is `mysql error: <message>` and the message
  never repeats a part of the url. A server that does not accept the connection is `mysql error <code>: <message>`
  with the code of the client library or the server (`2002` unreachable, `1045` access denied, `1049` unknown
  database); the messages of the library name the user and the host but never the password.
- The adapter goes through MariaDB Connector/C (`libmariadb.so.3`), which talks to MySQL and MariaDB servers. It is
  tested with MariaDB 11 and MySQL 8.4. The offsets of its `MYSQL_BIND` and `MYSQL_FIELD` structs and the numbers of
  its options are those of Connector/C 3.x, so `libmysqlclient` cannot take its place.
- Every statement with parameters is prepared (`mysql_stmt_*`): the sql is sent with its `?` placeholders and the
  values are bound as
  `BIGINT`, `DOUBLE`, strings and blobs. The `?` of a string, a quoted identifier or a comment is not a placeholder:
  the server decides, as always. A NUL in the sql or in a text is a bad input.
- Types, read and written. A `float` column has 32 bits, so `0.1` reads back as `0.10000000149011612`: use `double`
  for exact decimals. A statement the server does not prepare comes back through the text protocol, where it reads
  `0.1`.

  | MySQL | `Value` |
  |---|---|
  | `tinyint`, `smallint`, `mediumint`, `int`, `bigint`, `year`, and the `unsigned` ones that fit an `Int` | `Int` |
  | `float`, `double` | `Float`; no `NaN` or infinity (a parameter that is one is a bad input) |
  | `boolean` (a `tinyint(1)`) | `Int`: a `Bool` is stored as 1 or 0 and reads back as `Int` |
  | `binary`, `varbinary`, the blobs, `bit`, `geometry` | `Blob` |
  | NULL | `Null` |
  | `char`, `varchar`, the texts, `json`, `enum`, `set` | `Text` |
  | the rest: `decimal`, `date`, `time`, `datetime`, `timestamp`, a `bigint unsigned` past `Int` | `Text` |

  A `Text` parameter goes into a column of any of those types (`'12.50'` into `decimal`, `'2024-02-29'` into
  `date`). A `datetime` reads as `2024-02-29 13:14:15`. The connection character set is `utf8mb4`.
- `execute` counts the rows of `INSERT`, `UPDATE`, `DELETE` and `REPLACE` that match (an `UPDATE` that sets a column
  to the value it has counts the row, as in the other adapters); other statements, `SELECT` too, give 0.
  `INSERT ... ON DUPLICATE KEY UPDATE` over an existing row and `REPLACE` over an existing row count 2 (MySQL deletes
  and inserts, or inserts and updates), a new row counts 1. `CALL` gives its first result set; the others are
  dropped. The `use` statement changes the database of the connection for good.
- MySQL does not prepare some statements (`START TRANSACTION`, `BEGIN`, `SAVEPOINT`, `USE`, `LOCK TABLES`,
  `CHECK TABLE`, `SHOW WARNINGS` on MySQL 8.4; MariaDB prepares more of them). When the server answers `1295` to a
  statement with no placeholder, the adapter sends it through the text protocol (`mysql_real_query`) and reads the
  result with the same types. A statement with parameters never does: its values are always bound. A text-protocol
  float with an exponent (`1e-7`) that does not read as a decimal stays `Text`.
- The sql is one statement. The scanner knows the strings, the backticks, the `-- `, `#` and `/* */` comments of
  MySQL, and refuses a second statement before the server sees it. So a `CREATE PROCEDURE` with a `BEGIN ... END`
  body of several statements cannot be sent: create it with the `mysql` client. The scanner assumes backslash
  escapes in strings: with the `NO_BACKSLASH_ESCAPES` sql mode it may refuse valid sql (a string that ends with a
  backslash).
- `transaction` starts with `START TRANSACTION`. Transactions do not nest: MySQL would silently commit the open one at
  a `BEGIN`, so `BEGIN` and `START TRANSACTION` fail with `mysql error: a transaction is already in progress` while
  the server reports one open. A statement that fails inside a transaction does not abort it (a `COMMIT` after it
  commits the statements that worked; `Db.transaction` rolls back because the block returned the error). A DDL
  statement (`CREATE TABLE`, `DROP TABLE`, ...) commits the transaction before it runs, as in MySQL itself; `CREATE
  TEMPORARY TABLE` does not.
- TLS: `?ssl_mode=required` uses TLS and accepts any certificate (it hides the traffic, it does not prove the server).
  `?ssl_mode=verify&ssl_ca=PATH` uses TLS and checks the certificate of the server against the PEM file of authorities
  at `PATH` (percent-encode the path if needed): libmariadb checks nothing when it has no authority file, so `verify`
  without `ssl_ca`, and `ssl_ca` without `verify`, are errors. A server whose certificate those authorities do not
  vouch for fails with `mysql error 2026`. Without `ssl_mode` the library decides: Connector/C 3.4 (Debian 13)
  connected without TLS to MariaDB 11 and MySQL 8.4. Use `verify` over any network you do not trust. A client
  certificate is not supported. The path of `ssl_ca` is read by the process, so a relative path is relative to its
  working directory. Verifying a good certificate is not tested here: the test servers have self-signed ones.
- `LOAD DATA LOCAL INFILE` is off, so a server cannot ask for a file of this machine.
- The end of the task does not close the connection (unlike SQLite and PostgreSQL): call `Db.close`. The server
  session and the locks of an open transaction stay until then. Using a connection after `close` is `mysql error:
  the connection is closed`.
- `open`, `query` and `execute` wait for the server on the compute pool: other tasks keep running.
- Use a connection from one task at a time, and never `close` it while a query runs. If a task is cancelled, or
  `Task.await(task, ms)` times out, while a query is running, the call still runs to its end and its result is
  dropped: close that connection and open a new one.

## Development

The behavior of the API is written as Gherkin scenarios in `specs/`, run by `agentica test`; read them as the
specification. `specs/*.feature` hold the contract that every adapter meets (open and close, query and execute,
value round trips, transactions, errors), each scenario an outline with one row per adapter that the behavior
applies to, and `sqlite.feature`, `postgres.feature` and `mysql.feature` hold what only one adapter promises.
`specs/steps.agc` has the steps. Only the edge cases of the pure helpers, the scanners and the url reader, have unit
tests (`test/postgres_sql_test.agc`, `test/mysql_sql_test.agc`, `test/mysql_url_test.agc`); a feature repeats one of
them only as the single integration row per adapter (a bad url, a NUL in the sql).

```sh
for file in *.agc specs/*.agc test/*.agc; do agentica check "$file"; done
agentica test
```

`agentica test` finds `specs/steps.agc` by itself. The PostgreSQL scenarios need a server: set
`AGENTICA_DB_POSTGRES_URL`; the MySQL ones set `AGENTICA_DB_MYSQL_URL` (`mysql://root:pw@127.0.0.1:3306/mysql`).
CI always does; without them the scenarios fail. With no server, run only the SQLite scenarios, which have
"on sqlite" in their name: `agentica test --only "on sqlite"`. See `AGENTS.md`.

License: Apache-2.0.
