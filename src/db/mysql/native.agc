## The native driver of the MySQL adapter: the module of `native/db_mysql.c` (`[native.db_mysql]` of `agentica.toml`),
## which Agentica builds at the first run or compile of a program, a fetched package too. A query runs through the
## non-blocking calls of MariaDB Connector/C: every call is short, and a wait for the server is a wait on its socket
## (`Native.wait_readable`), which parks only this task, so a query takes no compute call. A connection keeps its
## prepared statements in a cache keyed by the sql text, and a result comes in batches of rows, one call per batch.
## The non-blocking calls run on a stack of their own, so the module runs them under `an_blocking` of the native API
## 1.3, which keeps the collector of the VM off it. The driver runs on Linux, where `libmariadb.so.3` is.
##
## A query holds the mutex of its connection from its first call to its last: the calls of a query must not mix with
## another's, and every call on the connection is made under it. A task that is cancelled in the middle of one leaves
## it on the connection, and the next query reads it to its end first, after a KILL QUERY of the statement.

import MysqlSql from "sql"
import MysqlStatement from "statement"
import MysqlUrl from "url"
import {Row, Value} from "../support/value"

## The error of `open` with AGENTICA_DB_MYSQL_DRIVER=native where the driver does not run.
UNAVAILABLE = "mysql error: the native MySQL driver runs on Linux, with its module built and libmariadb.so.3 loaded"

## What a call may give at once: up to `rows` rows or about `bytes` bytes of values; a longer result takes more calls.
struct Options
  rows: Int = 100
  bytes: Int = 262_144
end

## What the statement cache of a connection holds (`size` of `capacity`) and how it was used: a `hit` ran a cached
## statement, a `miss` prepared one, an `eviction` let go of the one used least long ago to make room.
struct CacheStats
  size: Int
  capacity: Int
  hits: Int
  misses: Int
  evictions: Int
end

## A connection of the module, the mutex that keeps its queries apart, and the caps of a call.
struct Session
  conn: Conn
  lock: Native.Mutex
  options: Options
end

extern module "db_mysql"
  ## A connection; `Native.close` ends it (mysql_close).
  resource Conn
end

## Whether the native driver runs here: on Linux, with a module that loads.
def available?() -> Bool = System.os() == "linux" and Native.load("db_mysql").ok?

## Connects to the target with its cache and batch caps.
def open(target: MysqlUrl.Target) -> Result[Session]
  conn = try connect(login_of(target), target.statement_cache)
  options = Options(rows: target.batch_rows, bytes: target.batch_bytes)
  ok(Session(conn: conn, lock: Native.mutex(), options: options))
end

## Runs one statement and gives its rows.
def query(session: Session, sql: String, params: List[Value]) -> Result[List[Row]]
  done = try session.lock.synchronize do run(session, sql, params, true) end
  ok(done.rows)
end

## Runs one statement that the cache never keeps and its counters never count, and gives its rows.
def query_once(session: Session, sql: String) -> Result[List[Row]]
  done = try session.lock.synchronize do run(session, sql, [], true, false) end
  ok(done.rows)
end

## Runs one statement and gives the number of rows it inserted, updated (matched), deleted or replaced.
def execute(session: Session, sql: String, params: List[Value]) -> Result[Int]
  done = try session.lock.synchronize do run(session, sql, params, false) end
  ok(done.changes)
end

## Whether the server says a transaction is open, once a query that a cancelled task left has ended.
def in_transaction?(session: Session) -> Bool
  session.lock.synchronize do
    settle(session)
    not Native.closed?(session.conn) and transaction_open?(session.conn)
  end
end

## Whether the client library still has its link to the server.
def connected?(session: Session) -> Bool
  session.lock.synchronize do not Native.closed?(session.conn) and link_up?(session.conn) end
end

## The version of the server, `8.4.3` or `11.4.2-MariaDB`.
def server_version(session: Session) -> String = session.lock.synchronize do server_info(session.conn) end

