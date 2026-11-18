## The requests that the step program (`steps.agc`) sends to the driver (`driver.agc`), one JSON line each.
##
## The driver owns the database connection: a step program cannot keep a connection between its steps (the scenario
## state holds JSON only), so each scenario starts a driver process and talks to it. The driver answers every request
## with one line: `ok`, or the reason the request or the expectation failed.
##
## A `Request` is one variant per op, and the struct of a variant holds the fields that op reads, named for what they
## mean. A `url` is a database url with its markers (`[URL]`, `[SCRATCH]`), an `ms` field is a number of milliseconds,
## and a `statements`, `rows` or `steps` field is the table of a step, header row included.

## The reply that means the request worked.
OK = "ok"

struct Open
  adapter: String
end

struct OpenUrl
  url: String
end

struct Execute
  sql: String
  params: List[String] = []
end

struct Query
  sql: String
  params: List[String] = []
end

struct QueryWithin
  sql: String
  timeout_ms: Int
end

struct ExecuteWithin
  sql: String
  timeout_ms: Int
end

struct Close
end

struct InTransaction
end

struct NotInTransaction
end

struct Healthy
end

struct NotHealthy
end

## `failure` is the message the body fails with (empty for ok), `kind` and `code` the kind and code of that failure,
## `nested` starts a transaction inside it, and `gives` makes the body give back the rows changed by its last
## statement, which the transaction gives as its count.
struct Transaction
  statements: List[List[String]] = []
  failure: String = ""
  kind: String = ""
  code: Int = 0
  nested: Bool = false
  gives: Bool = false
end

## `history` is the history table, or empty; `migrations` is the header and the version, name and sql of each.
struct MigrateRun
  history: String = ""
  migrations: List[List[String]]
end

## Each of `tasks` opens `url` and runs the statements in a transaction.
struct WriteTogether
  tasks: Int
  url: String
  statements: List[List[String]]
end

## `least_ms` is the least time that the failure of the statement of a task with its own connection takes.
struct ExecuteWaiting
  url: String
  sql: String
  least_ms: Int
end

struct ExecuteFresh
  url: String
  sql: String
end

## A task with its own connection queries `sql` while this connection commits after `commit_after_ms`; the query must
## be in the way of the commit.
struct QueryUntilCommit
  url: String
  sql: String
  commit_after_ms: Int
end

## A task with its own connection writes `write` in a transaction and waits at its COMMIT for this connection, which
## runs `sql`, rolls back and gives the failure of that sql, if any.
struct WriteWhileBlocked
  url: String
  write: String
  sql: String
end

## A task with its own connection holds the write lock `hold_ms` while this connection queries `sql`.
struct QueryWhileLocked
  url: String
  sql: String
  hold_ms: Int
end

## A task with its own connection holds the write lock `hold_ms` while this connection is opened again at `url`.
struct OpenWhileLocked
  url: String
  hold_ms: Int
end

struct ReadOnly
  path: String
end

struct Writable
  path: String
end

struct ExecuteInTask
  sql: String
end

struct QueryInNewTask
  sql: String
end

## The connection runs `sql` beside the long statement `long`; the scheduler must not stop for `limit_ms`.
struct QueryBesideLong
  long: String
  sql: String
  limit_ms: Int
end

struct CancelBesideLong
  url: String
  write: String
  long: String
  limit_ms: Int
end

struct ExecuteBesideWaiting
  url: String
  write: String
  sql: String
end

## A statement on a connection of its own to `url`: a query when `query` is true, else an execute.
struct OnOther
  url: String
  sql: String
  query: Bool
end

struct QueryTogether
  tasks: Int
  sql: String
end

struct QueryBigJson
  sql: String
  items: Int
  limit_ms: Int
end

struct QueryJsonList
  sql: String
  items: Int
end

## Runs `sql` in a task that is cancelled after `cancel_after_ms`. With a `query`, its rows follow, unless they took
## `limit_ms` or more.
struct CancelTask
  sql: String
  cancel_after_ms: Int
  query: String = ""
  limit_ms: Int = 0
end

struct QueryEach
  sql: String
  from: Int
  to: Int
end

struct CacheBesideBig
  sql: String
  size: Int
end

struct CloseBesideQueries
  first: String
  second: String
  close_after_ms: Int
