## The program under test of the features: it holds one database connection and runs the requests that
## `steps.agc` sends (`protocol.agc`), one JSON line in and one reply line out. It keeps the outcome of the last
## request, which the expectations check. A failed statement must be checked by an expectation before the next
## request: a setup step that fails cannot pass silently.

import Cells from "cells"
import Db from "../db"
import DbPool from "../db_pool"
import Migrate from "../migrate"
import Orm from "../orm"
import Mysql from "../mysql"
import Postgres from "../postgres"
import Protocol from "protocol"
import {Expectation, Request} from "protocol"
import Sqlite from "../sqlite"

private

# Per adapter: the id of the session of the connection, and the count of the sessions that have an id.
SESSION_ID_SQL = {"postgres": "select pg_backend_pid() as n", "mysql": "select connection_id() as n"}
SESSIONS_SQL = {
  "postgres": "select count(*) as n from pg_stat_activity where pid = ?",
  "mysql": "select count(*) as n from information_schema.processlist where id = ?",
}
# Per adapter: the count of the running statements of other sessions whose text has a marker (a `like` pattern).
RUNNING_SQL = {
  "postgres": (
    "select count(*) as n from pg_stat_activity where state = 'active' and query like ? and pid <> pg_backend_pid()"
  ),
  "mysql": (
    "select count(*) as n from information_schema.processlist " +
    "where command = 'Query' and info like ? and id <> connection_id()"
  ),
}
# What [SLOW] and [WORK] stand for, per adapter: a statement that runs for many seconds, and one that works for about
# half a second and gives the row `n = 1`.
SLOW_SQL = {
  "sqlite": (
    "with recursive c(x) as (select 1 union all select x + 1 from c limit 400000000) select count(*) as n from c"
  ),
  "postgres": "select pg_sleep(5)",
  "mysql": (
    "select count(*) from information_schema.columns a, information_schema.columns b, information_schema.columns c"
  ),
}
WORK_SQL = {
  "sqlite": "with recursive c(x) as (select 1 union all select x + 1 from c limit 2000000) select min(x) as n from c",
  "postgres": "select 1 as n from pg_sleep(0.6)",
  "mysql": "select 1 as n from dual where sleep(0.6) = 0",
}
SESSION_POLL_MS = 50
URL_VARIABLES = {"postgres": "AGENTICA_DB_POSTGRES_URL", "mysql": "AGENTICA_DB_MYSQL_URL"}
SQLITE_MEMORY = "sqlite::memory:"
# The folder of a driver that runs without the steps (by hand); a scenario always has its own.
SCRATCH_DEFAULT = "../tmp/scratch"
# The variable that steps.agc sets to the folder of the scenario (see `[SCRATCH]`).
SCRATCH_VARIABLE = "AGENTICA_DB_SCRATCH"
CARRY_ON = "carry on"
TICKS = 40
TICK_MS = 20
IO_TIMEOUT_MS = 5_000
# The longest a step waits for a task to hold a lock, and the longest a refused write may take. The refusal is also
# seen from the task, whose COMMIT fails when the write waits (the busy_timeout is 5000 ms), so this bound is the
# second check and is wide.
BLOCKED_WAIT_MS = 5_000
REFUSED_WRITE_MS = 4_000
PROBE_SQL = "select count(*) as n from sqlite_master"
NO_DATABASE = "no database is open"
NO_POOL = "no pool is started"
POOL_DRAIN_MS = 1_000
# The runs of the query in each task of `query_together`.
QUERY_REPEATS = 50
# `query_beside_long`: the time the long statement needs to start its step, the time the ticker needs to start, how
# long it ticks and the sleep between its ticks.
LONG_START_MS = 100
TICKER_START_MS = 20
TICKER_MS = 600
PAUSE_TICK_MS = 5
# `cancel_beside_long` cancels the write this soon after the long statement starts: the write sleeps between its tries
# (25 ms), and only a cancel in its sleep frees its cursor at once; once it tries again it waits in its own call.
CANCEL_AFTER_MS = 5
WRITER_END_MS = 10_000
# `execute_beside_waiting` lets the lock go once the write has waited this long: it then sleeps 25 ms between tries.
WRITER_WAITS_MS = 150
# `cache_beside_big` reads the statement cache this many times, a millisecond apart, while the big query runs.
CACHE_READS = 200
# `close_beside_queries`: the time the first statement needs to start, so that the second waits for it.
QUEUE_START_MS = 20
# The time a holder needs to take the connection of the pool before the step asks for one too.
HOLD_START_MS = 150
HOLDER_WAIT_MS = 5_000
# `pool_writers_in_turn`: the time between two writers that come to the line, and how long each holds its transaction.
ARRIVAL_MS = 50
TURN_HOLD_MS = 150
# `pool_turn_after`: a block that sleeps this long in its transaction runs past its lease.
STALL_MS = 10_000
# `pool_writers_readers`: the tasks that count the rows while the writers write.
READERS = 2

# The struct of the Orm scenarios: the table `people`, whose age is a value or NULL.
struct Person
  id: Int = 0
  name: String
  age: Optional[Int] = none
  admin: Bool
  score: Float
end

# The same table with an age that can also be absent: a column the query leaves out, or one a write leaves alone.
struct Partial
  id: Int = 0
  name: String
  age: JSON.Field[Int]
  admin: Bool
  score: Float
end

# A struct with a column that `people` lacks.
struct Ghost
  id: Int = 0
  name: String
  nickname: String
end

# A struct whose key is generated by the database but is not an Int.
struct Named
  id: String
  name: String
end

# A struct with nothing to write but its generated key.
struct Marker
  id: Int = 0
  note: JSON.Field[String]
end

# A struct whose key can be none.
struct MaybeKeyed
  id: Optional[Int] = none
  name: String
end

# A struct with a nested Optional, which no column holds.
struct Nested
  id: Int = 0
  age: Optional[Optional[Int]] = none
end

# A struct with a field that no column holds.
struct Tagged
  id: Int = 0
  tags: List[String]
end

# What the last request gave.
enum Outcome
  Nothing
  Failed(String)
  Counted(Int)
  Rows(List[Db.Row])
  Done
end

# `conns` holds the one connection, or none: a connection has no empty value; `pools` holds the one pool the same way.
# `checked` is true once an expectation has read `last`.
struct State
  conns: List[Db.Connection]
  pools: List[DbPool.Pool]
  adapter: String
  last: Outcome
  checked: Bool
end

struct Handled
  state: State
  reply: String
end

# A task that keeps a connection of the pool for `ms` milliseconds, in a transaction that has run `sql` when there is
# one, and tells on `got` that it holds the connection.
struct Holder
  pool: DbPool.Pool
  ms: Int
  sql: String
  got: Channel[Int]
end

# A task that keeps a connection of the pool for `ms` milliseconds.
struct Held
  pool: DbPool.Pool
  ms: Int
end

# A statement run in a task on the connection of the driver.
struct Job
  conn: Db.Connection
  sql: String
end

# A connection that a task opens and leaves open: the server shows its session by its id.
struct Leave
  url: String
  adapter: String
end

# The statements that a task runs in a transaction, on a connection that it opens at the url.
struct Writer
  url: String
  rows: List[List[String]]
end

# The writer number `writer`, which borrows its connection from the pool and writes its number.
struct TurnWriter
  pool: DbPool.Pool
  writer: Int
end

# A statement run in a task on a connection of its own.
struct Fresh
  url: String
  sql: String
end

# A query that a task ran, with the times at which it started and ended (the clock is the one of this process).
struct Timed
  started: Int
  ended: Int
  found: Result[List[Db.Row]]
end

# A task that holds the write lock of the database at the url for `ms` milliseconds.
struct Hold
  url: String
  ms: Int
end

# A connection whose write lock a task gives back after `ms` milliseconds.
struct Locked
  conn: Db.Connection
  ms: Int
end

# A writer of the pool that commits `count` transactions, each of two rows of its number `writer`, into `table`.
struct PoolWriter
  pool: DbPool.Pool
  table: String
  writer: Int
  count: Int
end

# A reader of the pool that counts the rows of `table` until `done` closes; every count must be even.
struct PoolReader
  pool: DbPool.Pool
  table: String
  done: Channel[Int]
end

def main() -> Void
  # The folder is the scenario's own (see `scratch_dir`): this removes it if it exists, so a driver that runs alone
  # starts from nothing.
  clean_scratch()
  state = State(conns: [], pools: [], adapter: "", last: Outcome.Nothing, checked: true)
  line = IO.gets
  while line.ok?
    handled = handle(state, line.unwrap_or(""))
    state = handled.state
    puts(handled.reply.replace("\n", "\\n"))
    IO.flush()
    line = IO.gets
  end

  clean_scratch()
end

# Every database of the scenarios.
def drivers() -> List[Db.Driver] = [Sqlite.driver(), Postgres.driver(), Mysql.driver()]

def handle(state: State, line: String) -> Handled
  case JSON.decode(line, Request)
    error(message) -> Handled(state: state, reply: "bad request: #{message}")
    ok(req) -> dispatch(state, req)
  end
end

def dispatch(state: State, req: Request) -> Handled
  case state.last
    Outcome.Failed(message) if not state.checked -> checking(state, req, message)
    _ -> act(state, req)
  end
end

# After a failure that no step has checked, only an expectation may come: any other request is refused.
def checking(state: State, req: Request, message: String) -> Handled
  case req
    Request.Expect(expectation) -> act_expecting(state, expectation)
    _ ->
      reply = "the previous statement failed with #{message.inspect}, and no step checked it"
      Handled(state: state, reply: reply)
  end
end

