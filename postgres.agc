## The PostgreSQL driver of `Db`: `Db.open("postgres://localhost/app", [Postgres.driver()])`. A program that imports
## this file builds the native PostgreSQL module (`native/db_postgres.c`) at its first run. The adapter itself is
## `postgres/postgres.agc`.

import C from "support/connection"
import PostgresAdapter from "postgres/postgres"

## The driver of `postgres://` and `postgresql://` urls, which libpq parses.
def driver() -> C.Driver = C.Driver(schemes: ["postgres://", "postgresql://"], open: &open, pool: &pooling)

## Opens a PostgreSQL database from a libpq url, or from a conninfo string (`host=localhost dbname=app`), which libpq
## also takes and `Db.open` does not, since it has no scheme. `timeout_ms` is a parameter of the url, or a key of the
## conninfo, that this package reads and libpq never sees: it sets the `statement_timeout` of the session.
def open(url: String) -> Result[C.Connection]
  conn = try PostgresAdapter.open(url)
  ok(connection(conn))
end

private

def connection(conn: PostgresAdapter.Connection) -> C.Connection
  C.Connection(
    adapter: C.Adapter.Postgres,
    begin_sql: PostgresAdapter.BEGIN_SQL,
    close: -> { PostgresAdapter.close(conn) },
    query: ->(sql, params, timeout_ms) { PostgresAdapter.query(conn, sql, params, timeout_ms) },
    execute: ->(sql, params, timeout_ms) { PostgresAdapter.execute(conn, sql, params, timeout_ms) },
    in_transaction: -> { PostgresAdapter.in_transaction?(conn) },
    connected: -> { PostgresAdapter.connected?(conn) },
    healthy: -> { PostgresAdapter.healthy?(conn) },
    interrupt: -> { PostgresAdapter.interrupt(conn) },
    enter_gate: -> { connection(conn) },
    leave_gate: -> { return },
    statement_cache: -> { cache_stats(conn) },
  )
end

def cache_stats(conn: PostgresAdapter.Connection) -> Optional[C.CacheStats]
  PostgresAdapter.statement_cache(conn).map do |c|
    C.CacheStats(size: c.size, capacity: c.capacity, hits: c.hits, misses: c.misses, evictions: c.evictions)
  end
end

# A pool of a server opens plain connections and starts nothing of its own.
def pooling(settings: C.PoolSettings) -> C.Pooling = C.Pooling(open: -> { open(settings.url) }, stop: -> { return })
