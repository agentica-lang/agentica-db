---
title: Connecting
weight: 1
description: Open a connection from a url, the scheme of each database, and close it.
aliases:
  - /guide/connecting/
---

`Db.open(url, drivers)` gives a `Result[Db.Connection]`. `drivers` are the databases the program uses, and the scheme of the url picks one of them.

| Url | Database | Driver |
|---|---|---|
| `sqlite:PATH` or `sqlite:PATH?journal_mode=delete` | the SQLite file at `PATH`, with its [settings](/databases/sqlite/#settings) | `Sqlite.driver()` of `pkg/db/sqlite` |
| `sqlite::memory:` | a private in-memory SQLite database | `Sqlite.driver()` |
| `postgres://user:pass@host:5432/app` or `postgresql://...` | PostgreSQL (a libpq url) | `Postgres.driver()` of `pkg/db/postgres` |
| `mysql://user:pass@host:3306/app` or `mariadb://...` | MySQL or MariaDB | `Mysql.driver()` of `pkg/db/mysql` |

`sqlite://` with two slashes is refused: write `sqlite:PATH`. A url of a database whose driver the program did not pass is `db error: no driver for the url scheme ...`, and any other scheme is `db error: unsupported database url scheme ...`. The message names only the scheme, because a url can hold a password.

```agentica
import Db from "pkg/db/db"
import Sqlite from "pkg/db/sqlite"

def main() -> Void
  case Db.open("oracle://app", [Sqlite.driver()])
    ok(_) -> puts("open")
    error(message) -> puts(message)
  end
end
```

```output
db error: unsupported database url scheme oracle: expected sqlite:
```

## Drivers

Import only the drivers the program uses. A program builds the native module of each driver it imports with the C compiler at its first run: SQLite and PostgreSQL have one, so an app that imports only `Sqlite` never builds the PostgreSQL one. An app that picks its database from its url at run time passes every driver it may need:

```ruby
conn = try Db.open(url, [Sqlite.driver(), Postgres.driver()])
```

When you know the database, its module opens it with no scheme rules:

| Function | Gives |
|---|---|
| `Sqlite.open(path)` | `Result[Db.Connection]`, a path or `:memory:` |
| `Postgres.open(url)` | `Result[Db.Connection]`, a libpq url or a conninfo string such as `host=localhost dbname=app` |
| `Mysql.open(url)` | `Result[Db.Connection]`, a `mysql://` or `mariadb://` url |

The pages of [SQLite](/databases/sqlite/), [PostgreSQL](/databases/postgresql/) and [MySQL](/databases/mysql/) have the url parameters of each.

## Checking a connection

`Db.in_transaction?(conn)` says whether a transaction is open, and `Db.healthy?(conn)` whether the connection works. The first asks the connection for its state and sends nothing to the server. The second may send a cheap statement or a ping. A closed connection is not in a transaction and not healthy; neither function stops the program. A pool uses them to roll back and to check a connection it takes back.

## Errors

An error is a `Result` failure: `error(message)`, an `Error` whose `message` is the text below. There are two shapes. An engine failure is `<adapter> error <code>: <message>`, as in `sqlite error 1: near "from": syntax error`. A bad input, refused before the statement runs, is `<adapter> error: <message>`. A failure of `Db` itself, such as an unknown url, is `db error: <message>`. A bad input is an error and never stops the program.

The code of PostgreSQL is its five character SQLSTATE. The code of MySQL is the number of the server or of the client library.

## Closing

`Db.close(conn)` ends the connection, and closing twice is safe. The end of the task that opened the connection closes it too, and so does the end of `main`.

A connection belongs to the task that opened it, and one task uses it at a time. Open it in the task that keeps it (usually `main`): a connection opened in a task that ends comes back closed. To share connections between tasks, use a [pool](/production/pooling/). Using a connection after `close` is an error (`postgres error: the connection is closed`), except for SQLite, where it is a runtime error (`RUNTIME-NATIVE-CLOSED`).