def act(state: State, req: Request) -> Handled
  case req
    Request.Open(a) -> opened(state, a.adapter)
    Request.OpenUrl(a) -> reply_ok(open_at(state, state.adapter, expand(state, a.url)))
    Request.Execute(a) -> reply_ok(with_params(state, a.sql, a.params, &execute))
    Request.Query(a) -> reply_ok(with_params(state, a.sql, a.params, &query))
    Request.QueryWithin(a) -> reply_ok(query_within(state, sql_of(state, a.sql), [], a.timeout_ms))
    Request.ExecuteWithin(a) -> reply_ok(execute_within(state, sql_of(state, a.sql), [], a.timeout_ms))
    Request.PoolStart(a) -> reply_ok(pool_start(state, a))
    Request.PoolQuery(a) -> reply_ok(pool_query(state, a))
    Request.PoolExecute(a) -> reply_ok(pool_execute(state, a))
    Request.PoolScript(a) -> reply_ok(pool_script(state, a.statements.drop(1)))
    Request.PoolCloseConnection(_) -> reply_ok(pool_close_connection(state))
    Request.PoolCrash(_) -> reply_ok(pool_crash(state))
    Request.PoolHold(a) -> reply_ok(pool_hold(state, a.ms))
    Request.PoolCancelHolder(a) -> reply_ok(pool_cancel_holder(state, a))
    Request.PoolWriteWithin(a) -> reply_ok(pool_write_within(state, a))
    Request.PoolRunsIn(a) -> reply_ok(pool_runs_in(state, a.place))
    Request.PoolQueryWhileHeld(a) -> reply_ok(pool_query_while_held(state, a))
    Request.PoolTransaction(a) -> reply_ok(pool_transaction(state, a))
    Request.PoolCommits(a) -> reply_ok(pool_commits(state, a))
    Request.PoolWritersReaders(a) -> reply_ok(pool_writers_readers(state, a))
    Request.PoolShortCalls(_) -> reply_ok(pool_short_calls(state))
    Request.PoolFallbacks(_) -> reply_ok(pool_fallbacks(state))
    Request.PoolRepeat(a) -> reply_ok(pool_repeat(state, a))
    Request.PoolClose(_) -> reply_ok(pool_close(state))
    Request.ShortCalls(_) -> reply_ok(short_calls(state))
    Request.Fallbacks(_) -> reply_ok(fallbacks(state))
    Request.FileSize(a) -> file_size(state, a)
    Request.PoolShortCallsAtMost(a) -> short_calls_at_most(pool_short_calls(state), a.most)
    Request.TransactionWhileLocked(a) -> transaction_while_locked(state, a)
    Request.InTransaction(_) -> check_connection(state, "in_transaction") do |conn| Db.in_transaction?(conn) end
    Request.NotInTransaction(_) ->
      check_connection(state, "not_in_transaction") do |conn| not Db.in_transaction?(conn) end
    Request.Healthy(_) -> check_connection(state, "healthy") do |conn| Db.healthy?(conn) end
    Request.NotHealthy(_) -> check_connection(state, "not_healthy") do |conn| not Db.healthy?(conn) end
    Request.Transaction(a) -> reply_ok(transaction(state, a))
    Request.OrmQuery(a) -> reply_ok(with_params(state, a.sql, a.params, &orm_query))
    Request.OrmPartialQuery(a) -> reply_ok(with_params(state, a.sql, a.params, &partial_query))
    Request.OrmQueryAs(a) -> reply_ok(orm_query_as(state, Cells.expand(a.sql)))
    Request.OrmDecode(a) -> reply_ok(orm_decode(state, a.sql))
    Request.OrmCheck(a) -> reply_ok(orm_check(state, a.schema))
    Request.OrmInsert(a) -> reply_ok(orm_insert(state, a))
    Request.OrmInsertPartial(a) -> reply_ok(orm_insert_partial(state, a))
    Request.OrmBuilder(a) -> reply_ok(orm_builder(state, a.ending, a.steps))
    Request.OrmFind(a) -> reply_ok(orm_find(state, a.key))
    Request.OrmMarker(a) -> reply_ok(orm_marker(state, a.action))
    Request.OrmUpdate(a) -> reply_ok(orm_update(state, people(), person_of(a.rows)))
    Request.OrmUpdatePartial(a) -> reply_ok(orm_update(state, partials(), partial_of(a.rows)))
    Request.OrmPatch(a) -> reply_ok(orm_patch(state, a.key, a.changes))
    Request.OrmDelete(a) -> reply_ok(orm_delete(state, a))
    Request.OrmDeleteTyped(a) -> reply_ok(orm_delete_typed(state, a.key))
    Request.Close(_) -> reply_ok(close(state))
    Request.Migrate(a) -> reply_ok(migrate(state, a))
    Request.ReadOnly(a) -> reply_ok(set_access(state, expand(state, a.path), false))
    Request.Writable(a) -> reply_ok(set_access(state, expand(state, a.path), true))
    Request.WriteTogether(a) -> reply_ok(write_together(state, a))
    Request.PoolWritersInTurn(a) -> reply_ok(pool_writers_in_turn(state, a))
    Request.PoolTurnAfter(a) -> reply_ok(pool_turn_after(state, a))
    Request.PoolNestedTransaction(a) -> reply_ok(pool_nested_transaction(state, a))
    Request.ExecuteWaiting(a) -> execute_waiting(state, a)
    Request.ExecuteFresh(a) -> reply_ok(execute_fresh(state, a))
    Request.QueryUntilCommit(a) -> query_until_commit(state, a)
    Request.WriteWhileBlocked(a) -> write_while_blocked(state, a)
    Request.QueryWhileLocked(a) -> query_while_locked(state, a)
    Request.OpenWhileLocked(a) -> open_while_locked(state, a)
    Request.ExecuteInTask(a) -> reply_ok(execute_in_task(state, a.sql))
    Request.QueryTogether(a) -> reply_ok(query_together(state, a))
    Request.QueryBesideLong(a) -> reply_ok(query_beside_long(state, a))
    Request.CancelBesideLong(a) -> reply_ok(cancel_beside_long(state, a))
    Request.ExecuteBesideWaiting(a) -> reply_ok(execute_beside_waiting(state, a))
    Request.OnOther(a) -> reply_ok(on_other(state, a))
    Request.QueryBigJson(a) -> reply_ok(query_big_json(state, a))
    Request.QueryJsonList(a) -> reply_ok(query_json_list(state, a))
    Request.StatementCache(_) -> reply_ok(statement_cache(state))
    Request.MysqlFlavor(_) -> Handled(state: state, reply: mysql_flavor(state))
    Request.DriverNamed(a) -> reply_ok(driver_named(state, a.variable))
    Request.CancelTask(a) -> reply_ok(cancel_task(state, a))
    Request.QueryEach(a) -> reply_ok(query_each(state, a))
    Request.CacheBesideBig(a) -> reply_ok(cache_beside_big(state, a))
    Request.CloseBesideQueries(a) -> reply_ok(close_beside_queries(state, a))
    Request.QueryInNewTask(a) -> reply_ok(query_in_new_task(state, a.sql))
    Request.RoundTrips(a) -> round_trips(state, a.rows)
    Request.FloatOracle(a) -> float_oracle(state, a.literal)
    Request.KeepRunning(a) -> keep_running(state, a.sql, a.gap_ms)
    Request.LeaveOpen(a) -> leave_open(state, a.limit_ms)
    Request.NoneRunning(a) -> none_running(state, a.marker, a.limit_ms)
    Request.Expect(expectation) -> act_expecting(state, expectation)
    Request.OrmDecodeTagged(a) -> reply_ok(orm_decode_tagged(state, a.sql))
  end
end

def act_expecting(state: State, expectation: Expectation) -> Handled
  case expectation
    Expectation.ExpectOk(_) -> expect(state, judge_ok(state.last))
    Expectation.ExpectTimeout(_) ->
      expect(state, judge_failure(state.last, "that is a timeout", "") do |message| Db.timeout?(message) end)
    Expectation.ExpectCount(a) -> expect(state, judge_count(state.last, a.count))
    Expectation.ExpectRows(a) -> expect(state, judge_rows(state.last, a.rows))
    Expectation.ExpectLast(a) -> expect(state, judge_last(state.last, a.count, a.rows))
    Expectation.ExpectPrefix(a) ->
      wanted = Cells.expand(a.text)
      expect(state, judge_failure(state.last, "starting with", wanted) do |message| message.start_with?(wanted) end)
    Expectation.ExpectExact(a) ->
      wanted = Cells.expand(a.text)
      expect(state, judge_failure(state.last, "exactly", wanted) do |message| message == wanted end)
    Expectation.ExpectMentions(a) ->
      wanted = Cells.expand(a.text)
      expect(state, judge_failure(state.last, "mentioning", wanted) do |message| message.include?(wanted) end)
    Expectation.ExpectHides(a) ->
      wanted = Cells.expand(a.text)
      expect(state, judge_failure(state.last, "never showing", wanted) do |message| not message.include?(wanted) end)
    Expectation.ExpectKind(a) -> expect(state, judge_kind(state.last, Cells.expand(a.kind)))
  end
end

def reply_ok(state: State) -> Handled = Handled(state: state, reply: Protocol.OK)

def recorded(state: State, outcome: Outcome) -> State
  State(conns: state.conns, pools: state.pools, adapter: state.adapter, last: outcome, checked: false)
end

def failed(state: State, message: String) -> State = recorded(state, Outcome.Failed(message))

# The server url is the variable of the adapter; the step reports a missing variable.
def server_url(adapter: String) -> String
  return System.env(URL_VARIABLES[adapter]).unwrap_or("") if URL_VARIABLES.key?(adapter)

  SQLITE_MEMORY
end

# The `open` request of the first step: the adapter by name. A database that does not open ends the scenario.
def opened(state: State, adapter: String) -> Handled
  if adapter != "sqlite" and not URL_VARIABLES.key?(adapter)
    return Handled(state: state, reply: "unknown adapter #{adapter.inspect}")
  end

  opened = open_at(state, adapter, server_url(adapter))
  case opened.last
    Outcome.Failed(message) -> Handled(state: opened, reply: "the #{adapter} database did not open: #{message}")
    _ -> reply_ok(opened)
  end
end

# The one way to open: the old connection is closed first. A failure leaves no connection.
def open_at(state: State, adapter: String, url: String) -> State
  state.conns.each do |conn| Db.close(conn) end
  if url.include?(scratch_dir())
    _ = Dir.mkdir(scratch_dir(), IO_TIMEOUT_MS)
  end

  case Db.open(url, drivers())
    error(message) ->
      State(conns: [], pools: state.pools, adapter: adapter, last: Outcome.Failed(message.message), checked: false)
    ok(conn) -> State(conns: [conn], pools: state.pools, adapter: adapter, last: Outcome.Done, checked: false)
  end
end

# The markers of a step text. `[URL]` is the server url of the adapter, and `[URL]&name=value` adds a url parameter
# with the right separator; `[SERVER]` is the url without its scheme; `[ADDRESS]` is its host and port, without the
# user, the password and the path; `[SCRATCH]` is a folder under tmp/, for the files of a SQLite database.
def expand(state: State, text: String) -> String
  url = server_url(state.adapter)
  without_scheme = url
  if url.include?("://")
    without_scheme = url.split("://").drop(1).join("://")
  end

  separator = "?"
  if url.include?("?")
    separator = "&"
  end

  expanded = Cells.expand(text)
  expanded = expanded.replace("[URL]&", "#{url}#{separator}")
  expanded = expanded.replace("[URL]", url)
  expanded = expanded.replace("[SERVER]", without_scheme)
  expanded = expanded.replace("[ADDRESS]", address(without_scheme))
  expanded.replace("[SCRATCH]", scratch_dir())
end

# The host and port of a url without its scheme: after the last `@`, up to the first `/` or `?`.
def address(without_scheme: String) -> String
  host = without_scheme.split("@").last
  host.split("/")[0].split("?")[0]
end

def scratch_dir() -> String = System.env(SCRATCH_VARIABLE).unwrap_or(SCRATCH_DEFAULT)

# The sql of a step: [SLOW] and [WORK] are the statements of the adapter, then the markers of a cell.
def sql_of(state: State, text: String) -> String
  slow = SLOW_SQL.get(state.adapter, "")
  work = WORK_SQL.get(state.adapter, "")
  Cells.expand(text.replace("[SLOW]", slow).replace("[WORK]", work))
end

# Closes the pool of the scenario, if any, and starts the one the request names: the url (with its markers) and a table
# of options, a header and a name and value per row. A pool that does not start is the outcome of the step.
def pool_start(state: State, req: Protocol.PoolStart) -> State
  state.pools.each do |old| DbPool.close(old, POOL_DRAIN_MS) end
  url = expand(state, req.url)
  if url.include?(scratch_dir())
    _ = Dir.mkdir(scratch_dir(), IO_TIMEOUT_MS)
  end

  stopped = State(conns: state.conns, pools: [], adapter: state.adapter, last: Outcome.Done, checked: false)
  case pool_options(url, req.options.drop(1))
    error(message) -> failed(stopped, message.message)
    ok(options) ->
      case DbPool.start(options)
        error(message) -> failed(stopped, message.message)
        ok(pool) ->
          State(conns: stopped.conns, pools: [pool], adapter: stopped.adapter, last: Outcome.Done, checked: false)
      end
  end
end

def pool_options(url: String, rows: List[List[String]]) -> Result[DbPool.Options]
  options = DbPool.Options(url: url, drivers: drivers())
  for row in rows
    options = try pool_setting(options, row[0], row[1])
  end

  ok(options)
end

