## The steps of the features. They drive `Db` through `driver.agc`, which holds the connection (see `protocol.agc`).
##
## A scenario that needs a server needs its variable, `AGENTICA_DB_POSTGRES_URL` or `AGENTICA_DB_MYSQL_URL`; without
## it the step `a "postgres" database` (or `a "mysql" database`) fails. Run without a server with
## `--only "on sqlite"`.

import BDD from "std/bdd"
import Protocol from "protocol"
import {
  Request, CacheBesideBig, CancelBesideLong, CancelTask, Close, CloseBesideQueries, DriverNamed, Execute,
  ExecuteBesideWaiting, ExecuteFresh, ExecuteInTask, ExecuteWaiting, ExecuteWithin, ExpectCount, ExpectExact,
  ExpectHides, ExpectKind, ExpectLast, ExpectMentions, ExpectOk, ExpectPrefix, ExpectRows, ExpectTimeout, Fallbacks,
  FileSize, FloatOracle, Healthy, InTransaction, KeepRunning, LeaveOpen, MigrateRun, MysqlFlavor, NoneRunning,
  NotHealthy, NotInTransaction, OnOther, Open, OpenUrl, OpenWhileLocked, OrmBuilder, OrmCheck, OrmDecode, OrmDelete,
  OrmDeleteTyped, OrmFind, OrmInsert, OrmInsertPartial, OrmMarker, OrmPartialQuery, OrmPatch, OrmQuery, OrmQueryAs,
  OrmUpdate, OrmUpdatePartial, PoolCancelHolder, PoolClose, PoolCloseConnection, PoolCommits, PoolCrash, PoolExecute,
  PoolFallbacks, PoolHold, PoolNestedTransaction, PoolQuery, PoolQueryWhileHeld, PoolRepeat, PoolRunsIn, PoolScript,
  PoolShortCalls, PoolShortCallsAtMost, PoolStart, PoolTransaction, PoolTurnAfter, PoolWriteWithin, PoolWritersInTurn,
  PoolWritersReaders, Query, QueryBesideLong, QueryBigJson, QueryEach, QueryInNewTask, QueryJsonList, QueryTogether,
  QueryUntilCommit, QueryWhileLocked, QueryWithin, ReadOnly, RoundTrips, ShortCalls, StatementCache, Transaction,
  TransactionWhileLocked, Writable, WriteTogether, WriteWhileBlocked,
} from "protocol"

private

URL_VARIABLES = {"postgres": "AGENTICA_DB_POSTGRES_URL", "mysql": "AGENTICA_DB_MYSQL_URL"}
REPLY_MS = 60_000
SCRATCH_VARIABLE = "AGENTICA_DB_SCRATCH"
IO_TIMEOUT_MS = 5_000
# A cold build of a native module runs the C compiler.
BUILD_TIMEOUT_MS = 25_000
MISSING_COMPILER = "agentica-db-no-such-cc"
# The `timeout_ms` of a call that takes the one of the connection (`Db.CONNECTION_DEFAULT`).
CONNECTION_DEFAULT = -1

