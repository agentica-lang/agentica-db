## The native driver of the PostgreSQL adapter: the module of `native/db_postgres.c` (`[native.db_postgres]` of
## `agentica.toml`), which Agentica builds at the first run or compile of a program, a fetched package too. The
## connection is in libpq's non-blocking mode: every call is short, and a wait for the server is a wait on its socket
## (`Native.wait_readable`), which parks only this task, so a query takes no compute call. A connection keeps its
## prepared statements in a cache keyed by the sql text, and a result comes in batches of rows, one call per batch.
##
## A query holds the mutex of its connection from its first call to its last: the calls of a query must not mix with
## another's. A task that is cancelled in the middle of one leaves it on the connection, and the next query drains it
## first, after a cancel request to the server.

import PostgresStatement from "statement"
import {Row, Value} from "../support/value"

# What `Step.state` asks of this file: wait until the socket can be read or written, take the rows and resume, take
# the last rows, give the failure, translate the sql (it is not cached), ask the server to cancel a query that a
# cancelled task left, or make the call on the compute pool (start_big, resume_big): parameters or a row of more than
# 256 KiB take too long to copy for a short call.
S_READ = 1
S_WRITE = 2
S_ROWS = 3
S_DONE = 4
S_FAILED = 5
S_PLAN = 6
S_CANCEL = 7
S_BIG_START = 8
S_BIG = 9
# A wait for the socket wakes this often to see whether the connection was closed meanwhile; a wait to write is short,
# since the server may need this side to read first (the module reads at each resume).
READ_WAIT_MS = 1_000
WRITE_WAIT_MS = 50
TIMED_OUT = "native: timed out"
# The verbs of the statements that the cache keeps (the ones the server plans), and of the ones that change the
# schema, after which the cache lets every statement go: a cached plan may no longer fit the tables.
CACHED_VERBS = Set.new(["select", "insert", "update", "delete", "with", "values", "merge", "table"])
FLUSH_VERBS = Set.new(["create", "alter", "drop", "import"])

## What a call may give at once: up to `rows` rows or about `bytes` bytes of values; a longer result takes more calls.
export struct Options
  rows: Int = 100
  bytes: Int = 262_144
end

# What the adapter read of a statement that is not cached: its translation (`sql`, `count` placeholders), whether to
# cache it, whether it changes the schema, and whether its rows are wanted (`keep`, false for `execute`). A Plan that
# is not `known` runs a cached statement only.
struct Plan
  known: Bool = false
  sql: String = ""
  count: Int = 0
  cache: Bool = false
  flush: Bool = false
  keep: Bool = true
end

# What one call did: see the S_ constants. `fd` is the socket to wait for; `changes` and `tag` (the command status of
# the server) come with S_DONE.
struct Step
  state: Int
  fd: Int
  failure: String
  rows: List[Row]
  changes: Int
  tag: String
end

## What the statement cache of a connection holds (`size` of `capacity`) and how it was used: a `hit` ran a cached
## statement, a `miss` prepared one, an `eviction` let go of the one used least long ago to make room.
export struct CacheStats
  size: Int
  capacity: Int
  hits: Int
  misses: Int
  evictions: Int
end

## A connection of the module, the mutex that keeps its queries apart, and the caps of a call.
export struct Session
  conn: Conn
  lock: Native.Mutex
  options: Options
end

# The rows of a statement that ran, its count of changes and its command status.
struct Done
  rows: List[Row]
  changes: Int
  tag: String
end

# A Plan with the verb of its statement, for the check of a COMMIT.
struct Planned
  plan: Plan
  verb: String
end

extern module "db_postgres"
  ## A connection; `Native.close` ends it (PQfinish).
  export resource Conn
  export def cache_stats(conn: Conn) -> CacheStats
end

## Whether the module opens: false where the built library does not load, and the FFI driver runs.
export def available?() -> Bool
  return Native.load("db_postgres").ok?
end

