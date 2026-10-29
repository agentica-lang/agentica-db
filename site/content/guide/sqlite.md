---
title: SQLite
weight: 5
description: Open a SQLite file or an in-memory database, and what is special about SQLite.
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

## What to know

- Parameters bind with the type of the `Db.Value`. A `Db.Value.Bool` is stored as 0 or 1 and reads back as `Db.Value.Int`, and NaN is stored as NULL. See [values](/guide/values/).
- A text is bound with its length, so a text with a NUL is stored and read back whole.
- SQLite keeps its defaults: foreign keys are off until you run `PRAGMA foreign_keys = ON`.
- A transaction starts with `BEGIN IMMEDIATE`, which needs write access to the database.
- `execute` gives the rows changed by an `insert`, `update` or `delete`.
- An engine failure is `sqlite error <code>: <message>`, as in `sqlite error 1: near "from": syntax error`. A bad input is `sqlite error: <message>`.
- A connection used after `close` is a runtime error (`RUNTIME-NATIVE-CLOSED`), not an `error` value.
