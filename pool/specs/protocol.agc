## The requests that the step program (`steps.agc`) sends to the driver (`driver.agc`), one JSON line each.
##
## The driver owns the pool and the jobs that use it: a step program cannot keep tasks between its steps, so each
## scenario starts a driver process and talks to it. The driver answers every request with one line: `ok`, or the
## reason the request or the expectation failed.

## The reply that means the request worked.
export OK = "ok"

## A request. The ops are `start` and `start_fails` (table: the settings, a header and a name and value per row;
## text: for `start_fails`, the start of the error), `job` (name, kind: `holds`, `crashes`, `fails` or `hangs`,
## number: the milliseconds a `holds` job keeps its resource), `cancel_job` (name), `wait_jobs`, `sleep` (number),
## `close` (number: the drain in milliseconds), and the expectations `expect_job` (name, text: the start of its
## result), `expect_timeout` (name), `expect_order` (text: the names in the order they finished, joined by commas),
## `expect_count` (name: the counter, number: its value, kind: `is` or `reaches`, wait: the milliseconds to wait
## for it).
export struct Request
  op: String
  name: String = ""
  kind: String = ""
  text: String = ""
  number: Int = 0
  wait: Int = 0
  table: List[List[String]] = []
end