def main() -> Void
  BDD.run([
    BDD.step("a {string} database", &open_database),
    text_step("I open {string}") do |text| Request.OpenUrl(OpenUrl(url: text)) end,
    text_step("I execute {string}") do |text| Request.Execute(Execute(sql: text)) end,
    BDD.step("I execute {string} with:") do |ctx, args|
      send(ctx, Request.Execute(Execute(sql: args[0], params: params_of(ctx))))
    end,
    text_step("I query {string}") do |text| Request.Query(Query(sql: text)) end,
    BDD.step("I query {string} with:") do |ctx, args|
      send(ctx, Request.Query(Query(sql: args[0], params: params_of(ctx))))
    end,
    BDD.step("I query {string} with a timeout of {int} ms") do |ctx, args|
      send(ctx, Request.QueryWithin(QueryWithin(sql: args[0], timeout_ms: args[1].to_i!)))
    end,
    BDD.step("I execute {string} with a timeout of {int} ms") do |ctx, args|
      send(ctx, Request.ExecuteWithin(ExecuteWithin(sql: args[0], timeout_ms: args[1].to_i!)))
    end,
    BDD.step("I start a pool on {string} with:") do |ctx, args|
      send(ctx, Request.PoolStart(PoolStart(url: args[0], options: BDD.table(ctx))))
    end,
    BDD.step("I query {string} in the pool") do |ctx, args|
      send(ctx, Request.PoolQuery(PoolQuery(sql: args[0], timeout_ms: CONNECTION_DEFAULT)))
    end,
    BDD.step("I query {string} in the pool with a timeout of {int} ms") do |ctx, args|
      send(ctx, Request.PoolQuery(PoolQuery(sql: args[0], timeout_ms: args[1].to_i!)))
    end,
    BDD.step("I execute {string} in the pool") do |ctx, args|
      send(ctx, Request.PoolExecute(PoolExecute(sql: args[0], timeout_ms: CONNECTION_DEFAULT)))
    end,
    BDD.step("I run these statements in one block of the pool:") do |ctx, _args|
      send(ctx, Request.PoolScript(PoolScript(statements: BDD.table(ctx))))
    end,
    BDD.step("I run these statements in a transaction of the pool:") do |ctx, _args|
      send(ctx, Request.PoolTransaction(PoolTransaction(statements: BDD.table(ctx))))
    end,
    BDD.step(
      "I run these statements in a transaction of the pool, and no scheduler stops for {int} ms:",
    ) do |ctx, args|
      send(ctx, Request.PoolTransaction(PoolTransaction(statements: BDD.table(ctx), stop_ms: args[0].to_i!)))
    end,
    BDD.step("I commit {int} transactions in the pool, each running {string}") do |ctx, args|
      send(ctx, Request.PoolCommits(PoolCommits(count: args[0].to_i!, sql: args[1])))
    end,
    BDD.step("I run {string} {int} times in a transaction of the pool") do |ctx, args|
      send(ctx, Request.PoolRepeat(PoolRepeat(sql: args[0], times: args[1].to_i!)))
    end,
    BDD.step(
      "{int} writers of the pool each commit {int} transactions of two rows into {string} while readers count them",
    ) do |ctx, args|
      send(
        ctx,
        Request.PoolWritersReaders(PoolWritersReaders(writers: args[0].to_i!, commits: args[1].to_i!, table: args[2])),
      )
    end,
    BDD.step(
      "another connection to {string} holds the write lock for {int} ms while I run these in a transaction:",
    ) do |ctx, args|
      send(
        ctx,
        Request.TransactionWhileLocked(
          TransactionWhileLocked(url: args[0], hold_ms: args[1].to_i!, statements: BDD.table(ctx)),
        ),
      )
    end,
    plain_step("I read how many statements ran in a short call in the pool", Request.PoolShortCalls(PoolShortCalls())),
    plain_step(
      "I read how many short calls left their statement to the compute pool in the pool",
      Request.PoolFallbacks(PoolFallbacks()),
    ),
    plain_step("I read how many statements ran in a short call", Request.ShortCalls(ShortCalls())),
    BDD.step("at most {int} statements ran in a short call in the pool") do |ctx, args|
      send(ctx, Request.PoolShortCallsAtMost(PoolShortCallsAtMost(most: args[0].to_i!)))
    end,
    plain_step("I close the pool", Request.PoolClose(PoolClose())),
    BDD.step("the file {string} holds at most {int} bytes") do |ctx, args|
      send(ctx, Request.FileSize(FileSize(path: args[0], most_bytes: args[1].to_i!)))
    end,
    plain_step("I run a block that crashes in the pool", Request.PoolCrash(PoolCrash())),
    plain_step(
      "I run a block that closes its connection in the pool",
      Request.PoolCloseConnection(PoolCloseConnection()),
    ),
    BDD.step("I keep a connection of the pool for {int} ms") do |ctx, args|
      send(ctx, Request.PoolHold(PoolHold(ms: args[0].to_i!)))
    end,
    BDD.step("I cancel a task that keeps a connection of the pool for {int} ms") do |ctx, args|
      send(ctx, Request.PoolCancelHolder(PoolCancelHolder(hold_ms: args[0].to_i!)))
    end,
    BDD.step("I cancel a task that holds a transaction with {string} for {int} ms") do |ctx, args|
      send(ctx, Request.PoolCancelHolder(PoolCancelHolder(sql: args[0], hold_ms: args[1].to_i!)))
    end,
    BDD.step("I execute {string} in the pool within {int} ms") do |ctx, args|
      send(ctx, Request.PoolWriteWithin(PoolWriteWithin(sql: args[0], limit_ms: args[1].to_i!)))
    end,
    BDD.step("a block of the pool runs in the task of its caller") do |ctx, _args|
      send(ctx, Request.PoolRunsIn(PoolRunsIn(place: "caller")))
    end,
    BDD.step("a block of the pool runs in a task of its own") do |ctx, _args|
      send(ctx, Request.PoolRunsIn(PoolRunsIn(place: "pool")))
    end,
    BDD.step(
      "another task keeps a connection of the pool for {int} ms while I query {string} in the pool",
    ) do |ctx, args|
      send(ctx, Request.PoolQueryWhileHeld(PoolQueryWhileHeld(sql: args[1], hold_ms: args[0].to_i!)))
    end,
    plain_step("the connection is in a transaction", Request.InTransaction(InTransaction())),
    plain_step("the connection is not in a transaction", Request.NotInTransaction(NotInTransaction())),
    plain_step("the connection is healthy", Request.Healthy(Healthy())),
    plain_step("the connection is not healthy", Request.NotHealthy(NotHealthy())),
    BDD.step("I run these statements in a transaction:") do |ctx, _args|
      send(ctx, Request.Transaction(Transaction(statements: BDD.table(ctx))))
    end,
    BDD.step("I run these statements in a transaction that fails with {string}:") do |ctx, args|
      send(ctx, Request.Transaction(Transaction(statements: BDD.table(ctx), failure: args[0])))
    end,
    BDD.step(
      "I run these statements in a transaction that fails with {string}, kind {string} and code {int}:",
    ) do |ctx, args|
      send(
        ctx,
        Request.Transaction(
          Transaction(statements: BDD.table(ctx), failure: args[0], kind: args[1], code: args[2].to_i!),
        ),
      )
    end,
    BDD.step("I run these statements in a transaction that gives a count:") do |ctx, _args|
      send(ctx, Request.Transaction(Transaction(statements: BDD.table(ctx), gives: true)))
    end,
    BDD.step("I run these statements in a transaction that starts a transaction inside it:") do |ctx, _args|
      send(ctx, Request.Transaction(Transaction(statements: BDD.table(ctx), nested: true)))
    end,
    BDD.step("{int} tasks each run these statements in a transaction on {string}:") do |ctx, args|
      send(ctx, Request.WriteTogether(WriteTogether(tasks: args[0].to_i!, url: args[1], statements: BDD.table(ctx))))
    end,
    BDD.step("{int} writers of the pool come in turn, each holding its transaction") do |ctx, args|
      send(ctx, Request.PoolWritersInTurn(PoolWritersInTurn(writers: args[0].to_i!)))
    end,
    BDD.step("a block of the pool {string} in its transaction, then a writer takes less than {int} ms") do |ctx, args|
      send(ctx, Request.PoolTurnAfter(PoolTurnAfter(mode: args[0], limit_ms: args[1].to_i!)))
    end,
    BDD.step("a block of the pool starts a transaction on a second connection, all within {int} ms") do |ctx, args|
      send(ctx, Request.PoolNestedTransaction(PoolNestedTransaction(limit_ms: args[0].to_i!)))
    end,
    BDD.step("I migrate with:") do |ctx, _args| send(ctx, Request.Migrate(MigrateRun(migrations: BDD.table(ctx)))) end,
    BDD.step("I migrate the table {string} with:") do |ctx, args|
      send(ctx, Request.Migrate(MigrateRun(history: args[0], migrations: BDD.table(ctx))))
    end,
    plain_step("I close the database", Request.Close(Close())),
    text_step("I make the file {string} read-only") do |text| Request.ReadOnly(ReadOnly(path: text)) end,
    text_step("I make the file {string} writable") do |text| Request.Writable(Writable(path: text)) end,
    BDD.step("a program whose native libraries are missing") do |ctx, _args|
      BDD.given_program(without_driver_choice(ctx), "fixtures/nolib/open.agc")
    end,
    BDD.step("a program that has only the SQLite driver") do |ctx, _args|
      BDD.given_program(without_driver_choice(ctx), "fixtures/sqlite_only.agc")
    end,
    BDD.step("the program opens {string}") do |ctx, args| BDD.when_line(ctx, args[0]) end,
    BDD.step("I compile {string} with an empty package cache") do |ctx, args| compile_cold(ctx, args[0], false) end,
    BDD.step("I compile {string} with an empty package cache and no C compiler") do |ctx, args|
      compile_cold(ctx, args[0], true)
    end,
    BDD.step("the build warns that the native module {string} is not built") do |ctx, args|
      printed(ctx, "warning: native module #{args[0]} not built")
    end,
    BDD.step("the build makes the native module {string}") do |ctx, args| built(ctx, args[0], true) end,
    BDD.step("the build never makes the native module {string}") do |ctx, args| built(ctx, args[0], false) end,
    BDD.step("the program answers a line starting with {string}", &answers_with),
    text_step("another task executes {string}") do |text| Request.ExecuteInTask(ExecuteInTask(sql: text)) end,
    BDD.step("another task on {string} queries {string} while I commit after {int} ms") do |ctx, args|
      send(ctx, Request.QueryUntilCommit(QueryUntilCommit(url: args[0], sql: args[1], commit_after_ms: args[2].to_i!)))
    end,
    BDD.step("another task on {string} commits {string} while I execute {string} once it waits") do |ctx, args|
      send(ctx, Request.WriteWhileBlocked(WriteWhileBlocked(url: args[0], write: args[1], sql: args[2])))
    end,
    BDD.step("another task on {string} holds the write lock for {int} ms while I query {string}") do |ctx, args|
      send(ctx, Request.QueryWhileLocked(QueryWhileLocked(url: args[0], sql: args[2], hold_ms: args[1].to_i!)))
    end,
    BDD.step("another task on {string} holds the write lock for {int} ms while I open it") do |ctx, args|
      send(ctx, Request.OpenWhileLocked(OpenWhileLocked(url: args[0], hold_ms: args[1].to_i!)))
    end,
    BDD.step("another task on {string} executes {string}") do |ctx, args|
      send(ctx, Request.ExecuteFresh(ExecuteFresh(url: args[0], sql: args[1])))
    end,
    BDD.step("another task on {string} executes {string} and waits {int} ms") do |ctx, args|
      send(ctx, Request.ExecuteWaiting(ExecuteWaiting(url: args[0], sql: args[1], least_ms: args[2].to_i!)))
    end,
    text_step("another task opens its own connection and queries {string}") do |text|
      Request.QueryInNewTask(QueryInNewTask(sql: text))
    end,
    BDD.step("{int} tasks each query {string} on the connection at once") do |ctx, args|
      send(ctx, Request.QueryTogether(QueryTogether(tasks: args[0].to_i!, sql: args[1])))
    end,
    BDD.step("another task runs {string} while I query {string}, and no scheduler stops for {int} ms") do |ctx, args|
      send(ctx, Request.QueryBesideLong(QueryBesideLong(long: args[0], sql: args[1], limit_ms: args[2].to_i!)))
    end,
    BDD.step("the write {string} that waits for {string} is cancelled beside {string} within {int} ms") do |ctx, args|
      send(
        ctx,
        Request.CancelBesideLong(
          CancelBesideLong(url: args[1], write: args[0], long: args[2], limit_ms: args[3].to_i!),
        ),
      )
    end,
    BDD.step("the write {string} waits for {string}, and I execute {string} once it is free") do |ctx, args|
      send(ctx, Request.ExecuteBesideWaiting(ExecuteBesideWaiting(url: args[1], write: args[0], sql: args[2])))
    end,
    BDD.step("a connection of its own to {string} queries {string}") do |ctx, args|
      send(ctx, Request.OnOther(OnOther(url: args[0], sql: args[1], query: true)))
    end,
    BDD.step("a connection of its own to {string} executes {string}") do |ctx, args|
      send(ctx, Request.OnOther(OnOther(url: args[0], sql: args[1], query: false)))
    end,
    BDD.step("I query {string} with a JSON list of {int} numbers, and no scheduler stops for {int} ms") do |ctx, args|
      send(ctx, Request.QueryBigJson(QueryBigJson(sql: args[0], items: args[1].to_i!, limit_ms: args[2].to_i!)))
    end,
    BDD.step("I query {string} with a JSON list of {int} numbers") do |ctx, args|
      send(ctx, Request.QueryJsonList(QueryJsonList(sql: args[0], items: args[1].to_i!)))
    end,
    plain_step("I read how many short calls left their statement to the compute pool", Request.Fallbacks(Fallbacks())),
    plain_step("I read the statement cache", Request.StatementCache(StatementCache())),
    BDD.step("the server is MariaDB", &mariadb_only),
    text_step("I check that the connection runs the driver that {string} names") do |text|
      Request.DriverNamed(DriverNamed(variable: text))
    end,
    BDD.step("a task that runs {string} is cancelled after {int} ms") do |ctx, args|
      send(ctx, Request.CancelTask(CancelTask(sql: args[0], cancel_after_ms: args[1].to_i!)))
    end,
    BDD.step(
      "a task that runs {string} is cancelled after {int} ms, and then {string} takes under {int} ms",
    ) do |ctx, args|
      send(
        ctx,
        Request.CancelTask(
          CancelTask(sql: args[0], cancel_after_ms: args[1].to_i!, query: args[2], limit_ms: args[3].to_i!),
        ),
      )
    end,
    BDD.step("I query {string} for each [N] from {int} to {int}") do |ctx, args|
      send(ctx, Request.QueryEach(QueryEach(sql: args[0], from: args[1].to_i!, to: args[2].to_i!)))
    end,
    BDD.step("I query {string} with {int} characters of text while the statement cache is read") do |ctx, args|
      send(ctx, Request.CacheBesideBig(CacheBesideBig(sql: args[0], size: args[1].to_i!)))
    end,
    BDD.step(
      "a task executes {string}, another executes {string}, and I close the connection after {int} ms",
    ) do |ctx, args|
      send(
        ctx,
        Request.CloseBesideQueries(CloseBesideQueries(first: args[0], second: args[1], close_after_ms: args[2].to_i!)),
      )
    end,
    text_step("I read people with {string}") do |text| Request.OrmQuery(OrmQuery(sql: text)) end,
    BDD.step("I read people with {string} and:") do |ctx, args|
      send(ctx, Request.OrmQuery(OrmQuery(sql: args[0], params: params_of(ctx))))
    end,
    BDD.step("I read partial people with {string}") do |ctx, args|
      send(ctx, Request.OrmPartialQuery(OrmPartialQuery(sql: args[0])))
    end,
    text_step("I read the names with {string}") do |text| Request.OrmQueryAs(OrmQueryAs(sql: text)) end,
    text_step("I decode people with {string}") do |text| Request.OrmDecode(OrmDecode(sql: text)) end,
    text_step("I check the {string} schema") do |text| Request.OrmCheck(OrmCheck(schema: text)) end,
    BDD.step("I insert the person:") do |ctx, _args| send(ctx, Request.OrmInsert(OrmInsert(rows: BDD.table(ctx)))) end,
    BDD.step("I insert the partial person:") do |ctx, _args|
      send(ctx, Request.OrmInsertPartial(OrmInsertPartial(rows: BDD.table(ctx))))
    end,
    BDD.step("I insert the person with its own key:") do |ctx, _args|
      send(ctx, Request.OrmInsert(OrmInsert(rows: BDD.table(ctx), manual: true)))
    end,
    BDD.step("I insert a marker with no note") do |ctx, _args|
      send(ctx, Request.OrmMarker(OrmMarker(action: "insert")))
    end,
    BDD.step("I update a marker with no note") do |ctx, _args|
      send(ctx, Request.OrmMarker(OrmMarker(action: "update")))
    end,
    BDD.step("I delete the person with the key {string}") do |ctx, args|
      send(ctx, Request.OrmDeleteTyped(OrmDeleteTyped(key: args[0])))
    end,
    BDD.step("I run the people query ending in {string}:") do |ctx, args|
      send(ctx, Request.OrmBuilder(OrmBuilder(ending: args[0], steps: BDD.table(ctx))))
    end,
    text_step("I find the person with the key {string}") do |text| Request.OrmFind(OrmFind(key: text)) end,
    BDD.step("I update the person:") do |ctx, _args| send(ctx, Request.OrmUpdate(OrmUpdate(rows: BDD.table(ctx)))) end,
    BDD.step("I update the partial person:") do |ctx, _args|
      send(ctx, Request.OrmUpdatePartial(OrmUpdatePartial(rows: BDD.table(ctx))))
    end,
    BDD.step("I patch the person {int} with {string}") do |ctx, args|
      send(ctx, Request.OrmPatch(OrmPatch(key: args[0].to_i!, changes: args[1])))
    end,
    BDD.step("I delete the person {int}") do |ctx, args|
      send(ctx, Request.OrmDelete(OrmDelete(key: args[0].to_i!)))
    end,
    BDD.step("I delete the person {int} from the {string} schema") do |ctx, args|
      send(ctx, Request.OrmDelete(OrmDelete(key: args[0].to_i!, schema: args[1])))
    end,
    BDD.step("the query {string} returns:") do |ctx, args|
      asked = send(ctx, Request.Query(Query(sql: args[0])))
      send(asked, rows_request(asked))
    end,
    BDD.step("each value reads back unchanged in a column of its type:") do |ctx, _args|
      send(ctx, Request.RoundTrips(RoundTrips(rows: BDD.table(ctx))))
    end,
    text_step("the server reads the float {string} exactly") do |text|
      Request.FloatOracle(FloatOracle(literal: text))
    end,
    BDD.step("the result has {int} rows, the last being:") do |ctx, args|
      send(ctx, Request.ExpectLast(ExpectLast(count: args[0].to_i!, rows: BDD.table(ctx))))
    end,
    BDD.step("the result is:") do |ctx, _args| send(ctx, rows_request(ctx)) end,
    BDD.step("the changed row count is {int}") do |ctx, args|
      send(ctx, Request.ExpectCount(ExpectCount(count: args[0].to_i!)))
    end,
    plain_step("it succeeds", Request.ExpectOk(ExpectOk())),
    plain_step("it fails with a timeout", Request.ExpectTimeout(ExpectTimeout())),
    text_step("it fails with {string}") do |text| Request.ExpectPrefix(ExpectPrefix(text: text)) end,
    text_step("the failure is a {string} error") do |text| Request.ExpectKind(ExpectKind(kind: text)) end,
    text_step("it fails with exactly {string}") do |text| Request.ExpectExact(ExpectExact(text: text)) end,
    text_step("it fails mentioning {string}") do |text| Request.ExpectMentions(ExpectMentions(text: text)) end,
    text_step("the failure never shows {string}") do |text| Request.ExpectHides(ExpectHides(text: text)) end,
    BDD.step("a task leaves a connection open, and the server drops its session within {int} ms", &left_open),
    BDD.step("no other session runs a statement with {string} within {int} ms") do |ctx, args|
      send(ctx, Request.NoneRunning(NoneRunning(marker: args[0], limit_ms: args[1].to_i!)))
    end,
    BDD.step("another task keeps running during {string}, with gaps under {int} milliseconds") do |ctx, args|
      send(ctx, Request.KeepRunning(KeepRunning(sql: args[0], gap_ms: args[1].to_i!)))
    end,
  ])
