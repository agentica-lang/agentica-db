## The steps of the features. They drive `Db` through `driver.agc`, which holds the connection (see `protocol.agc`).
##
## A scenario that needs a server needs its variable, `AGENTICA_DB_POSTGRES_URL` or `AGENTICA_DB_MYSQL_URL`; without
## it the step `a "postgres" database` (or `a "mysql" database`) fails. Run without a server with
## `--only "on sqlite"`.

import BDD from "std/bdd"
import Protocol from "protocol"
import {Request} from "protocol"

URL_VARIABLES = {"postgres": "AGENTICA_DB_POSTGRES_URL", "mysql": "AGENTICA_DB_MYSQL_URL"}
REPLY_MS = 60_000

def main() -> Void
  BDD.run([
    BDD.step("a {string} database", &open_database),
    text_step("I open {string}", "open_url"),
    text_step("I execute {string}", "execute"),
    BDD.step("I execute {string} with:") do |ctx, args| send(ctx, with_params("execute", args[0], ctx)) end,
    text_step("I query {string}", "query"),
    BDD.step("I query {string} with:") do |ctx, args| send(ctx, with_params("query", args[0], ctx)) end,
    BDD.step("I run these statements in a transaction:") do |ctx, args|
      send(ctx, Request(op: "transaction", table: BDD.table(ctx)))
    end,
    BDD.step("I run these statements in a transaction that fails with {string}:") do |ctx, args|
      send(ctx, Request(op: "transaction", text: args[0], table: BDD.table(ctx)))
    end,
    BDD.step("I run these statements in a transaction that starts a transaction inside it:") do |ctx, args|
      send(ctx, Request(op: "transaction", table: BDD.table(ctx), nested: true))
    end,
    plain_step("I close the database", "close"),
    BDD.step("a program whose native libraries are missing") do |ctx, args|
      BDD.given_program(ctx, "fixtures/nolib/open.agc")
    end,
    BDD.step("the program opens {string}") do |ctx, args| BDD.when_line(ctx, args[0]) end,
    BDD.step("the program answers a line starting with {string}", &answers_with),
    text_step("another task executes {string}", "execute_in_task"),
    text_step("another task opens its own connection and queries {string}", "query_in_new_task"),
    BDD.step("the query {string} returns:") do |ctx, args|
      asked = send(ctx, Request(op: "query", text: args[0]))
      send(asked, rows_request(asked))
    end,
    BDD.step("each value reads back unchanged in a column of its type:") do |ctx, args|
      send(ctx, Request(op: "round_trips", table: BDD.table(ctx)))
    end,
    text_step("the server reads the float {string} exactly", "float_oracle"),
    BDD.step("the result has {int} rows, the last being:") do |ctx, args|
      send(ctx, Request(op: "expect_last", number: args[0].to_i!, table: BDD.table(ctx)))
    end,
    BDD.step("the result is:") do |ctx, args| send(ctx, rows_request(ctx)) end,
    BDD.step("the changed row count is {int}") do |ctx, args|
      send(ctx, Request(op: "expect_count", number: args[0].to_i!))
    end,
    plain_step("it succeeds", "expect_ok"),
    text_step("it fails with {string}", "expect_prefix"),
    text_step("it fails with exactly {string}", "expect_exact"),
    text_step("it fails mentioning {string}", "expect_mentions"),
    text_step("the failure never shows {string}", "expect_hides"),
    BDD.step("a task leaves a connection open, and the server drops its session within {int} ms", &left_open),
    BDD.step("another task keeps running during {string}, with gaps under {int} milliseconds") do |ctx, args|
      send(ctx, Request(op: "keep_running", text: args[0], number: args[1].to_i!))
    end,
  ])
end

# A step that sends its one captured text.
def text_step(pattern: String, op: String) -> BDD.Step
  return BDD.step(pattern) do |ctx, args| send(ctx, Request(op: op, text: args[0])) end
end

# A step that captures nothing.
def plain_step(pattern: String, op: String) -> BDD.Step
  return BDD.step(pattern) do |ctx, args| send(ctx, Request(op: op)) end
end

# The program of `fixtures/nolib` answers each url with one line.
def answers_with(ctx: BDD.Context, args: List[String]) -> BDD.Context
  answer = BDD.read_line(ctx, REPLY_MS).unwrap_or("no answer")
  return BDD.assert(ctx, answer.start_with?(args[0]), "the program answered #{answer.inspect}")
end

def left_open(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return send(ctx, Request(op: "leave_open", number: args[0].to_i!))
end

def open_database(ctx: BDD.Context, args: List[String]) -> BDD.Context
  adapter = args[0]
  variable = URL_VARIABLES.get(adapter, "")
  missing = not variable.empty? and not System.env(variable).ok?
  message = "#{variable} is not set: set it, or run only the SQLite scenarios with --only \"on sqlite\""
  checked = BDD.assert(ctx, not missing, message)
  return send(checked, Request(op: "open", text: adapter))
end

# Sends the request to the driver, started on the first one, and checks that it answers ok. The driver puts what went
# wrong in the reply, which shows as the actual line of the failed check.
def send(ctx: BDD.Context, req: Request) -> BDD.Context
  running = start(ctx)
  asked = BDD.when_line(running, JSON.encode(req))
  return BDD.then_line(asked, Protocol.OK, REPLY_MS)
end

def start(ctx: BDD.Context) -> BDD.Context
  if BDD.get(ctx, "driver").ok?
    return ctx
  end

  return BDD.set(BDD.given_program(ctx, "driver.agc"), "driver", JSON.from(true))
end

# The Data Table of a step is a header row and one row per item.
def body(ctx: BDD.Context) -> List[List[String]]
  return BDD.table(ctx).drop(1)
end

def with_params(op: String, sql: String, ctx: BDD.Context) -> Request
  return Request(op: op, text: sql, cells: body(ctx).map do |row| row[0] end)
end

def rows_request(ctx: BDD.Context) -> Request
  return Request(op: "expect_rows", table: BDD.table(ctx))
end
