---
title: PostgreSQL
weight: 2
description: Open a PostgreSQL database through libpq, the types, errors and what is not supported.
aliases:
  - /guide/postgresql/
---

The PostgreSQL adapter uses the system `libpq` (PostgreSQL 12 or later). `open` gives an `error` when the library is missing.

```agentica
import Db from "pkg/db/db"

def run() -> Result[Void]
  conn = try Db.open("postgres://user:pass@localhost:5432/app?sslmode=disable&connect_timeout=5")
  rows = try Db.query(conn, "select id, name from users where age > ?::int", [Db.Value.Int(28)])
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

## The url

The url goes to libpq as it is, so every libpq parameter works (`sslmode`, `connect_timeout`, `application_name`, `options`). A conninfo string such as `host=localhost dbname=app` works with `Db.open_postgres`. Set `connect_timeout` (in seconds): without it, an unreachable host waits as long as the operating system does. The client encoding is always UTF8.

This package reads four parameters itself, which libpq never sees, in a url or in a conninfo string:

| Parameter | What it sets | Default |
|---|---|---|
| `timeout_ms` | the `statement_timeout` of the session (see [timeouts](#timeouts)) | none |
| `statement_cache` | prepared statements kept per connection by the native driver, 0 to 10000 | `100` |
| `batch_rows` | rows that one call of the native driver gives, 1 to 1000 | `100` |
| `batch_bytes` | bytes of values that one call of the native driver gives, about, 1 to 262144 | `262144` |

A value that is not a whole number, or is out of its range, is `postgres error: the url <name> ...`.

A connection that cannot open, or a url libpq cannot parse, is `postgres error: <libpq message>`. For a url libpq cannot parse, its message may quote the url, password included: do not log it blindly.

## Types

Parameters travel as text, and the server infers their types from the sql.

| PostgreSQL | `Db.Value` |
|---|---|
| `smallint`, `integer`, `bigint` | `Int` |
| `real`, `double precision` (also `Infinity`, `-Infinity`, `NaN`) | `Float` |
| `boolean` | `Bool` |
| `bytea` | `Blob` |
| NULL | `Null` |
| `text`, `varchar`, `char`, `name`, and the rest: `numeric`, `date`, `timestamp`, `uuid`, `json`, arrays | `Text` |

The server takes the type of a placeholder from its context (`where id = ?` takes the type of `id`). Where the context gives none (`select ? is null`) it is an error (`42P18`): cast it, with `?::int` or `cast(? as text)`.

## Placeholders

Write `?`, never `$1`. The adapter rewrites `?` to `$n` outside string literals, quoted names, dollar quotes and comments. The operators `?`, `?|` and `?&` of `jsonb` are not available: use `jsonb_exists`, `jsonb_exists_any` and `jsonb_exists_all`.

## Errors

An engine failure is `postgres error <SQLSTATE>: <message>`, as in `postgres error 23505: duplicate key value violates unique constraint "users_name_key"`. Common codes are `42601` (syntax), `23505` (unique), `23503` (foreign key), `23502` (not null) and `42P01` (missing table). The message is the server's, in the language of its `lc_messages`. A failure without a SQLSTATE, such as a dropped connection, is `postgres error: <message>`.

## Timeouts

`timeout_ms` sets the `statement_timeout` of the session at `open` (`postgres://...?timeout_ms=2000`; `host=localhost timeout_ms=2000` for a conninfo string). A statement that runs longer fails with `postgres error 57014: canceling statement due to statement timeout`, and the connection works after it; `Db.timeout?(message)` recognizes it. The `timeout_ms` argument of `Db.query` and `Db.execute` sets the limit of one call (`-1` takes the connection's, `0` has none): the adapter sets `statement_timeout` before the statement and puts the connection's back after it, which costs two more round trips, and costs none when the call asks for the limit the connection has or when the statement is `BEGIN`, `COMMIT`, `ROLLBACK` or another that starts, ends or steps inside a transaction (those run under the connection's limit, so a `ROLLBACK` of a failed transaction works). The limit that is put back is the url's, or, when the url has none, the one the server gives the session (a role setting or the `options` of the url). A `SET` statement also runs under the connection's limit. A `SET statement_timeout` you run yourself is undone by the next call that has its own limit, and so is a `SELECT set_config('statement_timeout', ...)`. A `SET LOCAL statement_timeout` is lost the same way: that call's limit replaces it for the rest of the transaction, and the connection's limit is put back, not yours. `timeout_ms=0` lifts the url's limit, but not a server-side one when the url has none. Without `timeout_ms` nothing is bounded.

