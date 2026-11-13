---
title: Timeouts
weight: 2
description: Limit the time of a statement with timeout_ms, as a url parameter or per call, and what each database does when it runs over.
---

`timeout_ms` bounds the time of a statement, in milliseconds. A statement that runs longer fails with an `error`, and the connection works after it, except on MySQL and MariaDB, where a `DO`, an `INSERT`, a `SLEEP()` or the client backstop (see below) can end the connection. Without a limit no statement is bounded, though on SQLite a wait for a lock still ends after `busy_timeout` (5000 ms by default).

## Set the limit

| Where | Does |
|---|---|
| the `timeout_ms` parameter of the url (`sqlite:app.db?timeout_ms=2000`) | the limit of every statement of the connection; none by default |
| the `timeout_ms` argument of `Db.query` and `Db.execute` | the limit of this call |
| `Db.CONNECTION_DEFAULT` (`-1`) | the default of the argument: the call takes the limit of the connection |
| `Db.NO_TIMEOUT` (`0`) | the call has no limit of its own |

`Db.NO_TIMEOUT` lifts the limit of the url, but not one that the server sets for the session when the url has none. On MySQL and MariaDB, a connection opened with a url `timeout_ms` still cuts the call at the client backstop (see below).

`timeout_ms` is a parameter that this package reads itself. libpq never sees it, in a url or in a conninfo string (`host=localhost timeout_ms=2000`).

## Tell a timeout

`Db.timeout?(e.message)` says whether the failure message is the one of a statement that ran over its `timeout_ms`. It knows the four messages in the table below.

```agentica
import Db from "pkg/db/db"

def run() -> Result[Void]
  conn = try Db.open("sqlite::memory:?timeout_ms=2000")
  try Db.query(conn, "select 1", [])
  try Db.query(conn, "select 1", [], 500)
  try Db.query(conn, "select 1", [], Db.NO_TIMEOUT)
  Db.close(conn)
  return ok()
end

def main() -> Void
  case run()
    ok(_) -> puts("done")
    error(e) ->
      if Db.timeout?(e.message)
        puts("timed out")
      else
        puts(e.message)
      end
  end
end
```

```output
done
```

## What each database does

| Database | How the limit works | The failure |
|---|---|---|
| SQLite | a watchdog task calls `sqlite3_interrupt` when the time is over | `sqlite error 9: interrupted` |
| PostgreSQL | sets the `statement_timeout` of the session | `postgres error 57014: canceling statement due to statement timeout` |
| MySQL | sets `max_execution_time` (the adapter tells MySQL from MariaDB by the version of the server at `open`), which limits only a `SELECT` | `mysql error 3024` |
| MariaDB | sets `max_statement_time`, which limits every statement | `mysql error 1969` |

- SQLite: the wait for a lock (`busy_timeout`) ends at the same deadline and fails the same way. SQLite rolls back the whole transaction when it interrupts a write inside one. A read that times out leaves the transaction open.
- PostgreSQL: a call with its own limit sets `statement_timeout` before the statement and puts the connection's back after it, which costs two more round trips. It costs none when the call asks for the limit the connection has, or when the statement is `BEGIN`, `COMMIT`, `ROLLBACK` or another that starts, ends or steps inside a transaction.
- MySQL: a `DO` or an `INSERT` is not bounded.
- MySQL and MariaDB: an interrupted `SLEEP()` ends early without an error (`select sleep(5)` on MySQL 8.4, `DO SLEEP(20)` on MariaDB).
- MySQL and MariaDB: a url with `timeout_ms` also sets the client read and write timeouts, in whole seconds, to the limit plus 10 seconds. That is the backstop for what the server does not time. A statement that hits it fails with `mysql error 2013: Lost connection to server during query`, and the connection is gone. The backstop is fixed at `open`, so a call that asks for a longer limit than the url's, `Db.NO_TIMEOUT` included, is cut at it: open with the longer `timeout_ms` for such calls.

The details are in the Timeouts sections of [SQLite](/databases/sqlite/#timeouts), [PostgreSQL](/databases/postgresql/#timeouts) and [MySQL and MariaDB](/databases/mysql/#timeouts).
