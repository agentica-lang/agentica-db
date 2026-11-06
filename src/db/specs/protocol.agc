## The requests that the step program (`steps.agc`) sends to the driver (`driver.agc`), one JSON line each.
##
## The driver owns the database connection: a step program cannot keep a connection between its steps (the scenario
## state holds JSON only), so each scenario starts a driver process and talks to it. The driver answers every request
## with one line: `ok`, or the reason the request or the expectation failed.

## The reply that means the request worked.
export OK = "ok"

## A request. Every field is always sent; each `op` reads the ones it needs. The ops are `open` (text: adapter),
## `open_url` (text: url), `execute` and `query` (text: sql, cells: params), `transaction` (table: statements, text:
## the failure message of the body, empty for ok, nested: start a transaction inside it, gives: the body gives back the
## rows changed by its last statement, and the transaction gives that count), `close`, `migrate` (text: the history
## table or empty, table: header and the version, name and sql of each migration), `write_together` (number: the tasks,
## text: a database url, table: statements; each task opens the url and runs the statements in a transaction),
## `execute_waiting` (text: a database url, cells: the sql, number: the least time in milliseconds that the failure of
## the statement of a task with its own connection takes), `query_until_commit` (text: a database url, cells: the sql,
## number: milliseconds; a task with its own connection queries the sql while this connection commits after that time,
## and the query must be in the way of the commit), `write_while_blocked` (text: a database url, cells: the sql of a
## write and the sql that this connection runs; a task with its own connection writes it in a transaction and waits at
## its COMMIT for this connection, which runs the second sql, rolls back and gives the failure of that sql, if any),
## `query_while_locked` (text: a database url, cells: the sql, number: milliseconds; a task with its own connection
## holds the write lock that long while this connection queries the sql), `open_while_locked` (text: a database url,
## number: milliseconds; a task with its own connection holds the write lock that long while this connection is
## opened again at the url), `read_only` and `writable` (text: a file),
## `execute_in_task`, `query_in_new_task` (text: sql), `keep_running` (text: sql, number: the longest gap in
## milliseconds), `leave_open` (text: connection name, number: milliseconds the server may take to drop it),
## `orm_query` (text: sql, cells: params, partial: read a Partial, whose age can be absent), `orm_query_as` (text: sql)
## and `orm_check` (text: schema name), `orm_insert` (table: a header and the row of a Person, text: `manual` for a key
## that is not generated, partial: write a Partial) and `orm_update` (table, partial), `orm_patch` (number: the key,
## text: the changes as JSON), `orm_delete` (number: the key or cells: the key as a typed cell, text: schema name),
## `orm_marker` (text: `insert` or `update`), `orm_builder` (text: how the query ends, table: its steps) and `orm_find`
## (text: the key as a typed cell), `round_trips` (table: column type and cell), `float_oracle` (text: a float
## literal), `query_within` and `execute_within` (text: sql, number: the `timeout_ms` of the call), `in_transaction`,
## `not_in_transaction`, `healthy` and `not_healthy` (they check the answer of `Db.in_transaction?` and `Db.healthy?`),
## `statements` and `pool_statements` (the number of prepared statements of the SQLite connection, or of the one a
## block of the pool gets, for `expect_count`), `close_while_running` (text: a long sql that a task runs while this one
## closes the connection) and `expect_gone` (text: a file that must not exist or must be empty),
## the ops of `DbPool`: `pool_start` (text: a database url, table: header and the options `size`, `max_overflow`,
## `checkout_ms` and `lease_ms`), `pool_query` and `pool_execute` (text: sql, number: the `timeout_ms` of the call;
## each runs in one block of the pool), `pool_script` (table: header and statements, run in one block),
## `pool_close_connection` (a block that closes its connection), `pool_crash` (a block that crashes), `pool_hold`
## (number: the milliseconds a block keeps its connection), `pool_query_while_held` (text: sql, number: the
## milliseconds a task keeps a connection of the pool while this one queries), and the expectations `expect_rows`
## (table: header and rows), `expect_last` (number, table), `expect_count` (number), `expect_ok`, `expect_timeout` (the
## failure is one that `Db.timeout?` knows), `expect_prefix`, `expect_exact`, `expect_mentions`, `expect_hides` and
## `expect_kind` (text; for the last, the kind that `Orm.classify` gives the failure, such as `Conflict`).
export struct Request
  op: String
  text: String = ""
  number: Int = 0
  cells: List[String] = []
  table: List[List[String]] = []
  nested: Bool = false
  gives: Bool = false
  partial: Bool = false
end