end

# A step that sends the request that `build` makes of its one captured text.
def text_step(pattern: String, build: Fn[String, Request]) -> BDD.Step
  BDD.step(pattern) do |ctx, args| send(ctx, build.call(args[0])) end
end

# The program of the missing libraries takes the driver by itself: a run that names `native` would get "the native
# driver is not built" in place of the error of the FFI library, which this scenario is about.
def without_driver_choice(ctx: BDD.Context) -> BDD.Context
  sqlite = BDD.given_env(ctx, "AGENTICA_DB_SQLITE_DRIVER", "")
  postgres = BDD.given_env(sqlite, "AGENTICA_DB_POSTGRES_DRIVER", "")
  BDD.given_env(postgres, "AGENTICA_DB_MYSQL_DRIVER", "")
end

# A step that captures nothing.
def plain_step(pattern: String, req: Request) -> BDD.Step = BDD.step(pattern) do |ctx, _args| send(ctx, req) end

# The program of `fixtures/nolib` answers each url with one line.
def answers_with(ctx: BDD.Context, args: List[String]) -> BDD.Context
  answer = BDD.read_line(ctx, REPLY_MS).unwrap_or("no answer")
  BDD.assert(ctx, answer.start_with?(args[0]), "the program answered #{answer.inspect}")
