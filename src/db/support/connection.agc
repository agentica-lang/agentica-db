## The types between `Db` and the drivers: a `Driver` opens a `Connection`, a record of the functions of one open
## connection. `db.agc` re-exports them (`Db.Driver`, `Db.Connection`). An app passes the drivers it uses to
## `Db.open` and `DbPool.Options`, and imports only those, so only their native modules are built. The fields are the
## contract of a driver: an app calls `Db` and never a field.

import {Row, Value} from "value"

## An open connection, owned by the task that opened it. `adapter` names the database (`sqlite`, `postgres`,
## `mysql`) and `begin_sql` is the statement that starts a transaction. Each function works on the connection that the
## driver opened: `query` and `execute` take the sql, the parameters and `timeout_ms`; `interrupt`, `enter_gate` and
## `leave_gate` serve the SQLite writers of a pool (`DbPool`) and do nothing elsewhere; `statement_cache` gives the
## counters of the native driver's cache, none on a driver without one.
struct Connection
  adapter: String
  begin_sql: String
  close: Fn[Void]
  query: Fn[String, List[Value], Int, Result[List[Row]]]
  execute: Fn[String, List[Value], Int, Result[Int]]
  in_transaction: Fn[Bool]
  connected: Fn[Bool]
  healthy: Fn[Bool]
  interrupt: Fn[Void]
  enter_gate: Fn[Connection]
  leave_gate: Fn[Void]
  statement_cache: Fn[Optional[CacheStats]]
end

## The counters of the statement cache of a native driver. `shorts` and `fallbacks` are SQLite's (0 on PostgreSQL):
## the statements that ran whole in a short call, and the short calls that left their statement for the compute pool.
struct CacheStats
  size: Int
  capacity: Int
  hits: Int
  misses: Int
  evictions: Int
  shorts: Int = 0
  fallbacks: Int = 0
end

## A database: its `name`, the url prefixes it takes (`schemes`), `open` of a whole url, and `pool`, which a pool of
## its connections starts with.
struct Driver
  name: String
  schemes: List[String]
  open: Fn[String, Result[Connection]]
  pool: Fn[PoolSettings, Pooling]
end

## What a pool tells the driver when it starts (see `DbPool.Options`).
struct PoolSettings
  url: String
  lease_ms: Int
  checkpoint_frames: Int
  checkpoint_ms: Int
  checkpoint_cap: Int
end

## What a pool runs on the driver: `open` opens each connection of the pool, and `stop` ends what the driver started
## for it (the WAL checkpointer of SQLite) when the pool closes.
struct Pooling
  open: Fn[Result[Connection]]
  stop: Fn[Void]
end