## Whether the connection is closed.
def closed?(session: Session) -> Bool = Native.closed?(session.conn)

## What the statement cache holds and has done; none once the connection is closed.
def stats(session: Session) -> Optional[CacheStats]
  session.lock.synchronize do
    return none if Native.closed?(session.conn)

    return some(cache_stats(session.conn))
  end
end

private

# What `Step.state` asks of this file: wait until the socket can be read or written, take the rows and resume, take
# the last rows, give the failure, read the sql (it is not cached), kill the statement that a cancelled task left,
# make the call on the compute pool (start_big, resume_big: parameters or a row of more than 256 KiB take too long to
# copy for a short call), or drain the query that a cancelled task left before this one starts.
S_READ = 1
S_WRITE = 2
S_ROWS = 3
S_DONE = 4
S_FAILED = 5
S_PLAN = 6
S_CANCEL = 7
S_BIG_START = 8
S_BIG = 9
S_LEFT = 10
# A wait for the socket wakes this often to see whether the connection was closed meanwhile (and the module whether a
# timeout of the library passed); a wait to write is short, since the server may need this side to read first.
READ_WAIT_MS = 1_000
WRITE_WAIT_MS = 50
# The verbs of the statements that the cache keeps, and of the ones that change the schema, after which the cache
# lets every statement go: a cached statement may no longer fit its tables.
CACHED_VERBS = Set.new(["select", "insert", "update", "delete", "replace", "with", "values", "table"])
FLUSH_VERBS = Set.new(["create", "alter", "drop", "rename", "truncate"])
# `Login.tls` for each `MysqlUrl.Tls`.
TLS_REQUIRED = 1
TLS_VERIFY = 2
CLOSED = "mysql error: the connection is closed"
LEFT_AGAIN = "mysql error: the query that a cancelled task left on the connection did not end"

# What the adapter read of a statement that is not cached: whether to cache it, whether it changes the schema,
# whether `execute` counts its rows, and whether its rows are wanted (`keep`, false for `execute`). A Plan that is not
# `known` runs a cached statement only.
struct Plan
  known: Bool = false
  cache: Bool = false
  flush: Bool = false
  counts: Bool = false
  keep: Bool = true
end

# What one call did: see the S_ constants. `fd` is the socket to wait for; `changes` comes with S_DONE.
struct Step
  state: Int
  fd: Int
  failure: String
  rows: List[Row]
  changes: Int
end

# Where and how to connect, for the module.
struct Login
  host: String
  port: Int
  user: String
  password: String
  database: String
  timeout: Int
  timeout_ms: Int
  tls: Int
  ca: String
end

# The rows of a statement that ran and its count of changes.
struct Done
  rows: List[Row]
  changes: Int
end

# The calls that only this file makes. A connection runs one query at a time, from `start` (or `drain`) to the step
# that ends it.
extern module "db_mysql"
  compute def connect(login: Login, cache: Int) -> Result[Conn]
  def start(conn: Conn, sql: String, params: List[Value], plan: Plan, options: Options) -> Step
  compute def start_big(conn: Conn, sql: String, params: List[Value], plan: Plan, options: Options) -> Step
  def resume(conn: Conn, options: Options) -> Step
  compute def resume_big(conn: Conn, options: Options) -> Step
  def drain(conn: Conn) -> Step
  compute def cancel(conn: Conn) -> Void
  def transaction_open?(conn: Conn) -> Bool
  def link_up?(conn: Conn) -> Bool
  def server_info(conn: Conn) -> String
  def cache_stats(conn: Conn) -> CacheStats
end

def login_of(target: MysqlUrl.Target) -> Login
  tls = 0
  case target.tls
    MysqlUrl.Tls.Default -> tls = 0
    MysqlUrl.Tls.Required -> tls = TLS_REQUIRED
    MysqlUrl.Tls.Verify -> tls = TLS_VERIFY
  end

  Login(
    host: target.host,
    port: target.port,
    user: target.user,
    password: target.password,
    database: target.database,
    timeout: target.timeout,
    timeout_ms: target.timeout_ms,
    tls: tls,
    ca: target.ca,
  )