def pool_setting(options: DbPool.Options, name: String, value: String) -> Result[DbPool.Options]
  case name
    "size" -> ok(options.with(size: try value.to_i))
    "max_overflow" -> ok(options.with(max_overflow: try value.to_i))
    "checkout_ms" -> ok(options.with(checkout_ms: try value.to_i))
    "lease_ms" -> ok(options.with(lease_ms: try value.to_i))
    "max_waiting" -> ok(options.with(max_waiting: try value.to_i))
    "health_ms" -> ok(options.with(health_ms: try value.to_i))
    "checkpoint_frames" -> ok(options.with(checkpoint_frames: try value.to_i))
    "checkpoint_ms" -> ok(options.with(checkpoint_ms: try value.to_i))
    "checkpoint_cap" -> ok(options.with(checkpoint_cap: try value.to_i))
    _ -> error("unknown pool option #{name.inspect}")
  end
end

# Runs `run` with the pool, or records the failure of having none.
def with_pool(state: State, run: Fn[DbPool.Pool, State]) -> State
  return failed(state, NO_POOL) if state.pools.empty?

  run.call(state.pools[0])
end

# One block of the pool runs the statement, and the pool checks the connection in after it. The `timeout_ms` of the
# request is the one of the call (`CONNECTION_DEFAULT` for none).
def pool_query(state: State, req: Protocol.PoolQuery) -> State
  with_pool(state) do |pool|
    sql = sql_of(state, req.sql)
    found = DbPool.with(pool) do |conn| Db.query(conn, sql, [], req.timeout_ms) end
    case found
      error(message) -> return failed(state, message.message)
      ok(rows) -> return recorded(state, Outcome.Rows(rows))
    end
  end
end

def pool_execute(state: State, req: Protocol.PoolExecute) -> State
  with_pool(state) do |pool|
    sql = sql_of(state, req.sql)
    found = DbPool.with(pool) do |conn| Db.execute(conn, sql, [], req.timeout_ms) end
    case found
      error(message) -> return failed(state, message.message)
      ok(count) -> return recorded(state, Outcome.Counted(count))
    end
  end
end

# The statements of the table (the header row is skipped) run in one block, one after the other, and the first failure
# ends the block. Nothing commits or rolls back: a BEGIN in them is left open for the pool to deal with.
def pool_script(state: State, rows: List[List[String]]) -> State
  with_pool(state) do |pool|
    found = DbPool.with(pool) do |conn| run_rows(conn, rows) end
    case found
      error(message) -> return failed(state, message.message)
      ok(_) -> return recorded(state, Outcome.Done)
    end
  end
end

# A block that closes the connection it was lent and ends with ok.
def pool_close_connection(state: State) -> State
  with_pool(state) do |pool|
    found = DbPool.with(pool) do |conn|
      Db.close(conn)
      ok()
    end

    case found
      error(message) -> return failed(state, message.message)
      ok(_) -> return recorded(state, Outcome.Done)
    end
  end
end

# A block that crashes (`to_i!` of a text that is not a number halts the task of the block).
def pool_crash(state: State) -> State
  with_pool(state) do |pool|
    # The crash is inside a transaction, which holds the turn of the writers of a SQLite pool.
    found = DbPool.with(pool) do |conn| Db.transaction(conn) do |_tx| ok("not a number".to_i!) end end
    case found
      error(message) -> return failed(state, message.message)
      ok(_) -> return recorded(state, Outcome.Done)
    end
  end
end

# A block that keeps its connection for `ms` milliseconds.
def pool_hold(state: State, ms: Int) -> State
  with_pool(state) do |pool|
    case hold(Held(pool: pool, ms: ms))
      error(message) -> return failed(state, message.message)
      ok(_) -> return recorded(state, Outcome.Done)
    end
  end
end

# A task takes a connection, runs `req.sql` in a transaction when it is not empty, keeps the connection for
# `req.hold_ms` milliseconds and is cancelled once it has the connection (it says so on a channel), and this one waits
# until the task has ended. The outcome is Done: what the pool does with the connection shows in the next steps.
def pool_cancel_holder(state: State, req: Protocol.PoolCancelHolder) -> State
  with_pool(state) do |pool|
    got: Channel[Int] = Channel.new(1)
    holder = Task.spawn(&hold_signalling, Holder(pool: pool, ms: req.hold_ms, sql: sql_of(state, req.sql), got: got))
    return failed(state, "the task never held a connection") if not got.recv(HOLDER_WAIT_MS).ok?

    Task.cancel(holder)
    _ = Task.await(holder)
    return recorded(state, Outcome.Done)
  end
end

def hold_signalling(job: Holder) -> Result[Void]
  DbPool.with(job.pool) do |conn|
    if job.sql.empty?
      _ = job.got.send(1, 0)
      Task.sleep(job.ms)
      return ok()
    end

    Db.transaction(conn) do |tx|
      try Db.execute(tx, job.sql, [])
      _ = job.got.send(1, 0)
      Task.sleep(job.ms)
      ok()
    end
  end
end

# One write in a block of the pool, which fails when it took `req.limit_ms` ms or more: a connection left in a
# transaction would hold SQLite's lock for the wait of `busy_timeout`.
def pool_write_within(state: State, req: Protocol.PoolWriteWithin) -> State
  with_pool(state) do |pool|
    started = Time.monotonic_ms()
    done = DbPool.with(pool) do |conn| Db.execute(conn, sql_of(state, req.sql), []) end
    took = Time.monotonic_ms() - started
    return failed(state, "the write took #{took} ms") if took >= req.limit_ms

    return counted(state, done)
  end
end

# Whether a block of the pool runs in the task of its caller (`lease_ms` 0) or in a task of the pool, as `place`
# says: `caller` or `pool`.
def pool_runs_in(state: State, expected: String) -> State
  with_pool(state) do |pool|
    caller = Task.current().id
    inside = DbPool.with(pool) do |_conn| ok(Task.current().id) end
    case inside
      error(message) -> return failed(state, message.message)
      ok(id) if (id == caller) == (expected == "caller") -> return recorded(state, Outcome.Done)
      ok(_) -> return failed(state, "the block did not run in the task of the #{expected}")
    end
  end
end

def hold(job: Held) -> Result[Void]
  DbPool.with(job.pool) do |_conn|
    Task.sleep(job.ms)
    ok()
  end
end

# A task takes a connection and keeps it for `req.hold_ms` milliseconds while this one asks for a connection too. The
# outcome is the one of this query; the task is awaited, so nothing runs on after the step.
def pool_query_while_held(state: State, req: Protocol.PoolQueryWhileHeld) -> State
  with_pool(state) do |pool|
    holder = Task.spawn(&hold, Held(pool: pool, ms: req.hold_ms))
    Task.sleep(HOLD_START_MS)
    asked = pool_query(state, Protocol.PoolQuery(sql: req.sql, timeout_ms: Db.CONNECTION_DEFAULT))
    _ = Task.await(holder)
    return asked
  end
end

# The statements of the table (the header row is skipped) run in one transaction in one block of the pool. With a
# `stop_ms` above 0, a ticker task runs meanwhile, and the outcome is a failure when the scheduler stopped for
# that many
# milliseconds or more: a write that runs long must not run in a short call.
def pool_transaction(state: State, req: Protocol.PoolTransaction) -> State
  with_pool(state) do |pool|
    rows = req.statements.drop(1)
    if req.stop_ms <= 0
      return checked(state, DbPool.with(pool) do |conn| Db.transaction(conn) do |tx| run_rows(tx, rows) end end)
    end

    ticker = Task.spawn(&longest_pause, TICKER_MS)
    Task.sleep(TICKER_START_MS)
    done = DbPool.with(pool) do |conn| Db.transaction(conn) do |tx| run_rows(tx, rows) end end
    case Task.await(ticker)
      error(message) -> return failed(state, message.message)
      ok(ms) if ms >= req.stop_ms -> return failed(state, "the scheduler stopped for #{ms} ms")
      ok(_) -> return checked(state, done)
    end
  end
end

# `req.count` transactions, one after the other, each in a block of the pool, each running the statement `req.sql`.
def pool_commits(state: State, req: Protocol.PoolCommits) -> State
  with_pool(state) do |pool|
    sql = sql_of(state, req.sql)
    for _ in 0...req.count
      done = DbPool.with(pool) do |conn| Db.transaction(conn) do |tx| Db.execute(tx, sql, []) end end
      return failed(state, done.message) if not done.ok?
    end

    return recorded(state, Outcome.Done)
  end
end

# `req.writers` writers of the pool commit `req.commits` transactions each, of two rows, into the table `req.table`,
# while READERS readers count its rows in other blocks of the pool: a reader that sees an odd count saw half of a
# transaction. The outcome is the first failure, if any.
def pool_writers_readers(state: State, req: Protocol.PoolWritersReaders) -> State
  with_pool(state) do |pool|
    count = req.commits
    done: Channel[Int] = Channel.new(1)
    readers: List[Task[Result[Int]]] = []
    for _ in 0...READERS
      readers = readers.push(Task.spawn(&count_rows, PoolReader(pool: pool, table: req.table, done: done)))
    end

    writers: List[Task[Result[Void]]] = []
    for writer in 1..req.writers
      job = PoolWriter(pool: pool, table: req.table, writer: writer, count: count)
      writers = writers.push(Task.spawn(&write_rows, job))
    end

    failures: List[String] = []
    for task in writers
      written = Task.await(task)
      if not written.ok?
        failures = failures.push(written.message)
      end
    end

    done.close
    for task in readers
      read = Task.await(task)
      if not read.ok?
        failures = failures.push(read.message)
      end
    end

    return failed(state, failures[0]) if not failures.empty?

    return recorded(state, Outcome.Done)
  end
end

def write_rows(job: PoolWriter) -> Result[Void]
  sql = "insert into #{job.table} (writer) values (?)"
  for _ in 0...job.count
    try DbPool.with(job.pool) do |conn|
      Db.transaction(conn) do |tx|
        try Db.execute(tx, sql, [Db.Value.Int(job.writer)])
        Db.execute(tx, sql, [Db.Value.Int(job.writer)])
      end
    end
  end

  ok()
end

# The counts it read, each even, until the writers are done.
def count_rows(job: PoolReader) -> Result[Int]
  reads = 0
  sql = "select count(*) as n from #{job.table}"
  while not job.done.closed?
    found = try DbPool.with(job.pool) do |conn| Db.query(conn, sql, []) end
    n = try int_of(found)
    return error("a reader saw #{n} rows, half of a transaction") if n % 2 != 0

    reads += 1
    Task.sleep(1)
  end

  ok(reads)
end

def pool_close(state: State) -> State
  state.pools.each do |pool| DbPool.close(pool, POOL_DRAIN_MS) end
  State(conns: state.conns, pools: [], adapter: state.adapter, last: Outcome.Done, checked: false)
end

# How many statements ran whole in a short call on the connection of a block of the pool, as one row.
def pool_short_calls(state: State) -> State = pool_stat(state, "shorts")

# How many short calls ran a statement and then left it to the compute pool (a value too long, rows past the caps, a
# lock), on the connection of a block of the pool, as one row.
def pool_fallbacks(state: State) -> State = pool_stat(state, "fallbacks")

def pool_stat(state: State, name: String) -> State
  with_pool(state) do |pool|
    found = DbPool.with(pool) do |conn| ok(stat_of(conn, name)) end
    case found
      error(message) -> return failed(state, message.message)
      ok(row) -> return stat_row(state, name, row)
    end
  end
end

# Checks the count that `pool_short_calls` just recorded against its most, `most`.
def short_calls_at_most(state: State, most: Int) -> Handled
  case state.last
    Outcome.Failed(message) -> Handled(state: state, reply: message)
    Outcome.Rows(rows) ->
      case rows.first.get("shorts")
        some(Db.Value.Int(n)) if n > most -> Handled(state: state, reply: "#{n} statements ran in a short call")
        _ -> reply_ok(state)
      end

    _ -> Handled(state: state, reply: "no count of short calls")
  end
end

def short_calls(state: State) -> State
  with_conn(state) do |conn| stat_row(state, "shorts", stat_of(conn, "shorts")) end
end

