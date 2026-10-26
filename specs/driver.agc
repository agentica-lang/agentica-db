## The program under test of the features: it holds one database connection and runs the requests that
## `steps.agc` sends (`protocol.agc`), one JSON line in and one reply line out. It keeps the outcome of the last
## request, which the expectations check. A failed statement must be checked by an expectation before the next
## request: a setup step that fails cannot pass silently.

import Cells from "cells"
import Db from "../db"
import Protocol from "protocol"
import {Request} from "protocol"

SESSIONS_SQL = "select count(*) as n from pg_stat_activity where application_name = ?"
SESSION_POLL_MS = 50
URL_VARIABLES = {"postgres": "AGENTICA_DB_POSTGRES_URL", "mysql": "AGENTICA_DB_MYSQL_URL"}
SQLITE_MEMORY = "sqlite::memory:"
SCRATCH_ROOT = "../tmp"
CARRY_ON = "carry on"
TICKS = 40
TICK_MS = 20
IO_TIMEOUT_MS = 5_000
NO_DATABASE = "no database is open"

# What the last request gave.
enum Outcome
  Nothing
  Failed(String)
  Counted(Int)
  Rows(List[Db.Row])
  Done
end

# `conns` holds the one connection, or none: a connection has no empty value. `checked` is true once an expectation
# has read `last`.
struct State
  conns: List[Db.Connection]
  adapter: String
  last: Outcome
  checked: Bool
end

struct Handled
  state: State
  reply: String
end

# A statement run in a task on the connection of the driver.
struct Job
  conn: Db.Connection
  sql: String
end

# A connection that a task opens and leaves open, named so that the server shows its session.
struct Leave
  url: String
  name: String
end

# A statement run in a task on a connection of its own.
struct Fresh
  url: String
  sql: String
end

def main() -> Void
  # The runner never closes the input of the driver, so the folder of a scenario that ended stays until the next
  # scenario starts: scenarios run one at a time, and each starts from nothing.
  Path.remove(scratch_dir(), IO_TIMEOUT_MS)
  state = State(conns: [], adapter: "", last: Outcome.Nothing, checked: true)
  line = IO.gets
  while line.ok?
    handled = handle(state, line.unwrap_or(""))
    state = handled.state
    puts(handled.reply.replace("\n", "\\n"))
    IO.flush()
    line = IO.gets
  end

  Path.remove(scratch_dir(), IO_TIMEOUT_MS)
end

def handle(state: State, line: String) -> Handled
  case JSON.decode(line, Request)
    error(message) -> return Handled(state: state, reply: "bad request: #{message}")
    ok(req) -> return dispatch(state, req)
  end
end

def dispatch(state: State, req: Request) -> Handled
  if req.op.start_with?("expect_")
    return expect(state, req)
  end

  case state.last
    Outcome.Failed(message) if not state.checked ->
      reply = "the previous statement failed with #{message.inspect}, and no step checked it"
      return Handled(state: state, reply: reply)
    _ -> return act(state, req)
  end
end

def act(state: State, req: Request) -> Handled
  case req.op
    "open" -> return opened(state, req.text)
    "open_url" -> return reply_ok(open_at(state, state.adapter, expand(state, req.text)))
    "execute" -> return reply_ok(with_params(state, req, &execute))
    "query" -> return reply_ok(with_params(state, req, &query))
    "transaction" -> return reply_ok(transaction(state, req))
    "close" -> return reply_ok(close(state))
    "execute_in_task" -> return reply_ok(execute_in_task(state, req.text))
    "query_in_new_task" -> return reply_ok(query_in_new_task(state, req.text))
    "round_trips" -> return round_trips(state, req.table)
    "float_oracle" -> return float_oracle(state, req.text)
    "keep_running" -> return keep_running(state, req.text, req.number)
    "leave_open" -> return leave_open(state, req.text, req.number)
    _ -> return Handled(state: state, reply: "unknown op #{req.op.inspect}")
  end
end

def reply_ok(state: State) -> Handled
  return Handled(state: state, reply: Protocol.OK)
end

def recorded(state: State, outcome: Outcome) -> State
  return State(conns: state.conns, adapter: state.adapter, last: outcome, checked: false)
end

def failed(state: State, message: String) -> State
  return recorded(state, Outcome.Failed(message))
end

# The server url is the variable of the adapter; the step reports a missing variable.
def server_url(adapter: String) -> String
  if URL_VARIABLES.key?(adapter)
    return System.env(URL_VARIABLES[adapter]).unwrap_or("")
  end

  return SQLITE_MEMORY
end