end

# A cached statement runs at once; any other is read and checked here first, then sent. The adapter checked that the
# connection was open, but another task may have closed it while this one waited for the mutex.
def run(session: Session, sql: String, params: List[Value], keep: Bool, cached: Bool = true) -> Result[Done]
  return error(CLOSED) if Native.closed?(session.conn)

  plan = Plan(known: not cached, keep: keep)
  step = start(session.conn, sql, params, plan, session.options)
  if step.state == S_LEFT
    settle(session)
    return error(CLOSED) if Native.closed?(session.conn)

    step = start(session.conn, sql, params, plan, session.options)
    # The drain gave up (a failure that did not end the query): never resume a query that is not this one.
    return error(LEFT_AGAIN) if step.state == S_LEFT
  end

  if step.state == S_PLAN
    plan = try plan_of(session, sql, keep)
    step = start(session.conn, sql, params, plan, session.options)
  end

  if step.state == S_BIG_START
    step = start_big(session.conn, sql, params, plan, session.options)
  end

  finish(session, step)
end

def plan_of(session: Session, sql: String, keep: Bool) -> Result[Plan]
  verb = (try MysqlSql.inspect(sql)).verb
  try MysqlStatement.check_begin(transaction_open?(session.conn), verb)
  counts = MysqlStatement.counts?(verb)
  ok(
    Plan(
      known: true,
      cache: CACHED_VERBS.include?(verb) and not (counts and returns_rows?(sql)),
      flush: FLUSH_VERBS.include?(verb),
      counts: counts,
      keep: keep,
    ),
  )
end

# A write that gives rows (`INSERT ... RETURNING`) is never cached: a cached statement meets 2057 only after the
# server ran it, and a write is never run again. The module also checks the columns of the prepared statement, but
# MariaDB 11.8 reports none for a RETURNING before it runs. A word `returning` in a literal only skips the cache.
def returns_rows?(sql: String) -> Bool = sql.downcase.include?("returning")

# Waits and resumes until the statement ends. The rows of each batch are kept as a list of batches, joined once.
def finish(session: Session, first: Step) -> Result[Done]
  step = first
  batches: List[List[Row]] = []
  while true
    if step.state == S_DONE
      rows = step.rows
      if not batches.empty?
        rows = batches.push(step.rows).flat_map do |batch| batch end
      end

      return ok(Done(rows: rows, changes: step.changes))
    elsif step.state == S_FAILED
      return error(step.failure)
    elsif step.state == S_LEFT
      return error(LEFT_AGAIN)
    elsif step.state == S_ROWS
      batches = batches.push(step.rows)
    elsif step.state != S_BIG
      try wait(session, step)
    end

    # Another task may close the connection meanwhile.
    return error(CLOSED) if Native.closed?(session.conn)

    if step.state == S_BIG
      step = resume_big(session.conn, session.options)
    else
      step = resume(session.conn, session.options)
    end
  end

  error("mysql error: the query ended without a result")
end

# Waits for the socket, or kills the statement that a cancelled task left. A wait that timed out goes on with a
# resume, which looks at the socket (and the timeout of the library) again.
def wait(session: Session, step: Step) -> Result[Void]
  waited: Result[Void] = ok()
  if step.state == S_READ
    waited = Native.wait_readable(step.fd, READ_WAIT_MS)
  elsif step.state == S_WRITE
    waited = Native.wait_writable(step.fd, WRITE_WAIT_MS)
  elsif step.state == S_CANCEL
    cancel(session.conn)
  end

  case waited
    ok(_) -> ok()
    error(e) ->
      return ok() if e.kind == "native.timeout"

      error(e.with(message: "mysql error: #{e.message}"))
  end
end

# Reads the query that a cancelled task left to its end; its rows and its failure are dropped.
def settle(session: Session) -> Void
  if not Native.closed?(session.conn)
    _ = finish(session, drain(session.conn))
  end
end