def fallbacks(state: State) -> State
  with_conn(state) do |conn| stat_row(state, "fallbacks", stat_of(conn, "fallbacks")) end
end

def stat_of(conn: Db.Connection, name: String) -> Optional[Int]
  return none if conn.adapter != Db.Adapter.Sqlite

  Db.statement_cache(conn).map do |c| pick_stat(c, name) end
end

def pick_stat(stats: Db.CacheStats, name: String) -> Int
  return stats.fallbacks if name == "fallbacks"

  stats.shorts
end

def stat_row(state: State, name: String, found: Optional[Int]) -> State
  case found
    none -> failed(state, "only the native SQLite driver runs short calls")
    some(n) if name == "fallbacks" -> recorded(state, Outcome.Rows([{"fallbacks": Db.Value.Int(n)}]))
    some(n) -> recorded(state, Outcome.Rows([{"shorts": Db.Value.Int(n)}]))
  end
end

# One transaction in a block of the pool that runs the statement `req.sql` `req.times` times.
def pool_repeat(state: State, req: Protocol.PoolRepeat) -> State
  with_pool(state) do |pool|
    sql = sql_of(state, req.sql)
    done = DbPool.with(pool) do |conn|
      Db.transaction(conn) do |tx|
        for _ in 0...req.times
          try Db.execute(tx, sql, [])
        end

        return ok()
      end
    end

    return checked(state, done)
  end
end

# A connection of its own to `req.url` takes the write lock, and a task gives it back after `req.hold_ms` ms, while
# the statements of the table run in a transaction on the connection of the scenario: its BEGIN must wait for the lock,
# for at least half of that time, and then work.
def transaction_while_locked(state: State, req: Protocol.TransactionWhileLocked) -> Handled
  return reply_ok(failed(state, NO_DATABASE)) if state.conns.empty?

  case Db.open(expand(state, req.url), drivers())
    error(message) -> Handled(state: state, reply: message.message)
    ok(other) ->
      taken = Db.execute(other, "BEGIN IMMEDIATE", [])
      if not taken.ok?
        Db.close(other)
        return Handled(state: state, reply: taken.message)
      end

      holder = Task.spawn(&unlock_after, Locked(conn: other, ms: req.hold_ms))
      started = Time.monotonic_ms()
      done = Db.transaction(state.conns[0]) do |tx| run_rows(tx, req.statements.drop(1)) end
      waited = Time.monotonic_ms() - started
      _ = Task.await(holder)
      Db.close(other)
      if waited < req.hold_ms / 2
        return Handled(state: state, reply: "the transaction took #{waited} ms, it did not wait for the lock")
      end

      reply_ok(checked(state, done))
  end
end

def unlock_after(job: Locked) -> Result[Int]
  Task.sleep(job.ms)
  Db.execute(job.conn, "COMMIT", [])
end

# An expectation: the file `req.path` (with its markers) exists and holds at most `req.most_bytes` bytes.
def file_size(state: State, req: Protocol.FileSize) -> Handled
  path = expand(state, req.path)
  case File.stat(path, IO_TIMEOUT_MS)
    error(message) -> Handled(state: state, reply: message.message)
    ok(info) if info.size_bytes > req.most_bytes -> Handled(state: state, reply: "it holds #{info.size_bytes} bytes")
    ok(_) -> reply_ok(state)
  end
end

# Runs `Migrate.up` with the rows of the table (`version`, `name`, `sql`; the header row is skipped). The sql cell
# holds statements separated by `;` (no `;` inside a literal), or `code:` and one statement that a function migration
# runs. The outcome is the versions applied, one row each, so a re-run shows no row. `history` is the history table, or
# empty for the default.
def migrate(state: State, req: Protocol.MigrateRun) -> State
  with_conn(state) do |conn|
    list = req.migrations.drop(1).map do |row| migration_of(row) end
    done = migrate_run(conn, list, req.history)
    case done
      error(message) -> return failed(state, message.message)
      ok(versions) -> return recorded(state, Outcome.Rows(versions.map do |v| {"version": Db.Value.Int(v)} end))
    end
  end
end

def migrate_run(conn: Db.Connection, list: List[Migrate.Migration], table: String) -> Result[List[Int]]
  return Migrate.up(conn, list) if table.empty?

  Migrate.up(conn, list, table)
end

def migration_of(row: List[String]) -> Migrate.Migration
  version = row[0].to_i.unwrap_or(0)
  sql = Cells.expand(row[2])
  if sql.start_with?("code:")
    statement = sql.slice(5, sql.length - 5)
    return Migrate.code(version, row[1]) do |tx|
      case Db.execute(tx, statement, [])
        error(message) -> return error(message)
        ok(_) -> return ok()
      end
    end
  end

  Migrate.sql(version, row[1], sql.split(";").map do |part| part.strip end)
end

# Removes the folder of the scenario. A scenario that failed between `read_only` and `writable` leaves a read-only
# file, which Windows refuses to remove, so it is made writable first (only when it exists: a process costs time).
def clean_scratch() -> Void
  locked = "#{scratch_dir()}/readonly.db"
  if File.stat(locked, IO_TIMEOUT_MS).ok?
    set_access(State(conns: [], pools: [], adapter: "", last: Outcome.Nothing, checked: true), locked, true)
  end

  _ = Path.remove(scratch_dir(), IO_TIMEOUT_MS)
end

# Makes a file read-only, or writable again: `chmod` on Unix, `attrib` on Windows (where a read-only file cannot be
# removed, so a scenario makes it writable before it ends). The process is the only way, there is no chmod in Agentica.
def set_access(state: State, path: String, writable: Bool) -> State
  command = "chmod"
  args = ["444", path]
  if writable
    args = ["644", path]
  end

  if System.os() == "windows"
    command = "attrib.exe"
    flag = "+R"
    if writable
      flag = "-R"
    end

    args = [flag, path.replace("/", "\\")]
  end

  started = Process.spawn(command, args, Process.Options(timeout_ms: IO_TIMEOUT_MS))
  case started
    error(message) -> failed(state, message.message)
    ok(process) ->
      code = Process.wait(process, IO_TIMEOUT_MS).unwrap_or(-1)
      return failed(state, "#{command} failed with #{code}") if code != 0

      recorded(state, Outcome.Done)
  end
end

# Runs `run` with the connection, or records the failure of having none.
def with_conn(state: State, run: Fn[Db.Connection, State]) -> State
  return failed(state, NO_DATABASE) if state.conns.empty?

  run.call(state.conns[0])
end

def with_params(state: State, sql: String, cells: List[String], run: Fn[State, String, List[Db.Value], State]) -> State
  case Cells.parse_all(cells)
    error(message) -> failed(state, message.message)
    ok(params) -> run.call(state, sql_of(state, sql), params)
  end
end

def execute(state: State, sql: String, params: List[Db.Value]) -> State
  execute_within(state, sql, params, Db.CONNECTION_DEFAULT)
end

def query(state: State, sql: String, params: List[Db.Value]) -> State
  query_within(state, sql, params, Db.CONNECTION_DEFAULT)
end

def execute_within(state: State, sql: String, params: List[Db.Value], timeout_ms: Int) -> State
  with_conn(state) do |conn|
    case Db.execute(conn, sql, params, timeout_ms)
      error(message) -> return failed(state, message.message)
      ok(count) -> return recorded(state, Outcome.Counted(count))
    end
  end
end

def query_within(state: State, sql: String, params: List[Db.Value], timeout_ms: Int) -> State
  with_conn(state) do |conn|
    case Db.query(conn, sql, params, timeout_ms)
      error(message) -> return failed(state, message.message)
      ok(rows) -> return recorded(state, Outcome.Rows(rows))
    end
  end
end

# The answer of `Db.in_transaction?` or `Db.healthy?`, as `answer` reads it, must be true. A closed connection is still
# the connection of the state, which is how a step asks about it.
def check_connection(state: State, name: String, answer: Fn[Db.Connection, Bool]) -> Handled
  return Handled(state: state, reply: NO_DATABASE) if state.conns.empty?

  return reply_ok(state) if answer.call(state.conns[0])

  Handled(state: state, reply: "the connection did not answer for #{name}")
end

# The query of the table of steps (the header row is skipped), then its end: the rows of the persons read, or the
# count of the rows `count`, `update_all` and `delete_all` gave.
def orm_builder(state: State, ending: String, table: List[List[String]]) -> State
  with_conn(state) do |conn|
    case build(table.drop(1))
      error(message) -> return failed(state, message.message)
      ok(query) -> return finished(state, conn, ending, query, changes_of(table.drop(1)))
    end
  end
end

def finished(state: State, conn: Db.Connection, ending: String, query: Orm.Query[Person], changes: String) -> State
  case ending
    "all" -> persons(state, Orm.all(query, conn))
    "one" -> persons(state, optional(Orm.one(query, conn)))
    "count" -> counted(state, Orm.count(query, conn))
    "delete_all" -> counted(state, Orm.delete_all(query, conn))
    _ -> counted(state, update_all(query, conn, changes))
  end
end

def update_all(query: Orm.Query[Person], conn: Db.Connection, changes: String) -> Result[Int]
  Orm.update_all(query, conn, try JSON.parse(changes))
end

# The `changes` row of the table, or an empty object.
def changes_of(rows: List[List[String]]) -> String
  found = rows.select do |row| row[0] == "changes" end
  return "{}" if found.empty?

  found[0][1]
end

def build(rows: List[List[String]]) -> Result[Orm.Query[Person]]
  query = Orm.from(people())
  for row in rows
    query = try step(query, row[0], row[1], row[2])
  end

  ok(query)
end

def step(query: Orm.Query[Person], name: String, argument: String, cells: String) -> Result[Orm.Query[Person]]
  case name
    "where_eq" -> ok(Orm.where_eq(query, argument, try Cells.parse(cells)))
    "where_in" -> ok(Orm.where_in(query, argument, try Cells.parse_all(listed(cells))))
    "where" -> ok(Orm.where(query, argument, try Cells.parse_all(listed(cells))))
    "order_by" -> ok(Orm.order_by(query, argument))
    "order_by_desc" -> ok(Orm.order_by_desc(query, argument))
    "limit" -> ok(Orm.limit(query, try argument.to_i))
    "offset" -> ok(Orm.offset(query, try argument.to_i))
    "changes" -> ok(query)
    _ -> error("unknown builder step #{name.inspect}")
  end
end

# The typed cells of a table cell, apart by `; `.
def listed(cells: String) -> List[String]
  return [] if cells.empty?

  cells.split("; ")
end

def persons(state: State, found: Result[List[Person]]) -> State
  case found
    error(message) -> failed(state, message.message)
    ok(list) -> recorded(state, Outcome.Rows(list.map do |person| person_row(person) end))
  end
end

def optional(found: Result[Optional[Person]]) -> Result[List[Person]]
  case try found
    some(person) -> ok([person])
    none -> ok([])
  end
end

def orm_find(state: State, key: String) -> State
  with_conn(state) do |conn|
    case Cells.parse(key)
      error(message) -> return failed(state, message.message)
      ok(id) -> return persons(state, optional(Orm.find(conn, people(), id)))
    end
  end
end

def people() -> Orm.Schema[Person] = Orm.schema("people", Person.codec)

def partials() -> Orm.Schema[Partial] = Orm.schema("people", Partial.codec)

# The persons read, shown as rows: an age shows its value or Null.
def orm_query(state: State, sql: String, params: List[Db.Value]) -> State
  read_rows(state, people(), sql, params, &person_row)
end

# The partial persons read: an age shows its value, Null, or `Text absent` for a column left out.
def partial_query(state: State, sql: String, params: List[Db.Value]) -> State
  read_rows(state, partials(), sql, params, &partial_row)
end

