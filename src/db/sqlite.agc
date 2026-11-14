## The SQLite driver of `Db`: `Db.open("sqlite:app.db", [Sqlite.driver()])`. A program that imports this file builds
## the native SQLite module (`native/db_sqlite.c`) at its first run; the adapter itself is `sqlite/sqlite.agc`.
##
## A pool of a SQLite file (`DbPool`) puts its connections in one line of writers and, on the native driver in WAL
## mode, takes the checkpoints of the WAL off the writers with a checkpointer task (see `db_pool.agc`).

import C from "support/connection"
import SqliteAdapter from "sqlite/sqlite"
import SqliteUrl from "sqlite/url"

## The driver of `sqlite:PATH` urls (`sqlite::memory:` for a private in-memory database).
def driver() -> C.Driver = C.Driver(schemes: [PREFIX], open: &open_url, pool: &pooling)

## Opens a SQLite database file, or `:memory:`, by its path: `sqlite:PATH` without the scheme. Parameters after a `?`
## set `journal_mode` (default `wal`), `foreign_keys` (default `on`), `busy_timeout` in milliseconds (default 5000),
## `timeout_ms` (default none), `synchronous`, `mmap_size`, `cache_size`, `journal_size_limit` and `fts5=required`
## (see `sqlite/sqlite.agc`).
def open(path: String) -> Result[C.Connection]
  conn = try SqliteAdapter.open(path)
  ok(connection(conn))
end

private

PREFIX = "sqlite:"

# The checkpointer of a pool: the task, and how the commits of the pool reach it (`plan.nudge`).
struct Checkpointer
  plan: SqliteAdapter.Checkpoints
  task: Task[Result[Void]]
end

# What the checkpointer task needs: the url of its own connection, the checkpoints of the pool (`plan.nudge` wakes it,
# and closed stops it), and the time between two checkpoints when nothing wakes it.
struct Watch
  url: String
  plan: SqliteAdapter.Checkpoints
  every_ms: Int
end

def open_url(url: String) -> Result[C.Connection]
  conn = try open_raw(url)
  ok(connection(conn))
end

# Errors name the scheme only: a url can hold a password.
def open_raw(url: String) -> Result[SqliteAdapter.Connection]
  if url.start_with?("sqlite://")
    return error("db error: unsupported database url with scheme sqlite://: write sqlite:PATH, without //")
  end

  path = url.slice(PREFIX.length, url.length - PREFIX.length)
  return error("db error: unsupported database url with scheme sqlite: the path is empty") if path.empty?

  SqliteAdapter.open(path)
end

def connection(conn: SqliteAdapter.Connection) -> C.Connection
  C.Connection(
    adapter: C.Adapter.Sqlite,
    begin_sql: SqliteAdapter.BEGIN_SQL,
    close: -> { SqliteAdapter.close(conn) },
    query: ->(sql, params, timeout_ms) { SqliteAdapter.query(conn, sql, params, timeout_ms) },
    execute: ->(sql, params, timeout_ms) { SqliteAdapter.execute(conn, sql, params, timeout_ms) },
    in_transaction: -> { SqliteAdapter.in_transaction?(conn) },
    connected: -> { SqliteAdapter.connected?(conn) },
    healthy: -> { SqliteAdapter.healthy?(conn) },
    interrupt: -> { SqliteAdapter.interrupt(conn) },
    enter_gate: -> { connection(SqliteAdapter.enter_gate(conn)) },
    leave_gate: -> { SqliteAdapter.leave_gate(conn) },
    statement_cache: -> { cache_stats(conn) },
  )
end

def cache_stats(conn: SqliteAdapter.Connection) -> Optional[C.CacheStats]
  SqliteAdapter.statement_cache(conn).map do |c|
    C.CacheStats(
      size: c.size,
      capacity: c.capacity,
      hits: c.hits,
      misses: c.misses,
      evictions: c.evictions,
      shorts: c.shorts,
      fallbacks: c.fallbacks,
    )
  end
end

# The connections of a pool share one line of writers (`gate` holds one token), and those of a file in WAL mode on the
# native driver the checkpointer, which starts before them so that none runs without it.
def pooling(settings: C.PoolSettings) -> C.Pooling
  gate: Channel[Int] = Channel.new(1)
  _ = gate.send(1, 0)
  checkpointer = start_checkpointer(settings)
  C.Pooling(open: -> { open_pooled(settings, gate, checkpointer) }, stop: -> { stop_checkpointer(checkpointer) })
end

def open_pooled(
  settings: C.PoolSettings,
  gate: Channel[Int],
  checkpointer: Optional[Checkpointer],
) -> Result[C.Connection]
  conn = try open_raw(settings.url)
  in_line = SqliteAdapter.with_gate(conn, gate, settings.lease_ms)
  case checkpointer
    some(running) -> ok(connection(SqliteAdapter.own_checkpoints(in_line, running.plan)))
    none -> ok(connection(in_line))
  end
end

# The checkpointer of a pool of a SQLite file, none for any other url or with `checkpoint_frames` 0.
def start_checkpointer(settings: C.PoolSettings) -> Optional[Checkpointer]
  return none if settings.checkpoint_frames == 0 or not SqliteUrl.file?(settings.url)

  nudge: Channel[Int] = Channel.new(1)
  case SqliteAdapter.checkpoints(nudge, settings.checkpoint_frames, settings.checkpoint_cap)
    none -> none
    some(plan) ->
      task = Task.spawn(&checkpoints, Watch(url: settings.url, plan: plan, every_ms: settings.checkpoint_ms))
      some(Checkpointer(plan: plan, task: task))
  end
end

# Closing the channel stops the task at its next wake-up, after the checkpoint that runs, if any; it closes its
# connection before it ends.
def stop_checkpointer(checkpointer: Optional[Checkpointer]) -> Void
  case checkpointer
    none -> return
    some(running) ->
      running.plan.nudge.close
      _ = Task.await(running.task)
  end
end

# The checkpointer task: a PASSIVE checkpoint on a connection of its own (the compute pool runs it) each time a commit
# wakes it, and every `every_ms`, until the channel closes. A connection that the pool cannot checkpoint (the FFI
# driver, not WAL) ends it at once, and so does one that does not open: the commits then checkpoint at the cap.
def checkpoints(watch: Watch) -> Result[Void]
  conn = try open_raw(watch.url)
  if SqliteAdapter.checkpointable?(conn)
    checkpoint_loop(conn, watch)
  end

  SqliteAdapter.close(conn)
  ok()
end

def checkpoint_loop(conn: SqliteAdapter.Connection, watch: Watch) -> Void
  while true
    _ = watch.plan.nudge.recv(watch.every_ms)
    return if watch.plan.nudge.closed?

    SqliteAdapter.checkpoint(conn, watch.plan)
  end
end
