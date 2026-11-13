## The steps of the features. They drive `Db` through `driver.agc`, which holds the connection (see `protocol.agc`).
##
## A scenario that needs a server needs its variable, `AGENTICA_DB_POSTGRES_URL` or `AGENTICA_DB_MYSQL_URL`; without
## it the step `a "postgres" database` (or `a "mysql" database`) fails. Run without a server with
## `--only "on sqlite"`.

import BDD from "std/bdd"
import Protocol from "protocol"
import {Request} from "protocol"

private

URL_VARIABLES = {"postgres": "AGENTICA_DB_POSTGRES_URL", "mysql": "AGENTICA_DB_MYSQL_URL"}
REPLY_MS = 60_000
SCRATCH_VARIABLE = "AGENTICA_DB_SCRATCH"
IO_TIMEOUT_MS = 5_000
# The `timeout_ms` of a call that takes the one of the connection (`Db.CONNECTION_DEFAULT`).
CONNECTION_DEFAULT = -1

def main() -> Void
  BDD.run([
    BDD.step("a {string} database", &open_database),
    text_step("I open {string}", "open_url"),
    text_step("I execute {string}", "execute"),
    BDD.step("I execute {string} with:") do |ctx, args| send(ctx, with_params("execute", args[0], ctx)) end,
    text_step("I query {string}", "query"),
    BDD.step("I query {string} with:") do |ctx, args| send(ctx, with_params("query", args[0], ctx)) end,
    BDD.step("I query {string} with a timeout of {int} ms") do |ctx, args|
      send(ctx, Request(op: "query_within", text: args[0], number: args[1].to_i!))
    end,
    BDD.step("I execute {string} with a timeout of {int} ms") do |ctx, args|
      send(ctx, Request(op: "execute_within", text: args[0], number: args[1].to_i!))
    end,
    BDD.step("I start a pool on {string} with:") do |ctx, args|
      send(ctx, Request(op: "pool_start", text: args[0], table: BDD.table(ctx)))
    end,
    BDD.step("I query {string} in the pool") do |ctx, args|
      send(ctx, Request(op: "pool_query", text: args[0], number: CONNECTION_DEFAULT))
    end,
    BDD.step("I query {string} in the pool with a timeout of {int} ms") do |ctx, args|
      send(ctx, Request(op: "pool_query", text: args[0], number: args[1].to_i!))
    end,
    BDD.step("I execute {string} in the pool") do |ctx, args|
      send(ctx, Request(op: "pool_execute", text: args[0], number: CONNECTION_DEFAULT))
    end,
    BDD.step("I run these statements in one block of the pool:") do |ctx, _args|
      send(ctx, Request(op: "pool_script", table: BDD.table(ctx)))
    end,
    BDD.step("I run these statements in a transaction of the pool:") do |ctx, _args|
      send(ctx, Request(op: "pool_transaction", table: BDD.table(ctx)))
    end,
    BDD.step(
      "I run these statements in a transaction of the pool, and no scheduler stops for {int} ms:",
    ) do |ctx, args| send(ctx, Request(op: "pool_transaction", table: BDD.table(ctx), number: args[0].to_i!)) end,
    BDD.step("I commit {int} transactions in the pool, each running {string}") do |ctx, args|
      send(ctx, Request(op: "pool_commits", number: args[0].to_i!, text: args[1]))
    end,
    BDD.step("I run {string} {int} times in a transaction of the pool") do |ctx, args|
      send(ctx, Request(op: "pool_repeat", text: args[0], number: args[1].to_i!))
    end,
    BDD.step(
      "{int} writers of the pool each commit {int} transactions of two rows into {string} while readers count them",
    ) do |ctx, args|
      send(ctx, Request(op: "pool_writers_readers", number: args[0].to_i!, cells: [args[1]], text: args[2]))
    end,
    BDD.step(
      "another connection to {string} holds the write lock for {int} ms while I run these in a transaction:",
    ) do |ctx, args|
      send(ctx, Request(op: "transaction_while_locked", text: args[0], number: args[1].to_i!, table: BDD.table(ctx)))
    end,
    plain_step("I read how many statements ran in a short call in the pool", "pool_short_calls"),
    plain_step("I read how many short calls left their statement to the compute pool in the pool", "pool_fallbacks"),
    plain_step("I read how many statements ran in a short call", "short_calls"),
    BDD.step("at most {int} statements ran in a short call in the pool") do |ctx, args|
      send(ctx, Request(op: "pool_short_calls_at_most", number: args[0].to_i!))
    end,
    plain_step("I close the pool", "pool_close"),
    BDD.step("the file {string} holds at most {int} bytes") do |ctx, args|
      send(ctx, Request(op: "file_size", text: args[0], number: args[1].to_i!))
    end,
    plain_step("I run a block that crashes in the pool", "pool_crash"),
    plain_step("I run a block that closes its connection in the pool", "pool_close_connection"),
    BDD.step("I keep a connection of the pool for {int} ms") do |ctx, args|
      send(ctx, Request(op: "pool_hold", number: args[0].to_i!))
    end,
    BDD.step("I cancel a task that keeps a connection of the pool for {int} ms") do |ctx, args|
      send(ctx, Request(op: "pool_cancel_holder", number: args[0].to_i!))
    end,
    BDD.step(
      "another task keeps a connection of the pool for {int} ms while I query {string} in the pool",
    ) do |ctx, args| send(ctx, Request(op: "pool_query_while_held", text: args[1], number: args[0].to_i!)) end,
    plain_step("the connection is in a transaction", "in_transaction"),
    plain_step("the connection is not in a transaction", "not_in_transaction"),
    plain_step("the connection is healthy", "healthy"),
    plain_step("the connection is not healthy", "not_healthy"),
    BDD.step("I run these statements in a transaction:") do |ctx, _args|
      send(ctx, Request(op: "transaction", table: BDD.table(ctx)))
    end,
    BDD.step("I run these statements in a transaction that fails with {string}:") do |ctx, args|
      send(ctx, Request(op: "transaction", text: args[0], table: BDD.table(ctx)))
    end,
    BDD.step(
      "I run these statements in a transaction that fails with {string}, kind {string} and code {int}:",
    ) do |ctx, args|
      send(ctx, Request(op: "transaction", text: args[0], kind: args[1], number: args[2].to_i!, table: BDD.table(ctx)))
    end,
    BDD.step("I run these statements in a transaction that gives a count:") do |ctx, _args|
      send(ctx, Request(op: "transaction", table: BDD.table(ctx), gives: true))
    end,
    BDD.step("I run these statements in a transaction that starts a transaction inside it:") do |ctx, _args|
      send(ctx, Request(op: "transaction", table: BDD.table(ctx), nested: true))
    end,
    BDD.step("{int} tasks each run these statements in a transaction on {string}:") do |ctx, args|
      send(ctx, Request(op: "write_together", number: args[0].to_i!, text: args[1], table: BDD.table(ctx)))
    end,
    BDD.step("{int} writers of the pool come in turn, each holding its transaction") do |ctx, args|
      send(ctx, Request(op: "pool_writers_in_turn", number: args[0].to_i!))
    end,
    BDD.step("a block of the pool {string} in its transaction, then a writer takes less than {int} ms") do |ctx, args|
      send(ctx, Request(op: "pool_turn_after", text: args[0], number: args[1].to_i!))
    end,
    BDD.step("a block of the pool starts a transaction on a second connection, all within {int} ms") do |ctx, args|
      send(ctx, Request(op: "pool_nested_transaction", number: args[0].to_i!))
    end,
    BDD.step("I migrate with:") do |ctx, _args| send(ctx, Request(op: "migrate", table: BDD.table(ctx))) end,
    BDD.step("I migrate the table {string} with:") do |ctx, args|
      send(ctx, Request(op: "migrate", text: args[0], table: BDD.table(ctx)))
    end,
    plain_step("I close the database", "close"),
    text_step("I make the file {string} read-only", "read_only"),
    text_step("I make the file {string} writable", "writable"),
    BDD.step("a program whose native libraries are missing") do |ctx, _args|
      BDD.given_program(without_driver_choice(ctx), "fixtures/nolib/open.agc")
    end,
    BDD.step("the program opens {string}") do |ctx, args| BDD.when_line(ctx, args[0]) end,
    BDD.step("the program answers a line starting with {string}", &answers_with),
    text_step("another task executes {string}", "execute_in_task"),
    BDD.step("another task on {string} queries {string} while I commit after {int} ms") do |ctx, args|
      send(ctx, Request(op: "query_until_commit", text: args[0], cells: [args[1]], number: args[2].to_i!))
    end,
    BDD.step("another task on {string} commits {string} while I execute {string} once it waits") do |ctx, args|
      send(ctx, Request(op: "write_while_blocked", text: args[0], cells: [args[1], args[2]]))
    end,
    BDD.step("another task on {string} holds the write lock for {int} ms while I query {string}") do |ctx, args|
      send(ctx, Request(op: "query_while_locked", text: args[0], cells: [args[2]], number: args[1].to_i!))
    end,
    BDD.step("another task on {string} holds the write lock for {int} ms while I open it") do |ctx, args|
      send(ctx, Request(op: "open_while_locked", text: args[0], number: args[1].to_i!))
    end,
    BDD.step("another task on {string} executes {string} and waits {int} ms") do |ctx, args|
      send(ctx, Request(op: "execute_waiting", text: args[0], cells: [args[1]], number: args[2].to_i!))
    end,
    text_step("another task opens its own connection and queries {string}", "query_in_new_task"),
    BDD.step("{int} tasks each query {string} on the connection at once") do |ctx, args|
      send(ctx, Request(op: "query_together", number: args[0].to_i!, text: args[1]))
    end,
    BDD.step("another task runs {string} while I query {string}, and no scheduler stops for {int} ms") do |ctx, args|
      send(ctx, Request(op: "query_beside_long", text: args[0], cells: [args[1]], number: args[2].to_i!))
    end,
    BDD.step("the write {string} that waits for {string} is cancelled beside {string} within {int} ms") do |ctx, args|
      send(ctx, Request(op: "cancel_beside_long", text: args[1], cells: [args[0], args[2]], number: args[3].to_i!))
    end,
    BDD.step("a connection of its own to {string} queries {string}") do |ctx, args|
      send(ctx, Request(op: "on_other", text: args[0], cells: [args[1]], number: 1))
    end,
    BDD.step("a connection of its own to {string} executes {string}") do |ctx, args|
      send(ctx, Request(op: "on_other", text: args[0], cells: [args[1]], number: 0))
    end,
    BDD.step("I query {string} with a JSON list of {int} numbers, and no scheduler stops for {int} ms") do |ctx, args|
      send(ctx, Request(op: "query_big_json", text: args[0], number: args[1].to_i!, cells: [args[2]]))
    end,
    plain_step("I read the statement cache", "statement_cache"),
    text_step("I check that the connection runs the driver that {string} names", "driver_named"),
    BDD.step("a task that runs {string} is cancelled after {int} ms") do |ctx, args|
      send(ctx, Request(op: "cancel_task", text: args[0], number: args[1].to_i!))
    end,
    BDD.step(
      "a task that runs {string} is cancelled after {int} ms, and then {string} takes under {int} ms",
    ) do |ctx, args|
      send(ctx, Request(op: "cancel_task", text: args[0], number: args[1].to_i!, cells: [args[2], args[3]]))
    end,
    BDD.step("I query {string} for each [N] from {int} to {int}") do |ctx, args|
      send(ctx, Request(op: "query_each", text: args[0], cells: [args[1]], number: args[2].to_i!))
    end,
    BDD.step("I query {string} with {int} characters of text while the statement cache is read") do |ctx, args|
      send(ctx, Request(op: "cache_beside_big", text: args[0], number: args[1].to_i!))
    end,
    BDD.step(
      "a task executes {string}, another executes {string}, and I close the connection after {int} ms",
    ) do |ctx, args|
      send(ctx, Request(op: "close_beside_queries", text: args[0], cells: [args[1]], number: args[2].to_i!))
    end,
    text_step("I read people with {string}", "orm_query"),
    BDD.step("I read people with {string} and:") do |ctx, args| send(ctx, with_params("orm_query", args[0], ctx)) end,
    BDD.step("I read partial people with {string}") do |ctx, args|
      send(ctx, Request(op: "orm_query", text: args[0], partial: true))
    end,
    text_step("I read the names with {string}", "orm_query_as"),
    text_step("I check the {string} schema", "orm_check"),
    BDD.step("I insert the person:") do |ctx, _args| send(ctx, Request(op: "orm_insert", table: BDD.table(ctx))) end,
    BDD.step("I insert the partial person:") do |ctx, _args|
      send(ctx, Request(op: "orm_insert", table: BDD.table(ctx), partial: true))
    end,
    BDD.step("I insert the person with its own key:") do |ctx, _args|
      send(ctx, Request(op: "orm_insert", text: "manual", table: BDD.table(ctx)))
    end,
    BDD.step("I insert a marker with no note") do |ctx, _args|
      send(ctx, Request(op: "orm_marker", text: "insert"))
    end,
    BDD.step("I update a marker with no note") do |ctx, _args|
      send(ctx, Request(op: "orm_marker", text: "update"))
    end,
    BDD.step("I delete the person with the key {string}") do |ctx, args|
      send(ctx, Request(op: "orm_delete", text: "people", cells: [args[0]]))
    end,
    BDD.step("I run the people query ending in {string}:") do |ctx, args|
      send(ctx, Request(op: "orm_builder", text: args[0], table: BDD.table(ctx)))
    end,
    text_step("I find the person with the key {string}", "orm_find"),
    BDD.step("I update the person:") do |ctx, _args| send(ctx, Request(op: "orm_update", table: BDD.table(ctx))) end,
    BDD.step("I update the partial person:") do |ctx, _args|
      send(ctx, Request(op: "orm_update", table: BDD.table(ctx), partial: true))
    end,
    BDD.step("I patch the person {int} with {string}") do |ctx, args|
      send(ctx, Request(op: "orm_patch", number: args[0].to_i!, text: args[1]))
    end,
    BDD.step("I delete the person {int}") do |ctx, args|
      send(ctx, Request(op: "orm_delete", number: args[0].to_i!, text: "people"))
    end,
    BDD.step("I delete the person {int} from the {string} schema") do |ctx, args|
      send(ctx, Request(op: "orm_delete", number: args[0].to_i!, text: args[1]))
    end,
    BDD.step("the query {string} returns:") do |ctx, args|
      asked = send(ctx, Request(op: "query", text: args[0]))
      send(asked, rows_request(asked))
    end,
    BDD.step("each value reads back unchanged in a column of its type:") do |ctx, _args|
      send(ctx, Request(op: "round_trips", table: BDD.table(ctx)))
    end,
    text_step("the server reads the float {string} exactly", "float_oracle"),
    BDD.step("the result has {int} rows, the last being:") do |ctx, args|
      send(ctx, Request(op: "expect_last", number: args[0].to_i!, table: BDD.table(ctx)))
    end,
    BDD.step("the result is:") do |ctx, _args| send(ctx, rows_request(ctx)) end,
    BDD.step("the changed row count is {int}") do |ctx, args|
      send(ctx, Request(op: "expect_count", number: args[0].to_i!))
    end,
    plain_step("it succeeds", "expect_ok"),
    plain_step("it fails with a timeout", "expect_timeout"),
    text_step("it fails with {string}", "expect_prefix"),
    text_step("the failure is a {string} error", "expect_kind"),
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
  BDD.step(pattern) do |ctx, args| send(ctx, Request(op: op, text: args[0])) end
end

# The program of the missing libraries takes the driver by itself: a run that names `native` would get "the native
# driver is not built" in place of the error of the FFI library, which this scenario is about.
def without_driver_choice(ctx: BDD.Context) -> BDD.Context
  sqlite = BDD.given_env(ctx, "AGENTICA_DB_SQLITE_DRIVER", "")
  BDD.given_env(sqlite, "AGENTICA_DB_POSTGRES_DRIVER", "")
end

# A step that captures nothing.
def plain_step(pattern: String, op: String) -> BDD.Step
  BDD.step(pattern) do |ctx, _args| send(ctx, Request(op: op)) end
end

# The program of `fixtures/nolib` answers each url with one line.
def answers_with(ctx: BDD.Context, args: List[String]) -> BDD.Context
  answer = BDD.read_line(ctx, REPLY_MS).unwrap_or("no answer")
  BDD.assert(ctx, answer.start_with?(args[0]), "the program answered #{answer.inspect}")
end

def left_open(ctx: BDD.Context, args: List[String]) -> BDD.Context
  send(ctx, Request(op: "leave_open", number: args[0].to_i!))
end

def open_database(ctx: BDD.Context, args: List[String]) -> BDD.Context
  adapter = args[0]
  variable = URL_VARIABLES.get(adapter, "")
  missing = not variable.empty? and not System.env(variable).ok?
  message = "#{variable} is not set: set it, or run only the SQLite scenarios with --only \"on sqlite\""
  checked = BDD.assert(ctx, not missing, message)
  send(checked, Request(op: "open", text: adapter))
end

# Sends the request to the driver, started on the first one, and checks that it answers ok. The driver puts what went
# wrong in the reply, which shows as the actual line of the failed check.
def send(ctx: BDD.Context, req: Request) -> BDD.Context
  running = start(ctx)
  asked = BDD.when_line(running, JSON.encode(req))
  BDD.then_line(asked, Protocol.OK, REPLY_MS)
end

def start(ctx: BDD.Context) -> BDD.Context
  return ctx if BDD.get(ctx, "driver").ok?

  # `[SCRATCH]` is a folder of this scenario under tmp/, so that test files that run at once never share, or empty,
  # one folder. The driver makes it when a scenario needs it; the hook removes it, and the scenario is not failed
  # when it cannot (Windows keeps an open database file).
  scratch = "#{Path.cwd().unwrap!}/tmp/scratch-#{OpenSSL.Random.hex(8)}"
  named = BDD.after(BDD.given_env(ctx, SCRATCH_VARIABLE, scratch)) do |_|
    make_writable("#{scratch}/readonly.db")
    _ = Path.remove(scratch, IO_TIMEOUT_MS)
    ok()
  end

  BDD.set(BDD.given_program(named, "driver.agc"), "driver", JSON.from(true))
end

# A scenario that failed between `read_only` and `writable` leaves a read-only file, which Windows refuses to remove
# (the driver has the same two commands in `set_access`). Only when the file exists: a process costs time.
def make_writable(path: String) -> Void
  return if not File.stat(path, IO_TIMEOUT_MS).ok?

  command = "chmod"
  args = ["644", path]
  if System.os() == "windows"
    command = "attrib.exe"
    args = ["-R", path.replace("/", "\\")]
  end

  started = Process.spawn(command, args, Process.Options(timeout_ms: IO_TIMEOUT_MS))
  if started.ok?
    _ = Process.wait(started.unwrap!, IO_TIMEOUT_MS)
  end
end

# The Data Table of a step is a header row and one row per item.
def body(ctx: BDD.Context) -> List[List[String]] = BDD.table(ctx).drop(1)

def with_params(op: String, sql: String, ctx: BDD.Context) -> Request
  Request(op: op, text: sql, cells: body(ctx).map do |row| row[0] end)
end

def rows_request(ctx: BDD.Context) -> Request = Request(op: "expect_rows", table: BDD.table(ctx))
