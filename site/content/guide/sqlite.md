---
title: SQLite
weight: 5
description: Open a SQLite file or an in-memory database, the settings of a connection, and what is special about SQLite.
---

The SQLite adapter uses the system `libsqlite3`. It needs no server, so it is also the database for tests.

```agentica
import Db from "pkg/db/db"

def main() -> Void
  file = Db.open("sqlite:app.db")
  memory = Db.open("sqlite::memory:")
  puts(file.ok?)
  puts(memory.ok?)
  Db.close(memory.unwrap!)
  Db.close(file.unwrap!)
end
```

```output
true
true
```

`sqlite:PATH` opens the file at `PATH` and creates it when it does not exist. `sqlite::memory:` is a private database that lives as long as its connection: each connection to `:memory:` has its own.

## Settings

A connection is set up for a web app. The parameters after a `?` change the settings:

| Parameter | Values | Default |
|---|---|---|
| `journal_mode` | `wal`, `delete`, `truncate`, `persist`, `memory`, `off` | `wal` |
| `foreign_keys` | `on`, `off` | `on` |
| `busy_timeout` | milliseconds, 0 or more | `5000` |
| `fts5` | `required` | not checked |

```agentica
import Db from "pkg/db/db"

def main() -> Void
  case Db.open("sqlite::memory:?fts5=required")
    error(message) -> puts(message)
    ok(conn) ->
      created = Db.execute(conn, "create virtual table notes using fts5(body, tokenize = porter)", [])
      puts(created.ok?)
      Db.close(conn)
  end
end
```

```output
true
```

- `journal_mode=wal` lets readers run while one connection writes, which a web server needs. The mode is stored in the database file, so the file stays in WAL mode for any later connection. While a connection is open, the file has `-wal` and `-shm` files beside it, and recent writes may live only in `-wal`: copying the `.db` file alone then can lose data. Close the connection first, or back up with SQLite's backup API (`VACUUM INTO 'copy.db'` also works).
- A database that cannot use WAL (a network file system) is an error, not a silent fallback. An in-memory database always stays in `memory` mode and is accepted. A database that cannot be written (a read-only file, or `mode=ro` in a `file:` name) keeps the mode it has when the url did not name one; `journal_mode=wal` on it is `sqlite error 8: attempt to write a readonly database`. A plain path that cannot take WAL is an error, so that a web app stops at startup and does not run in another mode; a `file:` name is more forgiving, since its own parameters can rule WAL out.
- `foreign_keys=on` makes SQLite check foreign keys. SQLite itself leaves them off.
- `busy_timeout` is how long each `prepare` or step of a statement waits for a lock held by another connection before it fails with `sqlite error 5: database is locked` (`sqlite error 6: database table is locked` for a table of a shared cache). The wait is per call, so a statement that waits again at a later step can wait up to `busy_timeout` once more. The task sleeps a few milliseconds and tries again, so the other tasks, the one that holds the lock among them, keep running; `0` fails at once. SQLite's own busy timeout stays 0 (`PRAGMA busy_timeout` shows 0): its wait would hold one thread of the pool that runs the SQLite calls, which has one thread per scheduler, and a few schedulers would all wait while the lock holder could not finish. Running `PRAGMA busy_timeout = N` yourself brings that blocking wait back. A `file:` name always waits 5000 ms.
- A transaction that starts with a plain `BEGIN`, reads, and then writes can wait in vain: if another connection holds the write lock, the write is refused until it commits, and in `journal_mode=delete` both connections can stall until `busy_timeout` ends (in WAL mode the write fails with `sqlite error 5` as soon as the other connection commits, since the snapshot of the reader is stale). Use `Db.transaction`, which begins with `BEGIN IMMEDIATE` and takes the write lock first.
- `fts5=required` makes `open` fail with `sqlite error: this SQLite was built without FTS5 (fts5=required)` when the system library has no FTS5, instead of failing later at the first `create virtual table`.
- Names and values are lowercase and case-sensitive (`journal_mode=WAL` is an error, although SQLite itself takes it), and a value is not percent-decoded. A repeated name keeps its last value. A parameter that is not in the table, an empty one (`?&x=1`), one without `=` or a value that is not allowed is `sqlite error: ...`.
- `sqlite:app.db?journal_mode=delete&foreign_keys=off` is SQLite's own behavior before these defaults.

### SQLite URIs

A name that starts with `file:` is a [SQLite URI](https://www.sqlite.org/uri.html) and goes to SQLite as it is: its `?` parameters belong to SQLite, and the table above does not apply to it. `sqlite:file:app.db?mode=ro` opens read-only, and `sqlite:file::memory:?cache=shared` is an in-memory database that several connections share. The defaults still apply (`foreign_keys` on, and WAL tried: if SQLite will not switch, for example with `immutable=1`, `nolock=1` or `mode=ro`, the database keeps its mode), and to change one, run `PRAGMA journal_mode = DELETE` or `PRAGMA foreign_keys = OFF` after `open`.

### A `?` in a path

A `?` always starts the parameters, so a file whose name holds a `?` cannot be opened by name. That includes the Windows extended-length prefix `\\?\C:\...`. Write such a path as a `file:` URI with the `?` as `%3f` (`sqlite:file:C:/dir/a%3fb.db`).

## What to know

- Parameters bind with the type of the `Db.Value`. A `Db.Value.Bool` is stored as 0 or 1 and reads back as `Db.Value.Int`, and NaN is stored as NULL. See [values](/guide/values/).
- A text is bound with its length, so a text with a NUL is stored and read back whole.
- A transaction starts with `BEGIN IMMEDIATE`, which needs write access to the database.
- `execute` gives the rows changed by an `insert`, `update` or `delete`.
- An engine failure is `sqlite error <code>: <message>`, as in `sqlite error 1: near "from": syntax error`. A bad input is `sqlite error: <message>`.
- A connection used after `close` is a runtime error (`RUNTIME-NATIVE-CLOSED`), not an `error` value.
