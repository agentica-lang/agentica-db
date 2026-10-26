## The program under test of the features: it holds one database connection and runs the requests that
## `steps.agc` sends (`protocol.agc`), one JSON line in and one reply line out. It keeps the outcome of the last
## request, which the expectations check.

import Cells from "cells"
import Db from "../db"
import Protocol from "protocol"
import {Request} from "protocol"
import {Row, Value} from "../value"

URL_VARIABLE = "AGENTICA_DB_POSTGRES_URL"
SQLITE_MEMORY = "sqlite::memory:"
SCRATCH_ROOT = "../tmp"
NESTED = "(nested transaction)"
IGNORED = "ignored"
TICKS = 40
TICK_MS = 20
IO_TIMEOUT_MS = 5_000

# What the last request gave.
enum Outcome
  Nothing
  Failed(String)
  Counted(Int)
  Rows(List[Row])
  Done
end

# `conns` holds the one connection, or none: a connection has no empty value.
struct State
  conns: List[Db.Connection]
  adapter: String
  last: Outcome
end

struct Handled
  state: State
  reply: String
end

struct Job
  conn: Db.Connection
  sql: String
end

struct Fresh
  url: String
  sql: String
end

def main() -> Void
  state = State(conns: [], adapter: "", last: Outcome.Nothing)
  line = IO.gets
  while line.ok?
    handled = handle(state, line.unwrap!)
    state = handled.state
    puts(handled.reply.replace("\n", "\\n"))
    IO.flush()
    line = IO.gets
  end
end

def handle(state: State, line: String) -> Handled
  decoded = JSON.decode(line, Request)
  if not decoded.ok?
    return Handled(state: state, reply: "bad request: #{decoded.message}")
  end

  req = decoded.unwrap!
  case req.op
    "open" -> return opened(state, req.text)
    "open_url" -> return reply_ok(open_url(state, expand(state, req.text)))
    "execute" -> return reply_ok(with_params(state, req, &execute))
    "query" -> return reply_ok(with_params(state, req, &query))
    "transaction" -> return reply_ok(transaction(state, req))
    "close" -> return reply_ok(close(state))
    "execute_in_task" -> return reply_ok(execute_in_task(state, req.text))
    "query_in_new_task" -> return reply_ok(query_in_new_task(state, req.text))
    "keep_running" -> return keep_running(state, req.text, req.number)
    "remove_scratch" -> return reply_ok(remove_scratch(state))
    "round_trips" -> return round_trips(state, req.table)
    _ -> return expect(state, req)
  end
end

def reply_ok(state: State) -> Handled
  return Handled(state: state, reply: Protocol.OK)
end

def recorded(state: State, outcome: Outcome) -> State
  return State(conns: state.conns, adapter: state.adapter, last: outcome)
end

def failed(state: State, message: String) -> State
  return recorded(state, Outcome.Failed(message))
end

# The server url is the variable of the postgres adapter; a missing variable is reported by the step.
def server_url(adapter: String) -> String
  if adapter == "postgres"
    return System.env(URL_VARIABLE).unwrap_or("")
  end

  return SQLITE_MEMORY
end

def opened(state: State, adapter: String) -> Handled
  if adapter != "sqlite" and adapter != "postgres"
    return Handled(state: state, reply: "unknown adapter #{adapter.inspect}")
  end

  conn = Db.open(server_url(adapter))
  if not conn.ok?
    return Handled(state: state, reply: "the #{adapter} database did not open: #{conn.message}")
  end

  return reply_ok(State(conns: [conn.unwrap!], adapter: adapter, last: Outcome.Nothing))
end

# The markers of a url: `[URL]` is the server url of the adapter, `[SERVER]` the same without its scheme, and
# `[SCRATCH]` a folder of this process under tmp/, for the files of a SQLite database.
def expand(state: State, text: String) -> String
  url = server_url(state.adapter)
  without_scheme = url
  if url.include?("://")
    parts = url.split("://")
    without_scheme = parts.drop(1).join("://")
  end

  return Cells.expand(text)
    .replace("[URL]", url)
    .replace("[SERVER]", without_scheme)
    .replace("[SCRATCH]", scratch_dir())