# The `open` request of the first step: the adapter by name. A database that does not open ends the scenario.
def opened(state: State, adapter: String) -> Handled
  if adapter != "sqlite" and not URL_VARIABLES.key?(adapter)
    return Handled(state: state, reply: "unknown adapter #{adapter.inspect}")
  end

  opened = open_at(state, adapter, server_url(adapter))
  case opened.last
    Outcome.Failed(message) -> return Handled(state: opened, reply: "the #{adapter} database did not open: #{message}")
    _ -> return reply_ok(opened)
  end
end

# The one way to open: the old connection is closed first. A failure leaves no connection.
def open_at(state: State, adapter: String, url: String) -> State
  state.conns.each do |conn| Db.close(conn) end
  if url.include?(scratch_dir())
    Dir.mkdir(scratch_dir(), IO_TIMEOUT_MS)
  end

  case Db.open(url)
    error(message) -> return State(conns: [], adapter: adapter, last: Outcome.Failed(message), checked: false)
    ok(conn) -> return State(conns: [conn], adapter: adapter, last: Outcome.Done, checked: false)
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
  return expanded.replace("[SCRATCH]", scratch_dir())
end

# The host and port of a url without its scheme: after the last `@`, up to the first `/` or `?`.
def address(without_scheme: String) -> String
  host = without_scheme.split("@").last
  return host.split("/")[0].split("?")[0]
end

def scratch_dir() -> String
  return "#{SCRATCH_ROOT}/scratch"
end

# Runs `run` with the connection, or records the failure of having none.
def with_conn(state: State, run: Fn[Db.Connection, State]) -> State
  if state.conns.empty?
    return failed(state, NO_DATABASE)
  end

  return run.call(state.conns[0])
end

def with_params(state: State, req: Request, run: Fn[State, String, List[Db.Value], State]) -> State
  case Cells.parse_all(req.cells)
    error(message) -> return failed(state, message)
    ok(params) -> return run.call(state, Cells.expand(req.text), params)
  end
end

def execute(state: State, sql: String, params: List[Db.Value]) -> State
  return with_conn(state) do |conn|
    case Db.execute(conn, sql, params)
      error(message) -> return failed(state, message)
      ok(count) -> return recorded(state, Outcome.Counted(count))
    end
  end
end

def query(state: State, sql: String, params: List[Db.Value]) -> State
  return with_conn(state) do |conn|
    case Db.query(conn, sql, params)
      error(message) -> return failed(state, message)
      ok(rows) -> return recorded(state, Outcome.Rows(rows))
    end
  end
end

def close(state: State) -> State
  state.conns.each do |conn| Db.close(conn) end
  return recorded(state, Outcome.Done)
end

# Each row of the table is a statement (the header row is skipped); a failed statement stops the body with its error
# unless its row says to carry on. Then, when asked, the body starts a transaction inside the transaction. The body
# ends with the failure message of the request, or with ok.
def transaction(state: State, req: Request) -> State
  rows = req.table.drop(1)
  return with_conn(state) do |conn|
    done = Db.transaction(conn) do |tx| run_body(tx, rows, req) end
    case done
      error(message) -> return failed(state, message)
      ok(_) -> return recorded(state, Outcome.Done)
    end
  end
end

def run_body(tx: Db.Connection, rows: List[List[String]], req: Request) -> Result[Void]
  for row in rows
    done = Db.execute(tx, Cells.expand(row[0]), [])
    if not done.ok? and not (row.size > 1 and row[1] == CARRY_ON)
      return error(done.message)
    end
  end

  if req.nested
    try Db.transaction(tx) do |inner| ok() end
  end

  if not req.text.empty?
    return error(req.text)
  end

  return ok()
end

# A runtime error in the task ends only the task, and its await gives it as an error.
def run_job(job: Job) -> Result[Int]
  return Db.execute(job.conn, job.sql, [])
end

def execute_in_task(state: State, sql: String) -> State
  return with_conn(state) do |conn|
    case Task.await(Task.spawn(&run_job, Job(conn: conn, sql: Cells.expand(sql))))
      error(message) -> return failed(state, message)
      ok(count) -> return recorded(state, Outcome.Counted(count))
    end
  end
end

def fresh_query(job: Fresh) -> Result[List[Db.Row]]
  conn = try Db.open(job.url)
  found = Db.query(conn, job.sql, [])
  Db.close(conn)
  return found
end

def query_in_new_task(state: State, sql: String) -> State
  job = Fresh(url: server_url(state.adapter), sql: Cells.expand(sql))
  case Task.await(Task.spawn(&fresh_query, job))
    error(message) -> return failed(state, message)
    ok(rows) -> return recorded(state, Outcome.Rows(rows))
  end
end

