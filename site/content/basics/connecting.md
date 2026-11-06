---
title: Connecting
weight: 1
description: Open a connection from a url, the scheme of each database, and close it.
aliases:
  - /guide/connecting/
---

`Db.open(url)` gives a `Result[Db.Connection]`. The scheme of the url picks the database.

| Url | Database |
|---|---|
| `sqlite:PATH` or `sqlite:PATH?journal_mode=delete` | the SQLite file at `PATH`, with its [settings](/databases/sqlite/#settings) |
| `sqlite::memory:` | a private in-memory SQLite database |
| `postgres://user:pass@host:5432/app` or `postgresql://...` | PostgreSQL (a libpq url) |
| `mysql://user:pass@host:3306/app` or `mariadb://...` | MySQL or MariaDB |

`sqlite://` with two slashes is refused: write `sqlite:PATH`. Any other scheme is `db error: unsupported database url scheme ...`, and the message names only the scheme, because a url can hold a password.

```agentica
import Db from "pkg/db/db"

def main() -> Void
  case Db.open("oracle://app")
    ok(_) -> puts("open")
    error(message) -> puts(message)
  end
end
```

```output
db error: unsupported database url scheme oracle: expected sqlite:PATH, sqlite::memory:, postgres:// or mysql://
```

## One function per database

When you know the database, call its function. They take the same arguments as `open` would, without the scheme rules.

| Function | Gives |
|---|---|
| `Db.open_sqlite(path)` | `Result[Connection]`, a path or `:memory:` |
| `Db.open_postgres(url)` | `Result[Connection]`, a libpq url or a conninfo string such as `host=localhost dbname=app` |
| `Db.open_mysql(url)` | `Result[Connection]`, a `mysql://` or `mariadb://` url |

The pages of [SQLite](/databases/sqlite/), [PostgreSQL](/databases/postgresql/) and [MySQL](/databases/mysql/) have the url parameters of each.

## Checking a connection

`Db.in_transaction?(conn)` says whether a transaction is open, and `Db.healthy?(conn)` whether the connection works. The first asks the connection for its state and sends nothing to the server. The second may send a cheap statement or a ping. A closed connection is not in a transaction and not healthy; neither function stops the program. A pool uses them to roll back and to check a connection it takes back.

## Errors

An error is a `Result` failure: `error(message)`. There are two shapes. An engine failure is `<adapter> error <code>: <message>`, as in `sqlite error 1: near "from": syntax error`. A bad input, refused before the statement runs, is `<adapter> error: <message>`. A failure of `Db` itself, such as an unknown url, is `db error: <message>`. A bad input is an error and never stops the program.

The code of PostgreSQL is its five character SQLSTATE. The code of MySQL is the number of the server or of the client library.

## Closing

`Db.close(conn)` ends the connection, and closing twice is safe. The end of the task that opened the connection closes it too, and so does the end of `main`. The one exception is a SQLite url with `statement_cache` above 0: the connection then keeps prepared statements that only `Db.close` finalizes, so close it yourself (see [SQLite](/databases/sqlite/)).

A connection belongs to the task that opened it, and one task uses it at a time. Open it in the task that keeps it (usually `main`), or hand it over with `Task.spawn_owning(&f, conn)`: a connection opened in a task that ends comes back closed. Using a connection after `close` is an error (`postgres error: the connection is closed`), except for SQLite, where it is a runtime error (`RUNTIME-NATIVE-CLOSED`).