end

def scratch_dir() -> String
  return "#{SCRATCH_ROOT}/scratch-#{System.pid()}"
end

def open_url(state: State, url: String) -> State
  if url.include?(scratch_dir())
    Dir.mkdir(scratch_dir(), IO_TIMEOUT_MS)
  end

  conn = Db.open(url)
  if not conn.ok?
    return State(conns: [], adapter: state.adapter, last: Outcome.Failed(conn.message))
  end

  return State(conns: [conn.unwrap!], adapter: state.adapter, last: Outcome.Done)
end

def with_params(state: State, req: Request, run: Fn[State, String, List[Value], State]) -> State
  params = Cells.parse_all(req.cells)
  if not params.ok?
    return failed(state, params.message)
  end

  return run.call(state, Cells.expand(req.text), params.unwrap!)
end

def execute(state: State, sql: String, params: List[Value]) -> State
  if state.conns.empty?
    return failed(state, "no database is open")
  end

  done = Db.execute(state.conns[0], sql, params)
  if not done.ok?
    return failed(state, done.message)
  end

  return recorded(state, Outcome.Counted(done.unwrap!))
end

def query(state: State, sql: String, params: List[Value]) -> State
  if state.conns.empty?
    return failed(state, "no database is open")
  end

  found = Db.query(state.conns[0], sql, params)
  if not found.ok?
    return failed(state, found.message)
  end

  return recorded(state, Outcome.Rows(found.unwrap!))
end

def close(state: State) -> State
  state.conns.each do |conn| Db.close(conn) end
  return recorded(state, Outcome.Done)
end

# Each row of the table is a statement (the header row is skipped); a failed statement stops the body with its error
# unless the row says `ignored`. The body ends with the failure message of the request, or with ok.
def transaction(state: State, req: Request) -> State
  if state.conns.empty?
    return failed(state, "no database is open")
  end

  rows = req.table.drop(1)
  done = Db.transaction(state.conns[0]) do |tx| run_body(tx, rows, req.text) end
  if not done.ok?
    return failed(state, done.message)
  end

  return recorded(state, Outcome.Done)
end

def run_body(tx: Db.Connection, rows: List[List[String]], failure: String) -> Result[Void]
  for row in rows
    done = run_statement(tx, Cells.expand(row[0]))
    if not done.ok? and not (row.size > 1 and row[1] == IGNORED)
      return done
    end
  end

  if not failure.empty?
    return error(failure)
  end

  return ok()
end

def run_statement(tx: Db.Connection, sql: String) -> Result[Void]
  if sql == NESTED
    return Db.transaction(tx) do |inner| ok() end
  end

  try Db.execute(tx, sql, [])
  return ok()
end

# A runtime error in the task ends only the task, and its await gives it as an error.
def run_job(job: Job) -> Result[Int]
  return Db.execute(job.conn, job.sql, [])
end

def execute_in_task(state: State, sql: String) -> State
  if state.conns.empty?
    return failed(state, "no database is open")
  end

  done = Task.await(Task.spawn(&run_job, Job(conn: state.conns[0], sql: Cells.expand(sql))))
  if not done.ok?
    return failed(state, done.message)
  end

  return recorded(state, Outcome.Counted(done.unwrap!))
end

def fresh_query(job: Fresh) -> Result[List[Row]]
  conn = try Db.open(job.url)
  found = Db.query(conn, job.sql, [])
  Db.close(conn)
  return found
end

def query_in_new_task(state: State, sql: String) -> State
  job = Fresh(url: server_url(state.adapter), sql: Cells.expand(sql))
  found = Task.await(Task.spawn(&fresh_query, job))
  if not found.ok?
    return failed(state, found.message)
  end

  return recorded(state, Outcome.Rows(found.unwrap!))
end

def remove_scratch(state: State) -> State
  Path.remove(scratch_dir(), IO_TIMEOUT_MS)
  return recorded(state, Outcome.Done)
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