# The task opens a connection and ends without closing it. It gives the sessions that the server shows under the name
# while the connection is open, since a session that never showed would pass the check of its end.
def open_and_leave(job: Leave) -> Result[Int]
  conn = try Db.open(job.url)
  return sessions(conn, job.name)
end

def sessions(conn: Db.Connection, name: String) -> Result[Int]
  rows = try Db.query(conn, SESSIONS_SQL, [Db.Value.Text(name)])
  case rows[0]["n"]
    Db.Value.Int(count) -> return ok(count)
    _ -> return error("the session count is not an Int")
  end
end

# The end of the task that opened a connection closes it: the server drops the session within `limit_ms`.
def leave_open(state: State, name: String, limit_ms: Int) -> Handled
  if state.conns.empty?
    return Handled(state: state, reply: NO_DATABASE)
  end

  url = expand(state, "[URL]&application_name=#{name}")
  seen = Task.await(Task.spawn(&open_and_leave, Leave(url: url, name: name)))
  case seen
    error(message) -> return Handled(state: state, reply: "the task failed: #{message}")
    ok(count) if count != 1 ->
      return Handled(state: state, reply: "the task saw #{count} sessions named #{name}, not 1")
    ok(_) -> return reply_ok_when_gone(state, name, limit_ms)
  end
end

def reply_ok_when_gone(state: State, name: String, limit_ms: Int) -> Handled
  started = Time.monotonic_ms()
  left = sessions(state.conns[0], name)
  while left.ok? and left.unwrap_or(0) > 0 and Time.monotonic_ms() - started < limit_ms
    Task.sleep(SESSION_POLL_MS)
    left = sessions(state.conns[0], name)
  end

  case left
    error(message) -> return Handled(state: state, reply: "counting the sessions failed: #{message}")
    ok(0) -> return reply_ok(state)
    ok(count) ->
      return Handled(state: state, reply: "#{count} sessions named #{name} stayed open after #{limit_ms} ms")
  end
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

  return longest
end

# The time the other task waited is measured while a query of a connection of its own waits for the server.
def keep_running(state: State, sql: String, limit: Int) -> Handled
  slow = Task.spawn(&fresh_query, Fresh(url: server_url(state.adapter), sql: Cells.expand(sql)))
  ticks = Task.spawn(&longest_gap, TICKS)
  found = Task.await(slow)
  gap = Task.await(ticks)
  if not found.ok?
    return Handled(state: state, reply: "the query failed: #{found.message}")
  end

  if gap >= limit
    return Handled(state: state, reply: "the other task was stopped for #{gap} ms during the query, limit #{limit} ms")
  end

  return reply_ok(state)
end

# Each table row is a column type and a cell: a table with a column of that type is written with the cell as a
# parameter and read back, and the value must come back the same.
def round_trips(state: State, table: List[List[String]]) -> Handled
  if state.conns.empty?
    return Handled(state: state, reply: NO_DATABASE)
  end

  for row in table.drop(1)
    case Cells.parse(row[1])
      error(message) -> return Handled(state: state, reply: message)
      ok(value) ->
        verdict = round_trip(state.conns[0], row[0], value)
        if not verdict.empty?
          return Handled(state: state, reply: "a #{row[0]} column: #{verdict}")
        end
    end
  end

  return reply_ok(state)
end

# The empty string when the value came back the same.
def round_trip(conn: Db.Connection, kind: String, value: Db.Value) -> String
  created = Db.execute(conn, "create temporary table rt (v #{kind})", [])
  if not created.ok?
    return created.message
  end

  inserted = Db.execute(conn, "insert into rt (v) values (?)", [value])
  found = Db.query(conn, "select v from rt", [])
  Db.execute(conn, "drop table rt", [])
  if not inserted.ok?
    return "the insert failed: #{inserted.message}"
  end

  case found
    error(message) -> return "the select failed: #{message}"
    ok(rows) if rows.size == 1 and Cells.same?(rows[0]["v"], value) -> return ""
    ok(rows) -> return "wrote #{Cells.show(value)}, read back #{shown(rows)}"
  end
end

# The server is the judge of a float: the driver reads the literal, sends the float back as a parameter, and the
# server says whether it is the literal. It compares the text forms, since `-0 = 0` is true for float8.
def float_oracle(state: State, literal: String) -> Handled
  if state.conns.empty?
    return Handled(state: state, reply: NO_DATABASE)
  end

  conn = state.conns[0]
  case Db.query(conn, "select '#{literal}'::float8 as v", [])
    error(message) -> return Handled(state: state, reply: "reading #{literal} failed: #{message}")
    ok(rows) ->
      sql = "select (?::float8)::text = ('#{literal}'::float8)::text as v"
      case Db.query(conn, sql, [rows[0]["v"]])
        error(message) -> return Handled(state: state, reply: "sending #{literal} back failed: #{message}")
        ok(same) if Cells.same?(same[0]["v"], Db.Value.Bool(true)) -> return reply_ok(state)
        ok(_) ->
          read = Cells.show(rows[0]["v"])
          return Handled(state: state, reply: "#{literal} was read as #{read}, which the server does not take for it")
      end
  end
