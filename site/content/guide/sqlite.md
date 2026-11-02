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

- `journal_mode=wal` lets readers run while one connection writes, which a web server needs. The mode is stored in the database file, so the file stays in WAL mode for any later connection. The file has `-wal` and `-shm` files beside it while a connection is open. A database that cannot use WAL (a network file system) is an error, not a silent fallback; an in-memory database always stays in `memory` mode and is accepted.
- `foreign_keys=on` makes SQLite check foreign keys. SQLite itself leaves them off.
- `busy_timeout` is how long a statement waits for a lock held by another connection before it fails with `sqlite error 5: database is locked`.
- `fts5=required` makes `open` fail with `sqlite error: this SQLite was built without FTS5 (fts5=required)` when the system library has no FTS5, instead of failing later at the first `create virtual table`.
- A parameter that is not in the table, or a value that is not allowed, is `sqlite error: ...`. A `?` always starts the parameters, so a file whose name holds a `?` cannot be opened by name.
- `sqlite:app.db?journal_mode=delete&foreign_keys=off` is SQLite's own behavior before these defaults.

## What to know

- Parameters bind with the type of the `Db.Value`. A `Db.Value.Bool` is stored as 0 or 1 and reads back as `Db.Value.Int`, and NaN is stored as NULL. See [values](/guide/values/).
- A text is bound with its length, so a text with a NUL is stored and read back whole.
- A transaction starts with `BEGIN IMMEDIATE`, which needs write access to the database.
- `execute` gives the rows changed by an `insert`, `update` or `delete`.
- An engine failure is `sqlite error <code>: <message>`, as in `sqlite error 1: near "from": syntax error`. A bad input is `sqlite error: <message>`.
- A connection used after `close` is a runtime error (`RUNTIME-NATIVE-CLOSED`), not an `error` value.