# Each table row is a column type and a cell: a table with a column of that type is written with the cell as a
# parameter and read back, and the value must come back the same.
def round_trips(state: State, table: List[List[String]]) -> Handled
  if state.conns.empty?
    return Handled(state: state, reply: "no database is open")
  end

  conn = state.conns[0]
  for row in table.drop(1)
    wrote = Cells.parse(row[1])
    if not wrote.ok?
      return Handled(state: state, reply: wrote.message)
    end

    verdict = round_trip(conn, row[0], wrote.unwrap!)
    if not verdict.empty?
      return Handled(state: state, reply: "#{row[0]} column, #{verdict}")
    end
  end

  return reply_ok(state)
end

# The empty string when the value came back the same.
def round_trip(conn: Db.Connection, kind: String, value: Value) -> String
  created = Db.execute(conn, "create temp table rt (v #{kind})", [])
  if not created.ok?
    return created.message
  end

  inserted = Db.execute(conn, "insert into rt (v) values (?)", [value])
  found = Db.query(conn, "select v from rt", [])
  Db.execute(conn, "drop table rt", [])
  if not inserted.ok?
    return "the insert failed: #{inserted.message}"
  end

  if not found.ok?
    return "the select failed: #{found.message}"
  end

  if found.unwrap!.size != 1 or not Cells.same?(found.unwrap![0]["v"], value)
    return "wrote #{Cells.show(value)}, read back #{shown(found.unwrap!)}"
  end

  return ""
end

def keep_running(state: State, sql: String, limit: Int) -> Handled
  slow = Task.spawn(&fresh_query, Fresh(url: server_url(state.adapter), sql: Cells.expand(sql)))
  ticks = Task.spawn(&longest_gap, TICKS)
  found = Task.await(slow)
  gap = Task.await(ticks)
  if not found.ok?
    return Handled(state: state, reply: "the query failed: #{found.message}")
  end

  if gap >= limit
    return Handled(state: state, reply: "the other task was stopped for #{gap} ms during the query")
  end

  return reply_ok(state)
end

def expect(state: State, req: Request) -> Handled
  verdict = judge(state.last, req)
  if verdict.empty?
    return reply_ok(state)
  end

  return Handled(state: state, reply: verdict)
end

# The empty string when the last outcome is what the request expects, else what went wrong.
def judge(last: Outcome, req: Request) -> String
  case req.op
    "expect_ok" -> return judge_ok(last)
    "expect_count" -> return judge_count(last, req.number)
    "expect_rows" -> return judge_rows(last, req.table)
    "expect_last" -> return judge_last(last, req.number, req.table)
    "expect_prefix" -> return judge_failure(last, req) do |message| message.start_with?(Cells.expand(req.text)) end
    "expect_exact" -> return judge_failure(last, req) do |message| message == Cells.expand(req.text) end
    "expect_mentions" -> return judge_failure(last, req) do |message| message.include?(Cells.expand(req.text)) end
    "expect_hides" -> return judge_failure(last, req) do |message| not message.include?(Cells.expand(req.text)) end
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
def judge_failure(last: Outcome, req: Request, accepted: Fn[String, Bool]) -> String
  case last
    Outcome.Failed(message) if accepted.call(message) -> return ""
    Outcome.Failed(message) -> return "unexpected failure #{message.inspect}, wanted #{req.op} #{req.text.inspect}"
    _ -> return "expected a failure, but it succeeded"
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
def compare_rows(rows: List[Row], table: List[List[String]]) -> String
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
      expected = Cells.parse(wanted[i][c])
      if not expected.ok?
        return expected.message
      end

      if not Cells.same?(rows[i][header[c]], expected.unwrap!)
        return "row #{i + 1}, column #{header[c]}: expected #{wanted[i][c]}, got #{shown(rows)}"
      end
    end
  end

  return ""
end

def shown(rows: List[Row]) -> String
  return rows.map do |row| "{#{Cells.show_row(row)}}" end.join(", ")
end