def read_rows[T](state: State, schema: Orm.Schema[T], sql: String, params: List[Db.Value], row: Fn[T, Db.Row]) -> State
  with_conn(state) do |conn|
    case Orm.query(conn, schema, sql, params)
      error(message) -> return failed(state, message.message)
      ok(found) -> return recorded(state, Outcome.Rows(found.map do |value| row.call(value) end))
    end
  end
end

def person_row(person: Person) -> Db.Row
  age = person.age.map do |years| Db.Value.Int(years) end
  {
    "id": Db.Value.Int(person.id),
    "name": Db.Value.Text(person.name),
    "age": age.unwrap_or(Db.Value.Null),
    "admin": Db.Value.Bool(person.admin),
    "score": Db.Value.Float(person.score),
  }
end

def partial_row(partial: Partial) -> Db.Row
  person = Person(id: partial.id, name: partial.name, admin: partial.admin, score: partial.score)
  person_row(person).put("age", age_value(partial.age))
end

def age_value(age: JSON.Field[Int]) -> Db.Value
  case age
    JSON.Field.Value(years) -> Db.Value.Int(years)
    JSON.Field.Null -> Db.Value.Null
    JSON.Field.Absent -> Db.Value.Text("absent")
  end
end

# Decodes by hand: the name of each row.
def orm_query_as(state: State, sql: String) -> State
  with_conn(state) do |conn|
    found = Orm.query_as(conn, sql, []) do |row| name_of(row) end
    case found
      error(message) -> return failed(state, message.message)
      ok(names) -> return recorded(state, Outcome.Rows(names.map do |name| {"name": Db.Value.Text(name)} end))
    end
  end
end

# Decodes with `Orm.decode_row`: the Person of each row.
def orm_decode(state: State, sql: String) -> State
  with_conn(state) do |conn|
    found = Orm.query_as(conn, sql, []) do |row| Orm.decode_row(row, Person.codec) end
    case found
      error(message) -> return failed(state, message.message)
      ok(persons) -> return recorded(state, Outcome.Rows(persons.map do |person| person_row(person) end))
    end
  end
end

# Decodes into a struct that no column can hold: it fails before any column is read.
def orm_decode_tagged(state: State, sql: String) -> State
  with_conn(state) do |conn|
    found = Orm.query_as(conn, sql, []) do |row| Orm.decode_row(row, Tagged.codec) end
    case found
      error(message) -> return failed(state, message.message)
      ok(_) -> return recorded(state, Outcome.Done)
    end
  end
end

def name_of(row: Db.Row) -> Result[String]
  case row.get("name", Db.Value.Null)
    Db.Value.Text(name) -> ok(name)
    _ -> error("no name in the row")
  end
end

# The schemas: `people`, `ghost` (a column the table lacks), `keyless` (a primary key that is not a column),
# `injection` (a table name that is sql), `textkey` (a generated key that is not an Int), `nullkey` (a key that is not
# generated and can be none), `nested` (an `Optional[Optional[Int]]` field) and `list` (a field no column holds).
def orm_check(state: State, which: String) -> State
  with_conn(state) do |conn|
    case which
      "people" -> return checked(state, Orm.check(conn, people()))
      "ghost" -> return checked(state, Orm.check(conn, Orm.schema("people", Ghost.codec)))
      "keyless" -> return checked(state, Orm.check(conn, people().with(primary_key: "pk")))
      "injection" -> return checked(state, Orm.check(conn, injected()))
      "textkey" -> return checked(state, Orm.check(conn, Orm.schema("people", Named.codec)))
      "nullkey" -> return checked(state, Orm.check(conn, nullable_key()))
      "nested" -> return checked(state, Orm.check(conn, Orm.schema("people", Nested.codec)))
      _ -> return checked(state, Orm.check(conn, Orm.schema("people", Tagged.codec)))
    end
  end
end

def nullable_key() -> Orm.Schema[MaybeKeyed] = Orm.schema("people", MaybeKeyed.codec).with(generated: false)

def injected() -> Orm.Schema[Person] = people().with(table: "a; drop table x")

# The Partial of a table of one row: the header names the fields, each cell is a typed cell. The id is 0 unless
# given, and a cell `Absent` is a JSON.Field with no value.
def partial_of(table: List[List[String]]) -> Result[Partial]
  cells: Map[String, String] = {}
  for i in 0...table[0].size
    cells = cells.put(table[0][i], table[1][i])
  end

  id = try int_cell(cells.get("id", "Int 0"))
  name = try text_cell(cells["name"])
  age = try age_cell(cells["age"])
  admin = try bool_cell(cells["admin"])
  score = try float_cell(cells["score"])
  ok(Partial(id: id, name: name, age: age, admin: admin, score: score))
end

# The Person of a table of one row, as `partial_of` reads it; an age is an Int or Null.
def person_of(table: List[List[String]]) -> Result[Person]
  partial = try partial_of(table)
  person = Person(id: partial.id, name: partial.name, admin: partial.admin, score: partial.score)
  case partial.age
    JSON.Field.Value(years) -> ok(person.with(age: some(years)))
    JSON.Field.Null -> ok(person)
    JSON.Field.Absent -> error("an Absent age needs a partial person")
  end
end

def int_cell(cell: String) -> Result[Int]
  case try Cells.parse(cell)
    Db.Value.Int(n) -> ok(n)
    _ -> error("expected an Int cell, got #{cell}")
  end
end

def text_cell(cell: String) -> Result[String]
  case try Cells.parse(cell)
    Db.Value.Text(text) -> ok(text)
    _ -> error("expected a Text cell, got #{cell}")
  end
end

def bool_cell(cell: String) -> Result[Bool]
  case try Cells.parse(cell)
    Db.Value.Bool(flag) -> ok(flag)
    _ -> error("expected a Bool cell, got #{cell}")
  end
end

def float_cell(cell: String) -> Result[Float]
  case try Cells.parse(cell)
    Db.Value.Float(x) -> ok(x)
    _ -> error("expected a Float cell, got #{cell}")
  end
end

def age_cell(cell: String) -> Result[JSON.Field[Int]]
  return ok(JSON.Field.Absent) if cell == "Absent"

  case try Cells.parse(cell)
    Db.Value.Null -> ok(JSON.Field.Null)
    Db.Value.Int(n) -> ok(JSON.Field.Value(n))
    _ -> error("expected an Int, Null or Absent cell, got #{cell}")
  end
end

# The schema `manual` is `people` with a key the value gives.
def orm_insert(state: State, req: Protocol.OrmInsert) -> State
  inserted(state, people().with(generated: not req.manual), person_of(req.rows), &person_row)
end

def orm_insert_partial(state: State, req: Protocol.OrmInsertPartial) -> State
  inserted(state, partials().with(generated: true), partial_of(req.rows), &partial_row)
end

def inserted[T](state: State, schema: Orm.Schema[T], value: Result[T], row: Fn[T, Db.Row]) -> State
  with_conn(state) do |conn|
    case value
      error(message) -> return failed(state, message.message)
      ok(item) ->
        case Orm.insert(conn, schema, item)
          error(message) -> return failed(state, message.message)
          ok(stored) -> return recorded(state, Outcome.Rows([row.call(stored)]))
        end
    end
  end
end

def orm_update[T](state: State, schema: Orm.Schema[T], value: Result[T]) -> State
  with_conn(state) do |conn|
    case value
      error(message) -> return failed(state, message.message)
      ok(item) -> return counted(state, Orm.update(conn, schema, item))
    end
  end
end

def orm_patch(state: State, id: Int, changes: String) -> State
  with_conn(state) do |conn|
    case JSON.parse(Cells.expand(changes))
      error(message) -> return failed(state, message.message)
      ok(json) -> return counted(state, Orm.patch(conn, people(), Db.Value.Int(id), json))
    end
  end
end

def orm_delete(state: State, req: Protocol.OrmDelete) -> State
  with_conn(state) do |conn|
    id = Db.Value.Int(req.key)
    return counted(state, Orm.delete(conn, injected(), id)) if req.schema == "injection"

    return counted(state, Orm.delete(conn, people(), id))
  end
end

# The key is a typed cell.
def orm_delete_typed(state: State, key: String) -> State
  with_conn(state) do |conn|
    case Cells.parse(key)
      error(message) -> return failed(state, message.message)
      ok(id) -> return counted(state, Orm.delete(conn, people(), id))
    end
  end
end

# A marker has no field to write but its key, so an insert and an update have no column.
def orm_marker(state: State, which: String) -> State
  with_conn(state) do |conn|
    markers = Orm.schema("markers", Marker.codec)
    marker = Marker(note: JSON.Field.Absent)
    if which == "insert"
      case Orm.insert(conn, markers, marker)
        error(message) -> return failed(state, message.message)
        ok(_) -> return recorded(state, Outcome.Done)
      end
    end

    return counted(state, Orm.update(conn, markers, marker))
  end
end

def counted(state: State, done: Result[Int]) -> State
  case done
    error(message) -> failed(state, message.message)
    ok(count) -> recorded(state, Outcome.Counted(count))
  end
end

def checked(state: State, done: Result[Void]) -> State
  case done
    error(message) -> failed(state, message.message)
    ok(_) -> recorded(state, Outcome.Done)
  end
end

def close(state: State) -> State
  state.conns.each do |conn| Db.close(conn) end
  recorded(state, Outcome.Done)
end

# Each row of the table is a statement (the header row is skipped); a failed statement stops the body with its error
# unless its row says to carry on. Then, when asked, the body starts a transaction inside the transaction. The body
# ends with the failure message of the request, or gives the rows changed by its last statement: the transaction
# gives that count when the request asks for it (`gives`), else it is a Void transaction that records only that it
# worked.
def transaction(state: State, req: Protocol.Transaction) -> State
  rows = req.statements.drop(1)
  with_conn(state) do |conn|
    if req.gives
      counted = Db.transaction(conn) do |tx| run_body(tx, rows, req) end
      case counted
        error(e) -> return failed(state, described(e, req))
        ok(count) -> return recorded(state, Outcome.Counted(count))
      end
    end

    done = Db.transaction(conn) do |tx| run_void(tx, rows, req) end
    case done
      error(e) -> return failed(state, described(e, req))
      ok(_) -> return recorded(state, Outcome.Done)
    end
  end
end

# The text of a failed transaction: its message, or, for a block that fails with a kind and a code, `kind code:
# message`, so a scenario sees what the call gave back, not only the text.
def described(e: Error, req: Protocol.Transaction) -> String
  return e.message if req.kind.empty?

  "#{e.kind} #{e.code.unwrap_or(-1)}: #{e.message}"
end

# The same body for a transaction whose value is Void, so both forms of `Db.transaction` run in CI.
def run_void(tx: Db.Connection, rows: List[List[String]], req: Protocol.Transaction) -> Result[Void]
  try run_body(tx, rows, req)
  ok()
end

def run_body(tx: Db.Connection, rows: List[List[String]], req: Protocol.Transaction) -> Result[Int]
  last = 0
  for row in rows
    done = Db.execute(tx, Cells.expand(row[0]), [])
    case done
      ok(count) -> last = count
      error(message) -> return error(message) if not (row.size > 1 and row[1] == CARRY_ON)
    end
  end

  if req.nested
    try Db.transaction(tx) do |_inner| ok() end
  end

  return error(req.failure, kind: req.kind, code: req.code) if not req.failure.empty? and not req.kind.empty?

  return error(req.failure) if not req.failure.empty?

  ok(last)
end

def write_in_task(job: Writer) -> Result[Void]
  conn = try Db.open(job.url, drivers())
  done = Db.transaction(conn) do |tx| run_rows(tx, job.rows) end
  Db.close(conn)
  done
end