`Db.in_transaction?(conn)` reads the transaction state libpq keeps (also `true` after a failed statement, until the `ROLLBACK`), and `Db.healthy?(conn)` checks the connection and sends `SELECT 1`. Healthy does not mean that statements run: a connection in a failed transaction is healthy but refuses statements until the `ROLLBACK`, so check `in_transaction?` and roll back before reusing a connection.

## Drivers

Two drivers run the statements, with the same results and errors:

- The native driver is a small C module of the package (`src/db/native/db_postgres.c`) that opens the system libpq itself (`libpq.so.5`; on macOS `libpq.5.dylib` from `DYLD_LIBRARY_PATH`, Homebrew or Postgres.app; on Windows `libpq.dll` next to `agentica.exe` or in the system folder). It keeps libpq in its non-blocking mode: a query sends its statement, parks its task on the socket until the server answers, and reads the rows in short calls of `batch_rows` rows or `batch_bytes` bytes, so it takes no compute call and other tasks run meanwhile. Each connection keeps up to `statement_cache` prepared statements (`agentica_1`, `agentica_2`, ... on the server), keyed by the sql text: a `SELECT`, `INSERT`, `UPDATE`, `DELETE`, `WITH`, `VALUES`, `MERGE` or `TABLE` that ran before is not parsed or planned again, and runs in one round trip; its first run takes two (a prepare, then the run). When the cache is full the statement used least long ago goes, and the server's copies are deallocated 16 at a time, in one round trip, when no transaction is open. A `CREATE`, `ALTER`, `DROP` or `IMPORT` lets the whole cache go, since a cached plan may not fit the new tables, and so does a `DEALLOCATE ALL` or `DISCARD ALL`, which drops the server's copies. A cached statement that the server refuses because another connection changed its table (`0A000`, cached plan must not change result type) or because it was deallocated (`26000`) is prepared again and run once more when no transaction is open; inside one the error stands and fails the transaction, and the next run prepares it again.
- The FFI driver calls libpq through `extern` functions: it sends each statement by its text, waits for the server on the compute pool, and reads the result one value per call. A one-row query costs about twice as much, and a query of 1000 rows about four times.

`open` takes the native driver when its library loads, else the FFI one. Agentica builds the library with the system C compiler like the [SQLite one](/databases/sqlite/#drivers) (no libpq headers are needed). `AGENTICA_DB_POSTGRES_DRIVER=native` makes a missing library an error of `open`, and `AGENTICA_DB_POSTGRES_DRIVER=ffi` always runs the FFI driver.

A prepared statement belongs to the server session. A pooler in transaction mode (PgBouncer before 1.21) gives a client another session for each transaction, where the statement is missing: set `statement_cache=0` there, and the native driver sends each statement by its text, as the FFI one does.

## More

- `execute` counts the rows of `INSERT`, `UPDATE`, `DELETE` and `MERGE`, also with `RETURNING`. Other statements, `SELECT` too, give 0.
- `COPY` is not supported. The adapter ends it and gives `postgres error: COPY is not supported`, and the connection keeps working.
- A transaction starts with `BEGIN`. See [transactions](/basics/transactions/) for the rules.
- Other tasks keep running while the server works: `open` runs on the compute pool, and a query of the native driver waits on the socket (the FFI driver runs it on the compute pool).
- Use a connection from one task at a time, and never close it while a query runs. With the native driver, queries of several tasks on one connection run one after the other, and a task cancelled while its query runs leaves it on the connection: the next query asks the server to cancel it and reads its end first (a cancelled statement in a transaction fails the transaction). With libpq 17 or later that request gives up after 5 seconds; an older libpq waits as long as the system lets a connect wait. With the FFI driver, the libpq call of a cancelled task still runs to its end and its result is dropped: close that connection and open a new one.