end

struct StatementCache
end

struct MysqlFlavor
end

struct DriverNamed
  variable: String
end

struct ShortCalls
end

struct Fallbacks
end

struct LeaveOpen
  limit_ms: Int
end

struct NoneRunning
  marker: String
  limit_ms: Int
end

struct KeepRunning
  sql: String
  gap_ms: Int
end

struct RoundTrips
  rows: List[List[String]]
end

struct FloatOracle
  literal: String
end

## `options` is the header and the options `size`, `max_overflow`, `checkout_ms`, `lease_ms`, `max_waiting`,
## `health_ms` and the `checkpoint_` ones.
struct PoolStart
  url: String
  options: List[List[String]] = []
end

struct PoolQuery
  sql: String
  timeout_ms: Int
end

struct PoolExecute
  sql: String
  timeout_ms: Int
end

struct PoolScript
  statements: List[List[String]]
end

struct PoolCloseConnection
end

struct PoolCrash
end

struct PoolHold
  ms: Int
end

## A task runs `sql` in a transaction, unless it is empty, keeps the connection `hold_ms` and is cancelled.
struct PoolCancelHolder
  sql: String = ""
  hold_ms: Int
end

struct PoolWriteWithin
  sql: String
  limit_ms: Int
end

## Where a block must run: `caller` or `pool`.
struct PoolRunsIn
  place: String
end

struct PoolQueryWhileHeld
  sql: String
  hold_ms: Int
end

## The statements run in a transaction of one block; `stop_ms` is the least scheduler stop that fails it, 0 for no
## ticker.
struct PoolTransaction
  statements: List[List[String]]
  stop_ms: Int = 0
end

struct PoolCommits
  count: Int
  sql: String
end

struct PoolWritersReaders
  writers: Int
  commits: Int
  table: String
end

struct PoolShortCalls
end

struct PoolFallbacks
end

struct PoolRepeat
  sql: String
  times: Int
end

struct PoolClose
end

struct PoolWritersInTurn
  writers: Int
end

## A block that crashes (`mode` is `crashes`) or sleeps past its lease, then a writer that must take less than
## `limit_ms`.
struct PoolTurnAfter
  mode: String
  limit_ms: Int
end

struct PoolNestedTransaction
  limit_ms: Int
end

struct TransactionWhileLocked
  url: String
  statements: List[List[String]]
  hold_ms: Int
end

struct FileSize
  path: String
  most_bytes: Int
end

struct PoolShortCallsAtMost
  most: Int
end

## The ORM ops read a Person, or a Partial whose age can be absent. `rows` is the header and the row of a person.
struct OrmQuery
  sql: String
  params: List[String] = []
end

struct OrmPartialQuery
  sql: String
  params: List[String] = []
end

struct OrmQueryAs
  sql: String
end

## `Orm.decode_row` reads each row into a Person.
struct OrmDecode
  sql: String
end

struct OrmCheck
  schema: String
end

## `manual` writes a key that is not generated.
struct OrmInsert
  rows: List[List[String]]
  manual: Bool = false
end

struct OrmInsertPartial
  rows: List[List[String]]
end

struct OrmUpdate
  rows: List[List[String]]
end

struct OrmUpdatePartial
  rows: List[List[String]]
end

struct OrmPatch
  key: Int
  changes: String
end

## The key is a number, and the schema is `people` or another one by name.
struct OrmDelete
  key: Int
  schema: String = "people"
end

## The key is a typed cell.
struct OrmDeleteTyped
  key: String
end

struct OrmFind
  key: String
end

## `insert` or `update`.
struct OrmMarker
  action: String
end

## `ending` is how the query ends; `steps` is the header and the steps.
struct OrmBuilder
  ending: String
  steps: List[List[String]]
end

struct ExpectOk
end

## The failure is one that `Db.timeout?` knows.
struct ExpectTimeout
end

struct ExpectCount
  count: Int
end

struct ExpectRows
  rows: List[List[String]]
end

struct ExpectLast
  count: Int
  rows: List[List[String]]
end

struct ExpectPrefix
  text: String
end

struct ExpectExact
  text: String
end

struct ExpectMentions
  text: String
end

struct ExpectHides
  text: String
end

## The kind that `Orm.classify` gives the failure, such as `Conflict`.
struct ExpectKind
  kind: String