# `req.writers` writers come to the line of the pool one after another, ARRIVAL_MS apart; each writes its number into
# `notes` and holds its transaction TURN_HOLD_MS.
def pool_writers_in_turn(state: State, req: Protocol.PoolWritersInTurn) -> State
  with_pool(state) do |pool|
    tasks: List[Task[Result[Void]]] = []
    for writer in 1..req.writers
      tasks = tasks.push(Task.spawn(&write_in_turn, TurnWriter(pool: pool, writer: writer)))
      Task.sleep(ARRIVAL_MS)
    end

    for task in tasks
      done = Task.await(task)
      return failed(state, done.message) if not done.ok?
    end

    return recorded(state, Outcome.Done)
  end
end

def write_in_turn(job: TurnWriter) -> Result[Void]
  DbPool.with(job.pool) do |conn| Db.transaction(conn) do |tx| hold_turn(tx, job.writer) end end
end

def hold_turn(tx: Db.Connection, writer: Int) -> Result[Void]
  try Db.execute(tx, "insert into notes (writer) values (?)", [Db.Value.Int(writer)])
  Task.sleep(TURN_HOLD_MS)
  ok()
end

# A block of the pool that crashes (`req.mode` "crashes") or sleeps past its lease in its transaction, then a writer of
# the pool; it fails when the writer took `req.limit_ms` ms or more, the wait of a turn that was not given back.
def pool_turn_after(state: State, req: Protocol.PoolTurnAfter) -> State
  with_pool(state) do |pool|
    first = DbPool.with(pool) do |conn| Db.transaction(conn) do |_tx| stall(req.mode) end end
    return failed(state, "the first block succeeded") if first.ok?

    started = Time.monotonic_ms()
    second = DbPool.with(pool) do |conn| Db.transaction(conn) do |tx| write_note(tx) end end
    took = Time.monotonic_ms() - started
    return failed(state, "the next writer waited #{took} ms") if took >= req.limit_ms

    return counted(state, second)
  end
end

# A crash (`to_i!` of a text that is not a number halts the task), or a sleep that the lease ends.
def stall(kind: String) -> Result[Int]
  return ok("not a number".to_i!) if kind == "crashes"

  Task.sleep(STALL_MS)
  ok(0)
end

def write_note(tx: Db.Connection) -> Result[Int] = Db.execute(tx, "insert into notes (writer) values (1)", [])

# A block of the pool that checks out a second connection inside its transaction and starts a transaction there; it
# fails when that took `req.limit_ms` ms or more.
def pool_nested_transaction(state: State, req: Protocol.PoolNestedTransaction) -> State
  with_pool(state) do |pool|
    started = Time.monotonic_ms()
    done = DbPool.with(pool) do |conn| Db.transaction(conn) do |_tx| inner_write(pool) end end
    took = Time.monotonic_ms() - started
    return failed(state, "the nested transaction took #{took} ms") if took >= req.limit_ms

    return counted(state, done)
  end
end

def inner_write(pool: DbPool.Pool) -> Result[Int]
  DbPool.with(pool) do |conn| Db.transaction(conn) do |tx| write_note(tx) end end
end

def run_rows(tx: Db.Connection, rows: List[List[String]]) -> Result[Void]
  for row in rows
    try Db.execute(tx, Cells.expand(row[0]), [])
  end

  ok()
end

# Every task starts before the first is awaited, so they all want the write lock together. The outcome is the first
# failure, if any.
def write_together(state: State, req: Protocol.WriteTogether) -> State
  job = Writer(url: expand(state, req.url), rows: req.statements.drop(1))
  tasks: List[Task[Result[Void]]] = []
  for _ in 0...req.tasks
    tasks = tasks.push(Task.spawn(&write_in_task, job))
  end

  failures: List[String] = []
  for task in tasks
    done = Task.await(task)
    if not done.ok?
      failures = failures.push(done.message)
    end
  end

  return recorded(state, Outcome.Done) if failures.empty?

  failed(state, failures[0])
end

# The statement runs in a task on a connection of its own at the url, and its count is recorded.
def execute_fresh(state: State, req: Protocol.ExecuteFresh) -> State
  job = Fresh(url: expand(state, req.url), sql: Cells.expand(req.sql))
  counted(state, Task.await(Task.spawn(&fresh_execute, job)))
end

# The statement runs in a task on a connection of its own at the url, which fails: the failure is recorded for the next
# step, and the wait that came before it must last `req.least_ms` milliseconds at least.
def execute_waiting(state: State, req: Protocol.ExecuteWaiting) -> Handled
  started = Time.monotonic_ms()
  job = Fresh(url: expand(state, req.url), sql: Cells.expand(req.sql))
  case Task.await(Task.spawn(&fresh_execute, job))
    ok(_) -> Handled(state: state, reply: "the statement did not fail")
    error(message) ->
      waited = Time.monotonic_ms() - started
      if waited < req.least_ms
        return Handled(state: state, reply: "it failed after #{waited} ms, less than #{req.least_ms} ms: #{message}")
      end

      reply_ok(failed(state, message.message))
  end
end

# The next two steps start a task with a connection of its own, and act once the task holds a lock that does not go
# away (a COMMIT that waits stays open; a transaction holds its lock). The task is seen by a probe, a connection that
# never waits (busy_timeout=0): its read fails while another connection holds a lock that refuses new readers, which
# is a PENDING lock (a commit that waits for the readers) or an EXCLUSIVE one.
def probe_url(url: String) -> String = "#{url}&busy_timeout=0"

# True once the probe is refused; false when it is not within BLOCKED_WAIT_MS.
def blocked?(probe: Db.Connection) -> Bool
  deadline = Time.monotonic_ms() + BLOCKED_WAIT_MS
  while Time.monotonic_ms() < deadline
    return true if not Db.query(probe, PROBE_SQL, []).ok?

    Task.sleep(1)
  end

  false
end

def never_blocked() -> String = "the task never held a lock in #{BLOCKED_WAIT_MS} ms"

def timed_query(job: Fresh) -> Timed
  started = Time.monotonic_ms()
  found = fresh_query(job)
  Timed(started: started, ended: Time.monotonic_ms(), found: found)
end

# The query runs in a task on a connection of its own while this connection, which holds a read lock, commits after
# `req.commit_after_ms` milliseconds: the query waits for the lock, then its rows or its failure are the outcome.
# A statement that writes in autocommit mode is rolled back by SQLite while it waits, so no lock shows that the task
# waits; the
# times do: the task must have started before the commit (by a tenth of the delay, so a slow start does not fail the
# step) and have ended after it, and nothing but the lock of this connection keeps a statement that long.
def query_until_commit(state: State, req: Protocol.QueryUntilCommit) -> Handled
  return reply_ok(failed(state, NO_DATABASE)) if state.conns.empty?

  task = Task.spawn(&timed_query, Fresh(url: expand(state, req.url), sql: Cells.expand(req.sql)))
  Task.sleep(req.commit_after_ms)
  committed_at = Time.monotonic_ms()
  committed = Db.execute(state.conns[0], "COMMIT", [])
  timed = Task.await(task)
  return reply_ok(failed(state, committed.message)) if not committed.ok?

  if timed.started > committed_at - req.commit_after_ms / 10 or timed.ended < committed_at
    return Handled(state: state, reply: "the query did not wait for the commit: #{timed_range(timed, committed_at)}")
  end

  case timed.found
    error(message) -> reply_ok(failed(state, message.message))
    ok(rows) -> reply_ok(recorded(state, Outcome.Rows(rows)))
  end
end

def timed_range(timed: Timed, committed_at: Int) -> String
  "it ran from #{timed.started} to #{timed.ended} ms and the commit was at #{committed_at} ms"
end

# A task writes in a transaction and waits at its COMMIT for this connection, which holds a read lock. This connection
# then runs its own write, which cannot get the lock of the task, and must be refused at once. It rolls back to let the
# task commit. The outcome is the result of the write.
def write_while_blocked(state: State, req: Protocol.WriteWhileBlocked) -> Handled
  return reply_ok(failed(state, NO_DATABASE)) if state.conns.empty?

  url = expand(state, req.url)
  case Db.open(probe_url(url), drivers())
    error(message) -> Handled(state: state, reply: message.message)
    ok(probe) ->
      task = Task.spawn(&commit_write, Fresh(url: url, sql: Cells.expand(req.write)))
      seen = blocked?(probe)
      Db.close(probe)
      started = Time.monotonic_ms()
      tried = Db.execute(state.conns[0], Cells.expand(req.sql), [])
      waited = Time.monotonic_ms() - started
      _ = Db.execute(state.conns[0], "ROLLBACK", [])
      committed = Task.await(task)
      return Handled(state: state, reply: never_blocked()) if not seen

      return Handled(state: state, reply: "the task could not commit: #{committed.message}") if not committed.ok?

      if waited > REFUSED_WRITE_MS
        return Handled(state: state, reply: "the write waited #{waited} ms for a lock that could not come")
      end

      case tried
        error(message) -> reply_ok(failed(state, message.message))
        ok(count) -> reply_ok(recorded(state, Outcome.Counted(count)))
      end
  end
end

def commit_write(job: Fresh) -> Result[Int]
  conn = try Db.open(job.url, drivers())
  try Db.execute(conn, "BEGIN IMMEDIATE", [])
  try Db.execute(conn, job.sql, [])
  done = Db.execute(conn, "COMMIT", [])
  Db.close(conn)
  done
end

# A task holds the write lock (EXCLUSIVE, which refuses readers too) for `req.hold_ms` milliseconds while this
# connection queries: the query must wait for it, then give its rows.
def query_while_locked(state: State, req: Protocol.QueryWhileLocked) -> Handled
  return reply_ok(failed(state, NO_DATABASE)) if state.conns.empty?

  url = expand(state, req.url)
  case Db.open(probe_url(url), drivers())
    error(message) -> Handled(state: state, reply: message.message)
    ok(probe) ->
      task = Task.spawn(&hold_lock, Hold(url: url, ms: req.hold_ms))
      seen = blocked?(probe)
      Db.close(probe)
      started = Time.monotonic_ms()
      found = Db.query(state.conns[0], Cells.expand(req.sql), [])
      waited = Time.monotonic_ms() - started
      _ = Task.await(task)
      return Handled(state: state, reply: never_blocked()) if not seen

      if waited < req.hold_ms / 10
        return Handled(state: state, reply: "the query took #{waited} ms, it did not wait for the lock")
      end

      case found
        error(message) -> reply_ok(failed(state, message.message))
        ok(rows) -> reply_ok(recorded(state, Outcome.Rows(rows)))
      end
  end
end

# A task holds the write lock (EXCLUSIVE, which refuses readers too) for `req.hold_ms` milliseconds while this
# connection is opened again at the same url. A new connection has not read the schema, so the statements that `open`
# runs must wait at their prepare, not at a step; the open must give a connection that works.
def open_while_locked(state: State, req: Protocol.OpenWhileLocked) -> Handled
  url = expand(state, req.url)
  case Db.open(probe_url(url), drivers())
    error(message) -> Handled(state: state, reply: message.message)
    ok(probe) ->
      task = Task.spawn(&hold_lock, Hold(url: url, ms: req.hold_ms))
      seen = blocked?(probe)
      Db.close(probe)
      started = Time.monotonic_ms()
      reopened = open_at(state, state.adapter, url)
      waited = Time.monotonic_ms() - started
      _ = Task.await(task)
      return Handled(state: state, reply: never_blocked()) if not seen

      if waited < req.hold_ms / 10
        return Handled(state: reopened, reply: "the open took #{waited} ms, it did not wait for the lock")
      end

      reply_ok(reopened)
  end
end

def hold_lock(job: Hold) -> Result[Int]
  conn = try Db.open(job.url, drivers())
  try Db.execute(conn, "BEGIN EXCLUSIVE", [])
  Task.sleep(job.ms)
  done = Db.execute(conn, "COMMIT", [])
  Db.close(conn)
  done
end