end

def expect(state: State, req: Request) -> Handled
  checked = State(conns: state.conns, adapter: state.adapter, last: state.last, checked: true)
  verdict = judge(state.last, req)
  if verdict.empty?
    return reply_ok(checked)
  end

  return Handled(state: checked, reply: verdict)
end

# The empty string when the last outcome is what the request expects, else what went wrong.
def judge(last: Outcome, req: Request) -> String
  wanted = Cells.expand(req.text)
  case req.op
    "expect_ok" -> return judge_ok(last)
    "expect_count" -> return judge_count(last, req.number)
    "expect_rows" -> return judge_rows(last, req.table)
    "expect_last" -> return judge_last(last, req.number, req.table)
    "expect_prefix" -> return judge_failure(last, "starting with", wanted) do |message| message.start_with?(wanted) end
    "expect_exact" -> return judge_failure(last, "exactly", wanted) do |message| message == wanted end
    "expect_mentions" -> return judge_failure(last, "mentioning", wanted) do |message| message.include?(wanted) end
    "expect_hides" -> return judge_failure(last, "never showing", wanted) do |message| not message.include?(wanted) end
    _ -> return "unknown op #{req.op.inspect}"
  end
end

def judge_ok(last: Outcome) -> String
  case last
    Outcome.Failed(message) -> return "expected it to succeed, but it failed with #{message.inspect}"
    Outcome.Nothing -> return "nothing ran before"
    Outcome.Counted(_) -> return ""
    Outcome.Rows(_) -> return ""
    Outcome.Done -> return ""
  end
end

def judge_count(last: Outcome, wanted: Int) -> String
  case last
    Outcome.Counted(count) if count == wanted -> return ""
    Outcome.Counted(count) -> return "expected #{wanted} rows changed, got #{count}"
    Outcome.Failed(message) -> return "expected a count, but it failed with #{message.inspect}"
    _ -> return "expected a count, got no count"
  end
end

# The failure message must pass `accepted`; a success never does.
def judge_failure(last: Outcome, how: String, wanted: String, accepted: Fn[String, Bool]) -> String
  case last
    Outcome.Failed(message) if accepted.call(message) -> return ""
    Outcome.Failed(message) -> return "expected a failure #{how} #{wanted.inspect}, got #{message.inspect}"
    _ -> return "expected a failure #{how} #{wanted.inspect}, but it succeeded"
  end
end

def judge_rows(last: Outcome, table: List[List[String]]) -> String
  case last
    Outcome.Rows(rows) -> return compare_rows(rows, table)
    Outcome.Failed(message) -> return "expected rows, but it failed with #{message.inspect}"
    _ -> return "expected rows, got none"
  end
end

# The result has `size` rows and the last one is the one row of the table.
def judge_last(last: Outcome, size: Int, table: List[List[String]]) -> String
  case last
    Outcome.Rows(rows) if rows.size == size -> return compare_rows(rows.drop(size - 1), table)
    Outcome.Rows(rows) -> return "expected #{size} rows, got #{rows.size}"
    Outcome.Failed(message) -> return "expected rows, but it failed with #{message.inspect}"
    _ -> return "expected rows, got none"
  end
end

# The first table row names the columns, in order; the others are the rows, in order.
def compare_rows(rows: List[Db.Row], table: List[List[String]]) -> String
  header = table[0]
  wanted = table.drop(1)
  if rows.size != wanted.size
    return "expected #{wanted.size} rows, got #{rows.size}: #{shown(rows)}"
  end

  for i in 0...rows.size
    if not Test.eq(rows[i].keys, header).ok?
      return "row #{i + 1} has the columns #{rows[i].keys.inspect}, expected #{header.inspect}"
    end

    for c in 0...header.size
      case Cells.parse(wanted[i][c])
        error(message) -> return message
        ok(expected) ->
          actual = rows[i][header[c]]
          if not Cells.same?(actual, expected)
            return "row #{i + 1}, column #{header[c]}: expected #{wanted[i][c]}, got #{Cells.show(actual)}"
          end
      end
    end
  end

  return ""
end

def shown(rows: List[Db.Row]) -> String
  return rows.map do |row| "{#{Cells.show_row(row)}}" end.join(", ")
end
