## The native driver of the PostgreSQL adapter: the module of `native/db_postgres.c` (`[native.db_postgres]` of
## `agentica.toml`), which Agentica builds at the first run or compile of a program, a fetched package too. The
## connection is in libpq's non-blocking mode: every call is short, and a wait for the server is a wait on its socket
## (`Native.wait_readable`), which parks only this task, so a query takes no compute call. A connection keeps its
## prepared statements in a cache keyed by the sql text, and a result comes in batches of rows, one call per batch.
##
## A query holds the mutex of its connection from its first call to its last: the calls of a query must not mix with
## another's, and every call on the connection is made under it. A task that is cancelled in the middle of one leaves
## it on the connection, and the next query drains it first, after a cancel request to the server.

import PostgresSql from "sql"
import PostgresStatement from "statement"
import {Row, Value} from "../support/value"

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

extern module "db_postgres"
  ## A connection; `Native.close` ends it (PQfinish).
  resource Conn
end

## Whether the module opens: false where the built library does not load, and the FFI driver runs.
def available?() -> Bool = Native.load("db_postgres").ok?

## Connects with what libpq takes and a cache of `cache` statements (0: none).
def open(conninfo: String, cache: Int, options: Options) -> Result[Session]
  conn = try connect(conninfo, cache)
  ok(Session(conn: conn, lock: Native.mutex(), options: options))
end

## Runs one statement and gives its rows.
def query(session: Session, sql: String, params: List[Value]) -> Result[List[Row]]
  done = try session.lock.synchronize do run(session, sql, params, true) end
  ok(done.rows)
end

## Runs one statement and gives the number of rows it inserted, updated or deleted.
def execute(session: Session, sql: String, params: List[Value]) -> Result[Int]
  done = try session.lock.synchronize do run(session, sql, params, false) end
  ok(done.changes)
end

## PQstatus and PQtransactionStatus, as `status * 16 + transaction status`, once a query that a cancelled task left
## has ended (while it runs, the transaction status is ACTIVE).
def link_status(session: Session) -> Int = session.lock.synchronize do settled_status(session) end

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
# The verbs of the statements that the cache keeps (the ones the server plans), and of the ones that change the
# schema, after which the cache lets every statement go: a cached plan may no longer fit the tables.
CACHED_VERBS = Set.new(["select", "insert", "update", "delete", "with", "values", "merge", "table"])
FLUSH_VERBS = Set.new(["create", "alter", "drop", "import"])
# The verbs of `DEALLOCATE [PREPARE] ALL` and `DISCARD ALL`, which drop every prepared statement of the session.
DROP_ALL_VERBS = Set.new(["deallocate", "discard"])
# PQstatus CONNECTION_BAD and PQtransactionStatus UNKNOWN, as `link_status` gives them: what a closed connection is.
CLOSED_STATUS = 1 * 16 + 4
CLOSED = "postgres error: the connection is closed"

# What the adapter read of a statement that is not cached: its translation (`sql`, `count` placeholders), whether to
# cache it, whether it changes the schema, whether it drops every prepared statement (`forgot`), and whether its rows
# are wanted (`keep`, false for `execute`). A Plan that is not `known` runs a cached statement only.
struct Plan
  known: Bool = false
  sql: String = ""
  count: Int = 0
  cache: Bool = false
  flush: Bool = false
  forgot: Bool = false
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
  def cache_stats(conn: Conn) -> CacheStats
end

# A cached statement runs at once; any other is translated and checked here first, then sent. The adapter checked
# that the connection was open, but another task may have closed it while this one waited for the mutex.
def run(session: Session, sql: String, params: List[Value], keep: Bool) -> Result[Done]
  return error(CLOSED) if Native.closed?(session.conn)

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
  ok(done)
end

# The transaction status that the check of a BEGIN reads is the one after a query that a cancelled task left.
def plan_of(session: Session, sql: String, params: List[Value], keep: Bool) -> Result[Planned]
  transaction = settled_status(session) % 16
  translated = try PostgresStatement.check_sql(sql, params.size, transaction)
  verb = translated.verb
  plan = Plan(
    known: true,
    sql: translated.sql,
    count: translated.count,
    cache: CACHED_VERBS.include?(verb),
    flush: FLUSH_VERBS.include?(verb),
    forgot: DROP_ALL_VERBS.include?(verb) and drops_all?(PostgresSql.first_words(sql, 3)),
    keep: keep,
  )

  ok(Planned(plan: plan, verb: verb))
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
    return error(CLOSED) if Native.closed?(session.conn)

    if step.state == S_BIG
      step = resume_big(session.conn, session.options)
    else
      step = resume(session.conn, session.options)
    end
  end

  error("postgres error: the query ended without a result")
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
    ok(_) -> ok()
    error(e) ->
      return ok() if e.kind == "native.timeout"

      error(e.with(message: "postgres error: #{e.message}"))
  end
end

def settled_status(session: Session) -> Int
  return CLOSED_STATUS if Native.closed?(session.conn)

  if left?(session.conn)
    _ = finish(session, drain(session.conn))
    return CLOSED_STATUS if Native.closed?(session.conn)
  end

  status(session.conn)
end

# Whether the statement is `DEALLOCATE [PREPARE] ALL` or `DISCARD ALL`, which drop every prepared statement of the
# session, the cached ones too. WORDS are its first bare words: a statement named `all` must be quoted, and a comment
# is not a word.
def drops_all?(words: List[String]) -> Bool
  return true if words == ["discard", "all"] or words == ["deallocate", "all"]

  words == ["deallocate", "prepare", "all"]
end