def fresh_execute(job: Fresh) -> Result[Int]
  conn = try Db.open(job.url, drivers())
  done = Db.execute(conn, job.sql, [])
  Db.close(conn)
  done
end

# A runtime error in the task ends only the task, and its await gives it as an error.
def run_job(job: Job) -> Result[Int] = Db.execute(job.conn, job.sql, [])

def execute_in_task(state: State, sql: String) -> State
  with_conn(state) do |conn|
    case Task.await(Task.spawn(&run_job, Job(conn: conn, sql: Cells.expand(sql))))
      error(message) -> return failed(state, message.message)
      ok(count) -> return recorded(state, Outcome.Counted(count))
    end
  end
end

# `req.tasks` tasks each run the query QUERY_REPEATS times on the one connection, at once; the rows when every run
# gave the same.
def query_together(state: State, req: Protocol.QueryTogether) -> State
  with_conn(state) do |conn|
    job = Job(conn: conn, sql: Cells.expand(req.sql))
    tasks = (0...req.tasks).to_a.map do |_| Task.spawn(&query_repeated, job) end
    results = tasks.map do |task| Task.await(task) end
    return same_rows(state, results)
  end
end

# The rows of a query on the connection while another task runs a long statement there, unless the scheduler stopped
# meanwhile for `req.limit_ms` ms or more: a short call that waited for the other task's statement stops it.
def query_beside_long(state: State, req: Protocol.QueryBesideLong) -> State
  with_conn(state) do |conn|
    long = Task.spawn(&run_job, Job(conn: conn, sql: Cells.expand(req.long)))
    Task.sleep(LONG_START_MS)
    ticker = Task.spawn(&longest_pause, TICKER_MS)
    Task.sleep(TICKER_START_MS)
    rows = Db.query(conn, Cells.expand(req.sql), [])
    pause = Task.await(ticker)
    _ = Task.await(long)
    return beside_rows(state, rows, pause, req.limit_ms)
  end
end

# A write on the connection that waits for the lock of another connection (at `req.url`) is cancelled while another
# task runs a long statement there. It fails when the scheduler stopped for `req.limit_ms` ms or more: the cancel frees
# the write's cursor, which must not wait for the long statement.
def cancel_beside_long(state: State, req: Protocol.CancelBesideLong) -> State
  with_conn(state) do |conn|
    case Db.open(expand(state, req.url), drivers())
      error(message) -> return failed(state, message.message)
      ok(other) -> return cancel_with_lock(state, conn, other, req)
    end
  end
end

def cancel_with_lock(state: State, conn: Db.Connection, other: Db.Connection, req: Protocol.CancelBesideLong) -> State
  write = Cells.expand(req.write)
  _ = Db.execute(other, "begin immediate", [])
  writer = Task.spawn(&run_job, Job(conn: conn, sql: write))
  writer_down: Channel[TaskDown] = Channel.new(1)
  Task.monitor(writer, writer_down) do |down| down end
  Task.sleep(LONG_START_MS)
  ticker = Task.spawn(&longest_pause, TICKER_MS)
  Task.sleep(TICKER_START_MS)
  long = Task.spawn(&run_job, Job(conn: conn, sql: Cells.expand(req.long)))
  Task.sleep(CANCEL_AFTER_MS)
  Task.cancel(writer)
  pause = Task.await(ticker)
  _ = Task.await(long)
  # The writer ends at the cancel, but a try already on the compute pool runs on, and may write once the lock is
  # let go.
  ended = writer_down.recv(WRITER_END_MS)
  _ = Db.execute(other, "rollback", [])
  Db.close(other)
  return failed(state, "the cancelled write did not end") if not ended.ok?

  case pause
    error(message) -> failed(state, message.message)
    ok(ms) if ms >= req.limit_ms -> failed(state, "the scheduler stopped for #{ms} ms")
    ok(_) -> recorded(state, Outcome.Done)
  end
end

# A write on the connection (`req.write`) waits for the lock of another connection to `req.url`; once that lock
# goes, the statement `req.sql` runs on the connection between two tries of the write, and its count is recorded
# after the write has ended.
def execute_beside_waiting(state: State, req: Protocol.ExecuteBesideWaiting) -> State
  with_conn(state) do |conn|
    case Db.open(expand(state, req.url), drivers())
      error(message) -> return failed(state, message.message)
      ok(other) ->
        _ = Db.execute(other, "begin immediate", [])
        writer = Task.spawn(&run_job, Job(conn: conn, sql: Cells.expand(req.write)))
        Task.sleep(WRITER_WAITS_MS)
        _ = Db.execute(other, "rollback", [])
        Db.close(other)
        count = Db.execute(conn, Cells.expand(req.sql), [])
        _ = Task.await(writer)
        return counted(state, count)
    end
  end
end

# A statement on a connection of its own to `req.url`, closed after it: its rows, or its count for `execute`.
def on_other(state: State, req: Protocol.OnOther) -> State
  case Db.open(expand(state, req.url), drivers())
    error(message) -> failed(state, message.message)
    ok(other) ->
      sql = Cells.expand(req.sql)
      if req.query
        rows = Db.query(other, sql, [])
        Db.close(other)
        return recorded_rows(state, rows)
      end

      count = Db.execute(other, sql, [])
      Db.close(other)
      counted(state, count)
  end
end

# The rows of `req.sql` with one parameter, a JSON list of `req.items` ones, unless the scheduler stopped for
# `req.limit_ms` ms or more meanwhile: a short call must not take big bound data.
def query_big_json(state: State, req: Protocol.QueryBigJson) -> State
  with_conn(state) do |conn|
    list = "[#{"1," * (req.items - 1)}1]"
    ticker = Task.spawn(&longest_pause, TICKER_MS)
    Task.sleep(TICKER_START_MS)
    rows = Db.query(conn, Cells.expand(req.sql), [Db.Value.Text(list)])
    pause = Task.await(ticker)
    return beside_rows(state, rows, pause, req.limit_ms)
  end
end

def query_json_list(state: State, req: Protocol.QueryJsonList) -> State
  with_conn(state) do |conn|
    list = "[#{"1," * (req.items - 1)}1]"
    return recorded_rows(state, Db.query(conn, Cells.expand(req.sql), [Db.Value.Text(list)]))
  end
end

def beside_rows(state: State, rows: Result[List[Db.Row]], pause: Result[Int], limit: Int) -> State
  case pause
    error(message) -> failed(state, message.message)
    ok(ms) if ms >= limit -> failed(state, "the scheduler stopped for #{ms} ms")
    ok(_) -> recorded_rows(state, rows)
  end
end

def recorded_rows(state: State, rows: Result[List[Db.Row]]) -> State
  case rows
    error(message) -> failed(state, message.message)
    ok(found) -> recorded(state, Outcome.Rows(found))
  end
end

# The longest time between two ticks in `ms` milliseconds: about PAUSE_TICK_MS while the scheduler runs freely.
def longest_pause(ms: Int) -> Result[Int]
  started = Time.monotonic_ms()
  last = started
  longest = 0
  while last - started < ms
    Task.sleep(PAUSE_TICK_MS)
    now = Time.monotonic_ms()
    if now - last > longest
      longest = now - last
    end

    last = now
  end

  ok(longest)
end

def same_rows(state: State, results: List[Result[List[Db.Row]]]) -> State
  found: List[List[Db.Row]] = []
  for result in results
    case result
      error(message) -> return failed(state, message.message)
      ok(rows) -> found = found.push(rows)
    end
  end

  return failed(state, "the tasks got different rows: #{found}") if found.any? do |rows| rows != found[0] end

  recorded(state, Outcome.Rows(found[0]))
end

def query_repeated(job: Job) -> Result[List[Db.Row]]
  first = try Db.query(job.conn, job.sql, [])
  for _ in 1...QUERY_REPEATS
    again = try Db.query(job.conn, job.sql, [])
    return error("a run of the query gave other rows: #{again}") if again != first
  end

  ok(first)
end

# The counters of the statement cache of the connection, as one row.
def statement_cache(state: State) -> State
  with_conn(state) do |conn|
    found = Db.statement_cache(conn).map do |c| [c.size, c.capacity, c.hits, c.misses, c.evictions] end
    cache_row(state, found)
  end
end

# Fails unless the connection runs the driver that the variable `name` asks for (`native` or `ffi`). Only the native
# driver has a statement cache, which tells them apart. A variable that is not set asks for none: the adapter takes the
# native driver when it loads, and any run passes.
def driver_named(state: State, name: String) -> State
  wanted = System.env(name).unwrap_or("")
  with_conn(state) do |conn|
    case Db.statement_cache(conn)
      some(_) -> driver_ran(state, name, wanted, "native")
      none -> driver_ran(state, name, wanted, "ffi")
    end
  end
end

# The server of the first connection, `mariadb` or `mysql`, for the steps of what one of them alone has.
def mysql_flavor(state: State) -> String
  return NO_DATABASE if state.conns.empty?

  conn = state.conns[0]
  return "not a mysql connection" if conn.adapter != Db.Adapter.Mysql

  # A SHOW, which the statement cache of the native driver never keeps or counts.
  case Db.query(conn, "show variables like 'version'", [])
    error(message) -> message.message
    ok(rows) ->
      case rows[0]["Value"]
        Db.Value.Text(version) if version.include?("MariaDB") -> "mariadb"
        _ -> "mysql"
      end
  end
end

def driver_ran(state: State, name: String, wanted: String, ran: String) -> State
  if wanted != "" and wanted != ran
    return failed(state, "#{name} is #{wanted}, but the connection runs the #{ran} driver")
  end

  recorded(state, Outcome.Done)
end

def cache_row(state: State, found: Optional[List[Int]]) -> State
  case found
    none -> failed(state, "the FFI driver has no statement cache")
    some(counts) ->
      names = ["size", "capacity", "hits", "misses", "evictions"]
      row: Db.Row = {}
      for i in 0...names.size
        row = row.put(names[i], Db.Value.Int(counts[i]))
      end

      recorded(state, Outcome.Rows([row]))
  end
end

# A task runs `req.sql` on the connection and is cancelled after `req.cancel_after_ms` ms. With a `req.query`, then
# its rows, unless it took `req.limit_ms` ms or more: the cancelled statement must not hold it up.
def cancel_task(state: State, req: Protocol.CancelTask) -> State
  with_conn(state) do |conn|
    task = Task.spawn(&run_job, Job(conn: conn, sql: Cells.expand(req.sql)))
    Task.sleep(req.cancel_after_ms)
    Task.cancel(task)
    return recorded(state, Outcome.Done) if req.query.empty?

    started = Time.monotonic_ms()
    rows = Db.query(conn, Cells.expand(req.query), [])
    took = Time.monotonic_ms() - started
    return failed(state, "the query took #{took} ms after the cancel") if took >= req.limit_ms

    return recorded_rows(state, rows)
  end
end

# Queries `req.sql` with `[N]` replaced by each number from `req.from` to `req.to`; the rows of the last.
def query_each(state: State, req: Protocol.QueryEach) -> State
  with_conn(state) do |conn|
    rows: Result[List[Db.Row]] = ok([])
    for n in req.from..req.to
      rows = Db.query(conn, Cells.expand(req.sql.replace("[N]", n.to_s)), [])
      return recorded_rows(state, rows) if not rows.ok?
    end

    return recorded_rows(state, rows)
  end
end

# Queries `req.sql` with a text of `req.size` characters while another task reads the statement cache of the
# connection: the reads wait for the query instead of failing its calls.
def cache_beside_big(state: State, req: Protocol.CacheBesideBig) -> State
  with_conn(state) do |conn|
    reader = Task.spawn(&read_cache, conn)
    rows = Db.query(conn, Cells.expand(req.sql), [Db.Value.Text("x" * req.size)])
    case Task.await(reader)
      error(message) -> return failed(state, message.message)
      ok(_) -> return recorded_rows(state, rows)
    end
  end
