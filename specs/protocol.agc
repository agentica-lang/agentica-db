## The requests that the step program (`steps.agc`) sends to the driver (`driver.agc`), one JSON line each.
##
## The driver owns the database connection: a step program cannot keep a connection between its steps (the scenario
## state holds JSON only), so each scenario starts a driver process and talks to it. The driver answers every request
## with one line: `ok`, or the reason the request or the expectation failed.

## The reply that means the request worked.
export OK = "ok"

## A request. Every field is always sent; each `op` reads the ones it needs. The ops are `open` (text: adapter),
## `open_url` (text: url), `execute` and `query` (text: sql, cells: params), `transaction` (table: statements,
## text: the failure message of the body, empty for ok, nested: start a transaction inside it, gives: the body
## gives back the rows changed by its last statement, and the transaction gives that count), `close`,
## `execute_in_task`, `query_in_new_task` (text: sql), `keep_running` (text: sql, number: the longest gap in
## milliseconds), `leave_open` (text: connection name, number: milliseconds the server may take to drop it),
## `orm_query` (text: sql, cells: params), `orm_query_as` (text: sql) and `orm_check` (text: schema name),
## `round_trips` (table: column type and cell), `float_oracle` (text: a float literal), and the
## expectations `expect_rows` (table: header and rows), `expect_last` (number, table), `expect_count` (number),
## `expect_ok`, `expect_prefix`, `expect_exact`, `expect_mentions` and `expect_hides` (text).
export struct Request
  op: String
  text: String = ""
  number: Int = 0
  cells: List[String] = []
  table: List[List[String]] = []
  nested: Bool = false
  gives: Bool = false
end
