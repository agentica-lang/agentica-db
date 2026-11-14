## The MySQL and MariaDB driver of `Db`: `Db.open("mysql://user@127.0.0.1/app", [Mysql.driver()])`. The adapter
## itself is `mysql/mysql.agc`.

import C from "support/connection"
import MysqlAdapter from "mysql/mysql"

## The driver of `mysql://` and `mariadb://` urls.
def driver() -> C.Driver = C.Driver(schemes: ["mysql://", "mariadb://"], open: &open, pool: &pooling)

## Opens a MySQL or MariaDB database from a `mysql://user:password@host:3306/database` url (also `mariadb://`).
## `timeout_ms` is a parameter of the url (see `mysql/mysql.agc`).
def open(url: String) -> Result[C.Connection]
  conn = try MysqlAdapter.open(url)
  ok(connection(conn, url))
end

private

def connection(conn: MysqlAdapter.Connection, url: String) -> C.Connection
  C.Connection(
    adapter: C.Adapter.Mysql,
    begin_sql: MysqlAdapter.BEGIN_SQL,
    close: -> { MysqlAdapter.close(conn) },
    query: ->(sql, params, timeout_ms) { MysqlAdapter.query(conn, sql, params, timeout_ms) },
    execute: ->(sql, params, timeout_ms) { MysqlAdapter.execute(conn, sql, params, timeout_ms) },
    in_transaction: -> { MysqlAdapter.in_transaction?(conn) },
    connected: -> { MysqlAdapter.connected?(conn) },
    healthy: -> { MysqlAdapter.healthy?(conn) },
    interrupt: -> { MysqlAdapter.interrupt(conn, url) },
    enter_gate: -> { connection(conn, url) },
    leave_gate: -> { return },
    statement_cache: -> { cache_stats(conn) },
  )
end

def cache_stats(conn: MysqlAdapter.Connection) -> Optional[C.CacheStats]
  MysqlAdapter.statement_cache(conn).map do |c|
    C.CacheStats(size: c.size, capacity: c.capacity, hits: c.hits, misses: c.misses, evictions: c.evictions)
  end
end

# A pool of a server opens plain connections and starts nothing of its own.
def pooling(settings: C.PoolSettings) -> C.Pooling = C.Pooling(open: -> { open(settings.url) }, stop: -> { return })