## Connects with what libpq takes and a cache of `cache` statements (0: none).
export def open(conninfo: String, cache: Int, options: Options) -> Result[Session]
  conn = try connect(conninfo, cache)
  return ok(Session(conn: conn, lock: Native.mutex(), options: options))
end

## Runs one statement and gives its rows.
export def query(session: Session, sql: String, params: List[Value]) -> Result[List[Row]]
  done = try session.lock.synchronize do run(session, sql, params, true) end
  return ok(done.rows)
end

## Runs one statement and gives the number of rows it inserted, updated or deleted.
export def execute(session: Session, sql: String, params: List[Value]) -> Result[Int]
  done = try session.lock.synchronize do run(session, sql, params, false) end
  return ok(done.changes)
end

## PQstatus and PQtransactionStatus, as `status * 16 + transaction status`, once a query that a cancelled task left
## has ended (while it runs, the transaction status is ACTIVE).
export def link_status(session: Session) -> Int
  return session.lock.synchronize do settled_status(session) end
end

## Whether the connection is closed.
export def closed?(session: Session) -> Bool
  return Native.closed?(session.conn)
end

# The calls that only this file makes. A connection runs one query at a time, from `start` (or `drain`) to the step
# that ends it.
extern module "db_postgres"
  compute def connect(conninfo: String, cache: Int) -> Result[Conn]
  def start(conn: Conn, sql: String, params: List[Value], plan: Plan, options: Options) -> Step
  compute def start_big(conn: Conn, sql: String, params: List[Value], plan: Plan, options: Options) -> Step
  def resume(conn: Conn, options: Options) -> Step
  compute def resume_big(conn: Conn, options: Options) -> Step
  def drain(conn: Conn) -> Step
  def left?(conn: Conn) -> Bool
  compute def cancel(conn: Conn) -> Void
  def status(conn: Conn) -> Int
end

# A cached statement runs at once; any other is translated and checked here first, then sent. The adapter has checked
# that the connection is open.
def run(session: Session, sql: String, params: List[Value], keep: Bool) -> Result[Done]
  plan = Plan(keep: keep)
  step = start(session.conn, sql, params, plan, session.options)
  verb = ""
  if step.state == S_PLAN
    planned = try plan_of(session, sql, params, keep)
    verb = planned.verb
    plan = planned.plan
    step = start(session.conn, sql, params, plan, session.options)
  end

  if step.state == S_BIG_START
    step = start_big(session.conn, sql, params, plan, session.options)
  end

  done = try finish(session, step)
  try PostgresStatement.check_commit(done.tag, verb)
  return ok(done)
end

def plan_of(session: Session, sql: String, params: List[Value], keep: Bool) -> Result[Planned]
  translated = try PostgresStatement.check_sql(sql, params.size, status(session.conn) % 16)
  verb = translated.verb
  plan = Plan(
    known: true,
    sql: translated.sql,
    count: translated.count,
    cache: CACHED_VERBS.include?(verb),
    flush: FLUSH_VERBS.include?(verb),
    keep: keep,
  )

  return ok(Planned(plan: plan, verb: verb))
end

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

      return ok(Done(rows: rows, changes: step.changes, tag: step.tag))
    elsif step.state == S_FAILED
      return error(step.failure)
    elsif step.state == S_ROWS
      batches = batches.push(step.rows)
    elsif step.state != S_BIG
      try wait(session, step)
    end

    # Another task may close the connection meanwhile.
    if Native.closed?(session.conn)
      return error("postgres error: the connection is closed")
    end

    if step.state == S_BIG
      step = resume_big(session.conn, session.options)
    else
      step = resume(session.conn, session.options)
    end
  end

  return error("postgres error: the query ended without a result")
end

# Waits for the socket, or asks the server to cancel the query that a cancelled task left. A wait that timed out goes
# on with a resume, which reads the socket again.
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
    ok(_) -> return ok()
    error(message) ->
      if message == TIMED_OUT
        return ok()
      end

      return error("postgres error: #{message}")
  end
end

def settled_status(session: Session) -> Int
  if left?(session.conn)
    _ = finish(session, drain(session.conn))
  end

  return status(session.conn)
end