end

enum Request
  Open(Open)
  OpenUrl(OpenUrl)
  Execute(Execute)
  Query(Query)
  QueryWithin(QueryWithin)
  ExecuteWithin(ExecuteWithin)
  Close(Close)
  InTransaction(InTransaction)
  NotInTransaction(NotInTransaction)
  Healthy(Healthy)
  NotHealthy(NotHealthy)
  Transaction(Transaction)
  Migrate(MigrateRun)
  WriteTogether(WriteTogether)
  ExecuteWaiting(ExecuteWaiting)
  ExecuteFresh(ExecuteFresh)
  QueryUntilCommit(QueryUntilCommit)
  WriteWhileBlocked(WriteWhileBlocked)
  QueryWhileLocked(QueryWhileLocked)
  OpenWhileLocked(OpenWhileLocked)
  ReadOnly(ReadOnly)
  Writable(Writable)
  ExecuteInTask(ExecuteInTask)
  QueryInNewTask(QueryInNewTask)
  QueryBesideLong(QueryBesideLong)
  CancelBesideLong(CancelBesideLong)
  ExecuteBesideWaiting(ExecuteBesideWaiting)
  OnOther(OnOther)
  QueryTogether(QueryTogether)
  QueryBigJson(QueryBigJson)
  QueryJsonList(QueryJsonList)
  CancelTask(CancelTask)
  QueryEach(QueryEach)
  CacheBesideBig(CacheBesideBig)
  CloseBesideQueries(CloseBesideQueries)
  StatementCache(StatementCache)
  MysqlFlavor(MysqlFlavor)
  DriverNamed(DriverNamed)
  ShortCalls(ShortCalls)
  Fallbacks(Fallbacks)
  LeaveOpen(LeaveOpen)
  NoneRunning(NoneRunning)
  KeepRunning(KeepRunning)
  RoundTrips(RoundTrips)
  FloatOracle(FloatOracle)
  PoolStart(PoolStart)
  PoolQuery(PoolQuery)
  PoolExecute(PoolExecute)
  PoolScript(PoolScript)
  PoolCloseConnection(PoolCloseConnection)
  PoolCrash(PoolCrash)
  PoolHold(PoolHold)
  PoolCancelHolder(PoolCancelHolder)
  PoolWriteWithin(PoolWriteWithin)
  PoolRunsIn(PoolRunsIn)
  PoolQueryWhileHeld(PoolQueryWhileHeld)
  PoolTransaction(PoolTransaction)
  PoolCommits(PoolCommits)
  PoolWritersReaders(PoolWritersReaders)
  PoolShortCalls(PoolShortCalls)
  PoolFallbacks(PoolFallbacks)
  PoolRepeat(PoolRepeat)
  PoolClose(PoolClose)
  PoolWritersInTurn(PoolWritersInTurn)
  PoolTurnAfter(PoolTurnAfter)
  PoolNestedTransaction(PoolNestedTransaction)
  TransactionWhileLocked(TransactionWhileLocked)
  FileSize(FileSize)
  PoolShortCallsAtMost(PoolShortCallsAtMost)
  OrmQuery(OrmQuery)
  OrmPartialQuery(OrmPartialQuery)
  OrmQueryAs(OrmQueryAs)
  OrmDecode(OrmDecode)
  OrmCheck(OrmCheck)
  OrmInsert(OrmInsert)
  OrmInsertPartial(OrmInsertPartial)
  OrmUpdate(OrmUpdate)
  OrmUpdatePartial(OrmUpdatePartial)
  OrmPatch(OrmPatch)
  OrmDelete(OrmDelete)
  OrmDeleteTyped(OrmDeleteTyped)
  OrmFind(OrmFind)
  OrmMarker(OrmMarker)
  OrmBuilder(OrmBuilder)
  ExpectOk(ExpectOk)
  ExpectTimeout(ExpectTimeout)
  ExpectCount(ExpectCount)
  ExpectRows(ExpectRows)
  ExpectLast(ExpectLast)
  ExpectPrefix(ExpectPrefix)
  ExpectExact(ExpectExact)
  ExpectMentions(ExpectMentions)
  ExpectHides(ExpectHides)
  ExpectKind(ExpectKind)
end
