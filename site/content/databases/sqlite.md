---
title: SQLite
weight: 1
description: Open a SQLite file or an in-memory database, the settings of a connection, and what is special about SQLite.
aliases:
  - /guide/sqlite/
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
| `timeout_ms` | milliseconds, the limit of each statement | none |
| `synchronous` | `off`, `normal`, `full`, `extra` | `normal` in WAL, SQLite's `full` in other modes |
| `mmap_size` | bytes, 0 or more | `134217728` (128 MiB) |
| `cache_size` | pages, or KiB when negative | `2000` pages |
| `journal_size_limit` | bytes, negative for no limit | `67108864` (64 MiB) |
| `statement_cache` | prepared statements kept per connection, 0 to 10000 | `0` for `Db.open`, `128` in a `DbPool` |
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
- `synchronous=normal` is the default in WAL, as in Rails 8: a commit does not wait for the WAL file to reach the disk, only a checkpoint does. After a power loss or an operating system crash, the last commits can be lost; the database is never corrupted. A crash of the program alone loses nothing, since the data is in the operating system's cache. Use `?synchronous=full` to sync the WAL file at each commit, at the cost of a disk flush per transaction (`extra` is the same in WAL; it only adds a directory sync in the rollback modes). In the other journal modes the default stays SQLite's own `full`. `off` hands everything to the operating system and can corrupt the database on a power loss.
- `mmap_size`, `cache_size` and `journal_size_limit` are the values of Rails 8, and SQLite's own are `0` (no memory-mapped reads), `-2000` (2000 KiB; a positive number is a count of pages, 4096 bytes each by default, so the default here is about 8 MiB) and `-1` (the `-wal` file keeps its size after a checkpoint). `mmap_size` is capped by the limit that SQLite was built with, and a smaller build value is not an error. They are set on every connection, also on an in-memory database and on a read-only file, which accept them.
- A database that cannot use WAL (a network file system) is an error, not a silent fallback. An in-memory database always stays in `memory` mode and is accepted. A database that cannot be written (a read-only file, or `mode=ro` in a `file:` name) keeps the mode it has when the url did not name one; `journal_mode=wal` on it is `sqlite error 8: attempt to write a readonly database`. A plain path that cannot take WAL is an error, so that a web app stops at startup and does not run in another mode; a `file:` name is more forgiving, since its own parameters can rule WAL out.
- `foreign_keys=on` makes SQLite check foreign keys. SQLite itself leaves them off.
- `busy_timeout` is how long each `prepare` or step of a statement waits for a lock held by another connection before it fails with `sqlite error 5: database is locked` (`sqlite error 6: database table is locked` for a table of a shared cache). The wait is per call, so a statement that waits again at a later step can wait up to `busy_timeout` once more. The task sleeps a few milliseconds and tries again, so the other tasks, the one that holds the lock among them, keep running; `0` fails at once. SQLite's own busy timeout stays 0 (`PRAGMA busy_timeout` shows 0): its wait would hold one thread of the pool that runs the SQLite calls, which has one thread per scheduler, and a few schedulers would all wait while the lock holder could not finish. Running `PRAGMA busy_timeout = N` yourself brings that blocking wait back. A `file:` name always waits 5000 ms.
- A transaction that starts with a plain `BEGIN`, reads, and then writes does not wait for a lock: if another connection holds the write lock, the write fails at once with `sqlite error 5: database is locked`, as in SQLite itself. In `journal_mode=delete` waiting would stall both connections: the other one's `COMMIT` waits for this transaction's read lock until `busy_timeout` ends, and the write then fails all the same. In WAL mode there is no such stall (a commit does not wait for readers); the write is refused at once there too, since waiting would fail if the other connection commits: the snapshot of the reader is then stale. Roll back and start again, or use `Db.transaction`, which begins with `BEGIN IMMEDIATE` and takes the write lock first (as `default_transaction_mode: immediate` does in Rails). The refusal needs SQLite 3.34 or later; an older library waits as before.
- `statement_cache` is how many prepared statements a connection keeps. A statement is kept by its sql text: the next `query` or `execute` with the same text skips the prepare (a hop to the thread pool that runs the SQLite calls, and the parse) and only binds the new values. When the cache is full, the statement used least recently is finalized. A statement that fails to prepare, and one whose sql is longer than 16 KiB, is not kept. Put the values in `?` parameters, never in the text, or every call is a new sql and fills the cache with statements that run once. After a schema change (`alter table`, here or from another connection) a kept `select *` reads the columns the table has now. A name that starts with `file:` has the default too (see [SQLite URIs](#sqlite-uris)).
- The default of `statement_cache` is `0` for a connection of `Db.open` and `128` for the connections of a `DbPool`. SQLite keeps a closed connection, with its file open, its page cache and its WAL file, for as long as one of its statements is not finalized, and only `Db.close` finalizes the kept ones: the end of the task that opened a connection closes the handle and nothing else. So a connection that relies on that end must keep none, and a pool, which always closes its connections, can. If you set `statement_cache` above 0 on a connection you open yourself, close it with `Db.close`.
- Never close a connection while another task runs a statement on it. `Db.close` waits for the step that is running, which blocks the thread that runs it, and the task that wakes up finds the connection closed and fails with `sqlite error: the connection was closed while the statement ran`. A pool closes a connection only after its lease is over and the statement interrupted.
- `fts5=required` makes `open` fail with `sqlite error: this SQLite was built without FTS5 (fts5=required)` when the system library has no FTS5, instead of failing later at the first `create virtual table`.
- Names and values are lowercase and case-sensitive (`journal_mode=WAL` is an error, although SQLite itself takes it), and a value is not percent-decoded. A repeated name keeps its last value. A parameter that is not in the table, an empty one (`?&x=1`), one without `=` or a value that is not allowed is `sqlite error: ...`.
- `sqlite:app.db?journal_mode=delete&foreign_keys=off&synchronous=full&mmap_size=0&cache_size=-2000&journal_size_limit=-1` is SQLite's own behavior before these defaults.

### Timeouts

`timeout_ms` (a url parameter, or the `timeout_ms` argument of `Db.query` and `Db.execute`: `-1` takes the connection's, `0` has none) ends a statement that runs longer. A watchdog task calls `sqlite3_interrupt` when the time is over, and the statement fails with `sqlite error 9: interrupted`; `Db.timeout?(message)` tells it from other failures. The connection works after it. The wait for a lock (`busy_timeout`) ends at the same deadline and fails the same way.

SQLite rolls back the whole transaction when it interrupts a write inside one, the earlier writes of the transaction included: `Db.in_transaction?(conn)` is then `false`. `Db.transaction` sends its `ROLLBACK` only when the transaction is still open, so its error is the timeout alone. A read that times out leaves the transaction open, and so does a statement whose time ran out before its first step: it does not run, so nothing is rolled back.

### SQLite URIs

A name that starts with `file:` is a [SQLite URI](https://www.sqlite.org/uri.html) and goes to SQLite as it is: its `?` parameters belong to SQLite, and the table above does not apply to it. `sqlite:file:app.db?mode=ro` opens read-only, and `sqlite:file::memory:?cache=shared` is an in-memory database that several connections share. The defaults still apply (`foreign_keys` on, WAL tried, and the `synchronous`, `mmap_size`, `cache_size` and `journal_size_limit` of the table: if SQLite will not switch to WAL, for example with `immutable=1`, `nolock=1` or `mode=ro`, the database keeps its mode and `synchronous` stays SQLite's), and to change one, run its `PRAGMA` after `open`, such as `PRAGMA journal_mode = DELETE`, `PRAGMA foreign_keys = OFF` or `PRAGMA synchronous = FULL`.

### A `?` in a path

A `?` always starts the parameters, so a file whose name holds a `?` cannot be opened by name. That includes the Windows extended-length prefix `\\?\C:\...`. Write such a path as a `file:` URI with the `?` as `%3f` (`sqlite:file:C:/dir/a%3fb.db`).

## What to know

- Parameters bind with the type of the `Db.Value`. A `Db.Value.Bool` is stored as 0 or 1 and reads back as `Db.Value.Int`, and NaN is stored as NULL. See [values](/basics/values/).
- A text is bound with its length, so a text with a NUL is stored and read back whole.
- A transaction starts with `BEGIN IMMEDIATE`, which needs write access to the database.
- `execute` gives the rows changed by an `insert`, `update` or `delete`.
- An engine failure is `sqlite error <code>: <message>`, as in `sqlite error 1: near "from": syntax error`. A bad input is `sqlite error: <message>`.
- A connection used after `close` is a runtime error (`RUNTIME-NATIVE-CLOSED`), not an `error` value.