end

# Compiles the program `program` (a path from specs/) with a package cache of its own, empty, so that every native
# module it reaches is built (with a C compiler that does not exist when `no_compiler`), and keeps what
# agentica printed.
def compile_cold(ctx: BDD.Context, program: String, no_compiler: Bool) -> BDD.Context
  cache = "#{Path.cwd().unwrap!}/tmp/cache-#{OpenSSL.Random.hex(8)}"
  cleaned = BDD.after(ctx) do |_|
    _ = Path.remove(cache, IO_TIMEOUT_MS)
    ok()
  end

  return BDD.assert(cleaned, false, "cannot make #{cache}") if not Dir.mkdir(cache, IO_TIMEOUT_MS).ok?

  env = {"XDG_CACHE_HOME": cache, "LOCALAPPDATA": cache}
  if no_compiler
    env = env.put("CC", MISSING_COMPILER)
  end

  options = Process.Options(timeout_ms: BUILD_TIMEOUT_MS, env: env)
  compile = ["compile", "specs/#{program}", "-o", "#{cache}/program.agcb"]
  started = Process.spawn_captured("agentica", compile, options)
  case started
    error(message) -> BDD.assert(cleaned, false, "agentica did not start: #{message.message}")
    ok(process) ->
      code = Process.wait(process, BUILD_TIMEOUT_MS).unwrap_or(-1)
      printed = ""
      case Process.output(process, IO_TIMEOUT_MS)
        ok(output) -> printed = output.stdout + output.stderr
        error(message) -> printed = message.message
      end

      checked = BDD.assert(cleaned, code == 0, "agentica compile exited with #{code}: #{printed}")
      BDD.set(checked, "build", JSON.from(printed))
  end
