---
title: Connection pool
weight: 1
description: DbPool lends connections to a request one at a time, rolls back what a request leaves open, and replaces a connection that fails.
aliases:
  - /guide/pooling/
---

A web app should not open a connection for each request. `DbPool` (`import DbPool from "pkg/db/db_pool"`) keeps a few connections open and lends one to a block of code at a time, on top of the [generic pool](/production/generic-pool/). The block gets a `Db.Connection`, so `Db`, `Orm` and `Migrate` work in it as always.

```agentica
import Db from "pkg/db/db"
import DbPool from "pkg/db/db_pool"
import Orm from "pkg/db/orm"

struct User
  id: Int = 0
  name: String
end

def main() -> Void
  users = Orm.schema("users", User.codec)
  pool = DbPool.start(DbPool.Options(url: "sqlite::memory:")).unwrap!
  setup = DbPool.with(pool) do |conn|
    try Db.execute(conn, "create table users (id integer primary key, name text not null)", [])
    try Db.execute(conn, "insert into users (name) values (?)", [Db.Value.Text("Ana")])
    return ok()
  end

  setup.unwrap!
  found = DbPool.with(pool) do |conn| Orm.find(conn, users, Db.Value.Int(1)) end
  puts(found)
  DbPool.close(pool, 1000)
end
```

```output
ok(some(User(id: 1, name: "Ana")))
```

Start the pool once, in a task that lives as long as it does, such as `main`: it opens the connections in that task, which owns them, and they close when it ends. Hand the `pool` value to the tasks that serve requests. In a web handler, one `DbPool.with` is one request: `with` waits in line for a connection, runs the block, and gives the connection back.

## Options

`DbPool.start(DbPool.Options(url: ...))` opens `size` connections at once, so a wrong url or a database that is down fails `start`, not the first request. The fields besides `url`:

- `size` (0): how many connections. 0 takes the size of the database: 4 for SQLite, 10 for PostgreSQL and MySQL or MariaDB. A private in-memory SQLite database (`sqlite::memory:`, `sqlite:file::memory:` or a `file:` name with `mode=memory`) has one connection, and a `size` or `max_overflow` that asks for more is refused with `db error: a pool of a private in-memory database can have one connection only` (each connection would be an empty database of its own). With `cache=shared` in the name (`sqlite:file:app?mode=memory&cache=shared`) every connection sees one database, and the size is free.
- `max_overflow` (0): in a spike, up to this many connections more are opened, so `size + max_overflow` is the most there are.
- `overflow_idle_ms` (1000): an overflow connection that nobody needs is closed after this long.
- `checkout_ms` (5000): how long a caller waits for a connection.
- `lease_ms` (30000): how long a block may run.
- `max_age_ms` (0): a connection this old is closed and replaced when it is idle. 0 turns it off.
- `idle_ms` (0): a connection unused this long is closed. It needs `lazy: true`, which opens connections only when callers need them (default `false`: always connected).
- `health_ms` (5000): how often the idle connections are pinged and `max_age_ms` and `idle_ms` applied. 0 turns the check off, and then those two must be 0.
- `checkpoint_frames` (1000), `checkpoint_ms` (1000) and `checkpoint_cap` (0): the checkpoints of a SQLite file in WAL mode, see [below](#sqlite-checkpoints). Other databases ignore them.

The url is anything `Db.open` takes, `timeout_ms` included: every statement of the pooled connections is then bounded, and the `timeout_ms` argument of `Db.query` and `Db.execute` works as on any connection.

## What happens when the block ends

The connection goes back to the pool, whatever the block did:

- A transaction the block left open is rolled back (`Db.in_transaction?` tells, without a round trip), so the next caller starts clean. Use `Db.transaction(conn)` in the block to commit.
- A connection the block closed or lost (`Db.connected?` is false) is closed and replaced, so the next caller does not get a dead one. The database client only learns that the server ended a connection when a call on it fails, so the call that fails does so in the block that made it, and the pool replaces the connection after it.
- On PostgreSQL too, a connection that the server ended quietly while it was idle fails the first caller that gets it, up to `size` callers, until the health check (`health_ms`) pings it and replaces it.
- A block that crashes ends its connection: the pool rolls it back, closes it and opens another. The caller gets `error("task crashed: ...")`.
- A block that runs past `lease_ms` ends its connection too, and its caller gets `pool error: lease timed out after N ms`.
- A connection whose rollback fails is closed and replaced.
- Idle connections are pinged with `Db.healthy?` every 5 seconds, and one that does not answer is replaced.

State that belongs to one connection (a temporary table, `SET` on the session, a prepared statement) is not safe to count on between two blocks: the next block may get another connection. The pool undoes only an open transaction: other session state that the block leaves (an advisory lock, `SET autocommit=0` on MySQL, a changed `search_path`) reaches the next caller, and so does a `conn` the block keeps after it ends, which then belongs to someone else. Use `conn` only inside the block, and undo what you set.

## SQLite writers take turns

SQLite has one writer at a time. The connections of a SQLite pool wait in line at `Db.transaction`: a writer waits for the one before it to commit, and they get their turn in the order they came, instead of each trying its `BEGIN IMMEDIATE` again every few milliseconds until the lock is free. A writer waits for its turn up to `busy_timeout`, and at most half of `lease_ms`; then its `BEGIN` takes the lock if it is free and fails with `sqlite error 5: database is locked` if not, as it would without the line. A block that crashes or runs past `lease_ms` inside its transaction gives the turn back when the pool takes its connection back. A statement outside `Db.transaction` does not wait in line, and `busy_timeout` stays its wait for the writers of other pools and processes.

Do not start a transaction on a second connection of the pool inside a transaction: it waits for the turn that the first one holds, and fails after `busy_timeout` with `sqlite error 5: database is locked`.

## SQLite checkpoints

In WAL mode a commit appends its pages to the `-wal` file, and a checkpoint copies them into the database file. By default SQLite checkpoints in the `COMMIT` that brings the WAL past 1000 pages, so that one commit pays for the copy of many. A pool of a SQLite file with the native driver takes the checkpoints off the commits: its connections turn SQLite's automatic checkpoint off, and a checkpointer task of the pool, with a connection of its own, runs a passive checkpoint (`PRAGMA wal_checkpoint(PASSIVE)`) on the compute pool when a commit leaves `checkpoint_frames` pages or more in the WAL that no checkpoint has copied, and every `checkpoint_ms` in any case. A passive checkpoint never waits for a reader or a writer, so it copies what it can and leaves the rest for the next one.

If the checkpointer falls behind, a commit that leaves `checkpoint_cap` such pages or more checkpoints itself, as SQLite would. 0 means four times `checkpoint_frames`. That keeps the WAL near the cap as long as no reader holds an older snapshot: as with SQLite's own checkpoints, a passive checkpoint cannot copy the pages that a long read still needs, and the WAL grows until it ends. `checkpoint_frames` 0 turns the checkpointer off and leaves the checkpoints to SQLite. `DbPool.close` stops the checkpointer and closes its connection. A value below 0 (below 1 for `checkpoint_ms`) does not start the pool: `db error: checkpoint_ms must be 1 or more, got 0`.

Since its `COMMIT` no longer checkpoints, the `COMMIT` of a transaction of short writes runs in a short call on the scheduler (see [the drivers](/databases/sqlite/#drivers)) when `synchronous` is `normal` (the default in WAL) or `off`: with `full` or `extra` a commit waits for the disk and runs on the compute pool. The `COMMIT` of a transaction that ran a write on the compute pool, or more than 64 short ones, runs on the compute pool too. So does every write of the pool while a checkpoint runs, and the transaction after a checkpoint that copied the whole WAL: its commit starts the WAL again from the start and syncs its header, a disk flush even with `synchronous=normal`. The pool does not see a checkpoint that another connection runs (another process, a connection outside the pool, or SQLite's own when the last connection closes), so the commit after it may sync on the scheduler. A `PRAGMA` that sets `journal_mode`, `synchronous` or `locking_mode` on a connection of the pool sends its writes to the compute pool from then on, and `PRAGMA wal_checkpoint`, or one that sets `wal_autocheckpoint`, the writes of the whole pool; a `PRAGMA` that only reads one of them changes nothing. An in-memory database, the FFI driver, `checkpoint_frames` 0 and a connection outside a pool keep SQLite's automatic checkpoint.

## Errors and timeouts

- `pool error: checkout timed out after N ms`: every connection was busy for `checkout_ms`.
- `pool error: lease timed out after N ms`: the block ran too long.
- `pool error: queue full`: more than 1000 callers wait already.
- `pool error: closed`: the pool is closed.
- `sqlite error 9: interrupted`, `postgres error 57014: ...` and the like: a statement ran over its `timeout_ms`.

`DbPool.timeout?(message)` is true for the first two and for a statement that ran over its `timeout_ms` (the same as `Db.timeout?`), so a handler can answer "busy, try later" to all of them. The other errors are those of the block. Cancelling a caller does not cancel its block: `lease_ms` bounds it.

## A block that runs past `lease_ms`

The caller gets `pool error: lease timed out after N ms` when the time is over, and the pool cancels the block, but a block that is inside a native call cannot be stopped from outside, so it can keep running for a while. What the pool does with its connection depends on the database:

- SQLite: the statement is interrupted, so the connection closes at once and the next caller gets a new one.
- PostgreSQL: the connection is closed while the statement may still run on the server until it ends.
- MySQL and MariaDB: the statement runs until the server stops it, and closing the connection under it is not safe: the process can crash when it exits. Set `timeout_ms` in the url below `lease_ms`, so that the server ends a statement before the lease does.

In all cases a `timeout_ms` below `lease_ms` makes the statement fail by itself (`Db.timeout?`), as an ordinary error of the block, and the connection is kept.

`DbPool.close(pool, drain_ms)` refuses new callers, lets the running blocks finish for up to `drain_ms`, and closes every connection.