end

def read_cache(conn: Db.Connection) -> Result[Int]
  if conn.adapter != Db.Adapter.Postgres and conn.adapter != Db.Adapter.Mysql
    return error("only a PostgreSQL or MySQL connection is read here")
  end

  for _ in 0...CACHE_READS
    _ = Db.statement_cache(conn)
    Task.sleep(1)
  end

  ok(CACHE_READS)
end

# A task executes `req.first` on the connection, a second one executes `req.second` there, which waits for the first,
# and this task closes the connection after `req.close_after_ms` ms: the outcome of the second.
def close_beside_queries(state: State, req: Protocol.CloseBesideQueries) -> State
  with_conn(state) do |conn|
    first = Task.spawn(&run_job, Job(conn: conn, sql: Cells.expand(req.first)))
    Task.sleep(QUEUE_START_MS)
    second = Task.spawn(&run_job, Job(conn: conn, sql: Cells.expand(req.second)))
    Task.sleep(req.close_after_ms)
    Db.close(conn)
    _ = Task.await(first)
    case Task.await(second)
      error(message) -> return failed(state, message.message)
      ok(count) -> return recorded(state, Outcome.Counted(count))
    end
  end
end

def fresh_query(job: Fresh) -> Result[List[Db.Row]]
  conn = try Db.open(job.url, drivers())
  found = Db.query(conn, job.sql, [])
  Db.close(conn)
  found
end

def query_in_new_task(state: State, sql: String) -> State
  job = Fresh(url: server_url(state.adapter), sql: Cells.expand(sql))
  case Task.await(Task.spawn(&fresh_query, job))
    error(message) -> failed(state, message.message)
    ok(rows) -> recorded(state, Outcome.Rows(rows))
  end
end

# The task opens a connection and ends without closing it. It gives the id of the session while the connection is
# open, since a session that never showed would pass the check of its end.
def open_and_leave(job: Leave) -> Result[Int]
  conn = try Db.open(job.url, drivers())
  rows = try Db.query(conn, SESSION_ID_SQL[job.adapter], [])
  int_of(rows)
end

def int_of(rows: List[Db.Row]) -> Result[Int]
  case rows[0]["n"]
    Db.Value.Int(n) -> ok(n)
    _ -> error("the count is not an Int")
  end
end

def sessions(conn: Db.Connection, adapter: String, id: Int) -> Result[Int]
  rows = try Db.query(conn, SESSIONS_SQL[adapter], [Db.Value.Int(id)])
  int_of(rows)
end

# The end of the task that opened a connection closes it: the server drops the session within `limit_ms`.
def leave_open(state: State, limit_ms: Int) -> Handled
  return Handled(state: state, reply: NO_DATABASE) if state.conns.empty?

  job = Leave(url: expand(state, "[URL]"), adapter: state.adapter)
  seen = Task.await(Task.spawn(&open_and_leave, job))
  case seen
    error(message) -> Handled(state: state, reply: "the task failed: #{message}")
    ok(id) -> reply_ok_when_gone(state, id, limit_ms)
  end
end

def reply_ok_when_gone(state: State, id: Int, limit_ms: Int) -> Handled
  started = Time.monotonic_ms()
  left = sessions(state.conns[0], state.adapter, id)
  while left.ok? and left.unwrap_or(0) > 0 and Time.monotonic_ms() - started < limit_ms
    Task.sleep(SESSION_POLL_MS)
    left = sessions(state.conns[0], state.adapter, id)
  end

  case left
    error(message) -> Handled(state: state, reply: "counting the sessions failed: #{message}")
    ok(0) -> reply_ok(state)
    ok(_) -> Handled(state: state, reply: "the session #{id} stayed open after #{limit_ms} ms")
  end
end

# No other session runs a statement whose text has `marker` within `limit_ms`.
def none_running(state: State, marker: String, limit_ms: Int) -> Handled
  return Handled(state: state, reply: NO_DATABASE) if state.conns.empty?

  started = Time.monotonic_ms()
  left = running(state.conns[0], state.adapter, marker)
  while left.ok? and left.unwrap_or(0) > 0 and Time.monotonic_ms() - started < limit_ms
    Task.sleep(SESSION_POLL_MS)
    left = running(state.conns[0], state.adapter, marker)
  end

  case left
    error(message) -> Handled(state: state, reply: "counting the statements failed: #{message}")
    ok(0) -> reply_ok(state)
    ok(n) -> Handled(state: state, reply: "#{n} statements with #{marker} still ran after #{limit_ms} ms")
  end
end

def running(conn: Db.Connection, adapter: String, marker: String) -> Result[Int]
  rows = try Db.query(conn, RUNNING_SQL[adapter], [Db.Value.Text("%#{marker}%")])
  int_of(rows)
end

# The longest time between two wake-ups of a task that sleeps a few milliseconds at a time.
def longest_gap(ticks: Int) -> Int
  longest = 0
  last = Time.monotonic_ms()
  for _ in 0...ticks
    Task.sleep(TICK_MS)
    now = Time.monotonic_ms()
    if now - last > longest
      longest = now - last
    end

    last = now
  end

  longest
end

# The time the other task waited is measured while a query of a connection of its own waits for the server.
def keep_running(state: State, sql: String, limit: Int) -> Handled
  slow = Task.spawn(&fresh_query, Fresh(url: server_url(state.adapter), sql: Cells.expand(sql)))
  ticks = Task.spawn(&longest_gap, TICKS)
  found = Task.await(slow)
  gap = Task.await(ticks)
  return Handled(state: state, reply: "the query failed: #{found.message}") if not found.ok?

  if gap >= limit
    return Handled(state: state, reply: "the other task was stopped for #{gap} ms during the query, limit #{limit} ms")
  end

  reply_ok(state)
end

# Each table row is a column type and a cell: a table with a column of that type is written with the cell as a
# parameter and read back, and the value must come back the same.
def round_trips(state: State, table: List[List[String]]) -> Handled
  return Handled(state: state, reply: NO_DATABASE) if state.conns.empty?

  for row in table.drop(1)
    case Cells.parse(row[1])
      error(message) -> return Handled(state: state, reply: message.message)
      ok(value) ->
        verdict = round_trip(state.conns[0], row[0], value)
        return Handled(state: state, reply: "a #{row[0]} column: #{verdict}") if not verdict.empty?
    end
  end

  reply_ok(state)
end

# The empty string when the value came back the same.
def round_trip(conn: Db.Connection, kind: String, value: Db.Value) -> String
  created = Db.execute(conn, "create temporary table rt (v #{kind})", [])
  return created.message if not created.ok?

  inserted = Db.execute(conn, "insert into rt (v) values (?)", [value])
  found = Db.query(conn, "select v from rt", [])
  _ = Db.execute(conn, "drop table rt", [])
  return "the insert failed: #{inserted.message}" if not inserted.ok?

  case found
    error(message) -> "the select failed: #{message}"
    ok(rows) if rows.size == 1 and Cells.same?(rows[0]["v"], value) -> ""
    ok(rows) -> "wrote #{Cells.show(value)}, read back #{shown(rows)}"
  end
end

# The server is the judge of a float: the driver reads the literal, sends the float back as a parameter, and the
# server says whether it is the literal. It compares the text forms, since `-0 = 0` is true for float8.
def float_oracle(state: State, literal: String) -> Handled
  return Handled(state: state, reply: NO_DATABASE) if state.conns.empty?

  conn = state.conns[0]
  case Db.query(conn, "select '#{literal}'::float8 as v", [])
    error(message) -> Handled(state: state, reply: "reading #{literal} failed: #{message}")
    ok(rows) ->
      sql = "select (?::float8)::text = ('#{literal}'::float8)::text as v"
      case Db.query(conn, sql, [rows[0]["v"]])
        error(message) -> Handled(state: state, reply: "sending #{literal} back failed: #{message}")
        ok(same) if Cells.same?(same[0]["v"], Db.Value.Bool(true)) -> reply_ok(state)
        ok(_) ->
          read = Cells.show(rows[0]["v"])
          Handled(state: state, reply: "#{literal} was read as #{read}, which the server does not take for it")
      end
  end
end

# Marks the last outcome as checked, and replies with the verdict: the empty string when it is what the request
# expects, else what went wrong.
def expect(state: State, verdict: String) -> Handled
  checked = State(conns: state.conns, pools: state.pools, adapter: state.adapter, last: state.last, checked: true)
  return reply_ok(checked) if verdict.empty?

  Handled(state: checked, reply: verdict)
end

# The failure must be of the kind that `Orm.classify` gives its message.
def judge_kind(last: Outcome, wanted: String) -> String
  case last
    Outcome.Failed(message) if Orm.kind(Orm.classify(message)) == wanted -> ""
    Outcome.Failed(message) -> "expected a #{wanted} error, got #{Orm.kind(Orm.classify(message))}: #{message}"
    _ -> "expected a #{wanted} error, but it succeeded"
  end
end

def judge_ok(last: Outcome) -> String
  case last
    Outcome.Failed(message) -> "expected it to succeed, but it failed with #{message.inspect}"
    Outcome.Nothing -> "nothing ran before"
    Outcome.Counted(_) -> ""
    Outcome.Rows(_) -> ""
    Outcome.Done -> ""
  end
end

def judge_count(last: Outcome, wanted: Int) -> String
  case last
    Outcome.Counted(count) if count == wanted -> ""
    Outcome.Counted(count) -> "expected #{wanted} rows changed, got #{count}"
    Outcome.Failed(message) -> "expected a count, but it failed with #{message.inspect}"
    _ -> "expected a count, got no count"
  end
end

# The failure message must pass `accepted`; a success never does.
def judge_failure(last: Outcome, how: String, wanted: String, accepted: Fn[String, Bool]) -> String
  case last
    Outcome.Failed(message) if accepted.call(message) -> ""
    Outcome.Failed(message) -> "expected a failure #{how} #{wanted.inspect}, got #{message.inspect}"
    _ -> "expected a failure #{how} #{wanted.inspect}, but it succeeded"
  end
end

def judge_rows(last: Outcome, table: List[List[String]]) -> String
  case last
    Outcome.Rows(rows) -> compare_rows(rows, table)
    Outcome.Failed(message) -> "expected rows, but it failed with #{message.inspect}"
    _ -> "expected rows, got none"
  end
end

# The result has `size` rows and the last one is the one row of the table.
def judge_last(last: Outcome, size: Int, table: List[List[String]]) -> String
  case last
    Outcome.Rows(rows) if rows.size == size -> compare_rows(rows.drop(size - 1), table)
    Outcome.Rows(rows) -> "expected #{size} rows, got #{rows.size}"
    Outcome.Failed(message) -> "expected rows, but it failed with #{message.inspect}"
    _ -> "expected rows, got none"
  end
end

# The first table row names the columns, in order; the others are the rows, in order.
def compare_rows(rows: List[Db.Row], table: List[List[String]]) -> String
  header = table[0]
  wanted = table.drop(1)
  return "expected #{wanted.size} rows, got #{rows.size}: #{shown(rows)}" if rows.size != wanted.size

  for i in 0...rows.size
    if not Test.eq(rows[i].keys, header).ok?
      return "row #{i + 1} has the columns #{rows[i].keys.inspect}, expected #{header.inspect}"
    end

    for c in 0...header.size
      case Cells.parse(wanted[i][c])
        error(message) -> return message.message
        ok(expected) ->
          actual = rows[i][header[c]]
          if not Cells.same?(actual, expected)
            return "row #{i + 1}, column #{header[c]}: expected #{wanted[i][c]}, got #{Cells.show(actual)}"
          end
      end
    end
  end

  ""
end

def shown(rows: List[Db.Row]) -> String
  texts = rows.map do |row| "{#{Cells.show_row(row)}}" end
  texts.join(", ")
end
