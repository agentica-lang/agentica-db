---
title: Pooling
weight: 14
description: DbPool lends connections to a request one at a time, rolls back what a request leaves open, and replaces a connection that fails.
---

A web app should not open a connection for each request. `DbPool` (`import DbPool from "pkg/db/db_pool"`) keeps a few connections open and lends one to a block of code at a time, on top of the [generic pool](/guide/pool/). The block gets a `Db.Connection`, so `Db`, `Orm` and `Migrate` work in it as always.

```agentica
import Db from "pkg/db/db"
import DbPool from "pkg/db/db_pool"
import Orm from "pkg/db/orm"

struct User
  id: Int = 0
  name: String
end

def main() -> Void
  users = Orm.schema("users", User.members, JSON.codec(User))
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

- `size` (0): how many connections. 0 takes the size of the database: 4 for SQLite, 10 for PostgreSQL and MySQL or MariaDB. A private in-memory database, `sqlite::memory:`, has one connection, and a `size` or `max_overflow` that asks for more is refused with `db error: a pool of sqlite::memory: can have one connection only` (each connection would be an empty database of its own; `file::memory:?cache=shared` is one database to all).
- `max_overflow` (0): in a spike, up to this many connections more are opened, so `size + max_overflow` is the most there are.
- `overflow_idle_ms` (1000): an overflow connection that nobody needs is closed after this long.
- `checkout_ms` (5000): how long a caller waits for a connection.
- `lease_ms` (30000): how long a block may run.
- `max_age_ms` (0): a connection this old is closed and replaced when it is idle. 0 turns it off.
- `idle_ms` (0): a connection unused this long is closed. It needs `lazy: true`, which opens connections only when callers need them (default `false`: always connected).

The url is anything `Db.open` takes, `timeout_ms` included: every statement of the pooled connections is then bounded, and the `timeout_ms` argument of `Db.query` and `Db.execute` works as on any connection.

## What happens when the block ends

The connection goes back to the pool, whatever the block did:

- A transaction the block left open is rolled back (`Db.in_transaction?` tells, without a round trip), so the next caller starts clean. Use `Db.transaction(conn)` in the block to commit.
- A block that crashes ends its connection: the pool rolls it back, closes it and opens another. The caller gets `error("task crashed: ...")`.
- A block that runs past `lease_ms` ends its connection too, and its caller gets `pool error: lease timed out after N ms`.
- A connection whose rollback fails is closed and replaced.
- Idle connections are pinged with `Db.healthy?` every 5 seconds, and one that does not answer is replaced.

State that belongs to one connection (a temporary table, `SET` on the session, a prepared statement) is not safe to count on between two blocks: the next block may get another connection.

## Errors and timeouts

- `pool error: checkout timed out after N ms`: every connection was busy for `checkout_ms`.
- `pool error: lease timed out after N ms`: the block ran too long.
- `pool error: queue full`: more than 1000 callers wait already.
- `pool error: closed`: the pool is closed.
- `sqlite error 9: interrupted`, `postgres error 57014: ...` and the like: a statement ran over its `timeout_ms`.

`DbPool.timeout?(message)` is true for the first two and for a statement that ran over its `timeout_ms` (the same as `Db.timeout?`), so a handler can answer "busy, try later" to all of them. The other errors are those of the block. Cancelling a caller does not cancel its block: `lease_ms` bounds it.

`DbPool.close(pool, drain_ms)` refuses new callers, lets the running blocks finish for up to `drain_ms`, and closes every connection.