end

# Whether the build that `compile_cold` ran made the native module `name` (`built native NAME:`), as `wanted` says.
def built(ctx: BDD.Context, name: String, wanted: Bool) -> BDD.Context
  text = build_output(ctx)
  made = text.include?("built native #{name}:")
  BDD.assert(ctx, made == wanted, "the build printed #{text.inspect}")
end

def printed(ctx: BDD.Context, wanted: String) -> BDD.Context
  text = build_output(ctx)
  BDD.assert(ctx, text.include?(wanted), "the build printed #{text.inspect}")
end

def build_output(ctx: BDD.Context) -> String
  case BDD.get(ctx, "build")
    ok(value) -> JSON.string(value).unwrap_or("")
    error(_) -> ""
  end
end

# A scenario of what MariaDB alone has (`RETURNING`) is skipped on MySQL. The driver answers with the flavor of its
# first connection.
def mariadb_only(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  asked = BDD.when_line(start(ctx), JSON.encode(Request.MysqlFlavor(MysqlFlavor())))
  answer = BDD.read_line(asked, REPLY_MS).unwrap_or("no answer")
  return BDD.skip(asked, "MariaDB only") if answer == "mysql"

  BDD.assert(asked, answer == "mariadb", "the driver answered #{answer.inspect}")
end

def left_open(ctx: BDD.Context, args: List[String]) -> BDD.Context
  send(ctx, Request.LeaveOpen(LeaveOpen(limit_ms: args[0].to_i!)))
end

def open_database(ctx: BDD.Context, args: List[String]) -> BDD.Context
  adapter = args[0]
  variable = URL_VARIABLES.get(adapter, "")
  missing = not variable.empty? and not System.env(variable).ok?
  message = "#{variable} is not set: set it, or run only the SQLite scenarios with --only \"on sqlite\""
  checked = BDD.assert(ctx, not missing, message)
  send(checked, Request.Open(Open(adapter: adapter)))
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

def params_of(ctx: BDD.Context) -> List[String] = body(ctx).map do |row| row[0] end

def rows_request(ctx: BDD.Context) -> Request = Request.ExpectRows(ExpectRows(rows: BDD.table(ctx)))
