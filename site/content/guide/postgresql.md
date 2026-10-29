---
title: PostgreSQL
weight: 6
description: Open a PostgreSQL database through libpq, the types, errors and what is not supported.
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

## More

- `execute` counts the rows of `INSERT`, `UPDATE`, `DELETE` and `MERGE`, also with `RETURNING`. Other statements, `SELECT` too, give 0.
- `COPY` is not supported. The adapter ends it and gives `postgres error: COPY is not supported`, and the connection keeps working.
- A transaction starts with `BEGIN`. See [transactions](/guide/transactions/) for the rules.
- `open`, `query` and `execute` run on the compute pool, so other tasks keep running while the server works.
- Use a connection from one task at a time, and never close it while a query runs. If a task is cancelled, or `Task.await(task, ms)` times out, while a query runs, the libpq call still runs to its end and its result is dropped. Close that connection and open a new one.
