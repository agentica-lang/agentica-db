## The steps of the features. They drive `Db` through `driver.agc`, which holds the connection (see `protocol.agc`).
##
## A scenario that needs PostgreSQL runs only when `AGENTICA_DB_POSTGRES_URL` is set. Without it the step
## `a "postgres" database` fails when `CI=true` and otherwise marks the scenario as skipped: every later step then
## does nothing and passes (`agentica test` has no way to skip a scenario).

import BDD from "std/bdd"
import Protocol from "protocol"
import {Request} from "protocol"

URL_VARIABLE = "AGENTICA_DB_POSTGRES_URL"
REPLY_MS = 60_000

def main() -> Void
  BDD.run([
    BDD.step("a {string} database", &open_database),
    text_step("I open {string}", "open_url"),
    text_step("I execute {string}", "execute"),
    guarded("I execute {string} with:") do |ctx, args| send(ctx, with_params("execute", args[0], ctx)) end,
    text_step("I query {string}", "query"),
    guarded("I query {string} with:") do |ctx, args| send(ctx, with_params("query", args[0], ctx)) end,
    guarded("I run these statements in a transaction:") do |ctx, args| send(ctx, statements(ctx, "")) end,
    guarded("I run these statements in a transaction that fails with {string}:") do |ctx, args|
      send(ctx, statements(ctx, args[0]))
    end,
    plain_step("I close the database", "close"),
    text_step("another task executes {string}", "execute_in_task"),
    text_step("another task opens its own connection and queries {string}", "query_in_new_task"),
    plain_step("I remove the files I created", "remove_scratch"),
    guarded("the query {string} returns:") do |ctx, args|
      asked = send(ctx, Request(op: "query", text: args[0]))
      send(asked, rows_request(asked))
    end,
    guarded("each value reads back unchanged in a column of its type:") do |ctx, args|
      send(ctx, Request(op: "round_trips", table: BDD.table(ctx)))
    end,
    guarded("the result has {int} rows, the last being:") do |ctx, args|
      send(ctx, Request(op: "expect_last", number: args[0].to_i!, table: BDD.table(ctx)))
    end,
    guarded("the result is:") do |ctx, args| send(ctx, rows_request(ctx)) end,
    guarded("the changed row count is {int}") do |ctx, args|
      send(ctx, Request(op: "expect_count", number: args[0].to_i!))
    end,
    plain_step("it succeeds", "expect_ok"),
    text_step("it fails with {string}", "expect_prefix"),
    text_step("it fails with exactly {string}", "expect_exact"),
    text_step("it fails mentioning {string}", "expect_mentions"),
    text_step("the failure never shows {string}", "expect_hides"),
    guarded("another task keeps running during {string}, with gaps under {int} milliseconds") do |ctx, args|
      send(ctx, Request(op: "keep_running", text: args[0], number: args[1].to_i!))
    end,
  ])
end

# A step that sends its one captured text.
def text_step(pattern: String, op: String) -> BDD.Step
  return guarded(pattern) do |ctx, args| send(ctx, Request(op: op, text: args[0])) end
end

# A step that captures nothing.
def plain_step(pattern: String, op: String) -> BDD.Step
  return guarded(pattern) do |ctx, args| send(ctx, Request(op: op)) end
end

# A step that does nothing in a skipped scenario, though it still makes the check that a Then step needs.
def guarded(pattern: String, handler: Fn[BDD.Context, List[String], BDD.Context]) -> BDD.Step
  return BDD.step(pattern) do |ctx, args|
    if BDD.get(ctx, "skipped").ok?
      return BDD.assert(ctx, true, "skipped")
    end

    handler.call(ctx, args)
  end
end

def open_database(ctx: BDD.Context, args: List[String]) -> BDD.Context
  adapter = args[0]
  if adapter == "postgres" and not System.env(URL_VARIABLE).ok?
    if System.env("CI").unwrap_or("") == "true"
      return BDD.assert(ctx, false, "CI must set #{URL_VARIABLE}, or the postgres scenarios do not run")
    end

    return BDD.set(ctx, "skipped", JSON.from(true))
  end

  return send(ctx, Request(op: "open", text: adapter))
end

# Sends the request to the driver, started on the first one, and checks that it answers ok.
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

def statements(ctx: BDD.Context, failure: String) -> Request
  return Request(op: "transaction", text: failure, table: BDD.table(ctx))
end

def rows_request(ctx: BDD.Context) -> Request
  return Request(op: "expect_rows", table: BDD.table(ctx))
end
