## A micro-benchmark of the SQLite adapter: the cost of one query and of one row, on an in-memory database. Run it in
## `src/db` with `agentica examples/sqlite_bench.agc`; it prints the milliseconds of each case and the cost per query
## or per row. A number depends on the machine and its load, so compare two runs of the same machine (alternate them,
## as one run is noisy), not two machines. The cases run with `?statement_cache=0` (every query is prepared and
## finalized, as before the cache) and with the default cache.
##
## - `one-row query`: `select ... where id = ?` by a bound Int, 2000 times; the cost is the prepare, one step for
##   the row and one for the end.
## - `20-row query`: a query that gives 20 rows of 3 columns, 500 times.
## - `wide`: one query that gives 2000 rows of 6 columns (2 Int, Float, Text, Blob, NULL), 20 times.

import Db from "../db"

ONE_ROW_QUERIES = 2000
TWENTY_ROW_QUERIES = 500
WIDE_ROWS = 2000
WIDE_QUERIES = 20
ROW_SIZE = 20

struct Timing
  name: String
  ms: Int
  per: Int
  unit: String
end

def main() -> Void
  for cache in [0, 128]
    report(cache, run(cache))
  end
end

def run(cache: Int) -> List[Timing]
  conn = Db.open("sqlite::memory:?statement_cache=#{cache}").unwrap!
  seed(conn)
  return [one_row(conn), twenty_rows(conn), wide(conn)]
end

def seed(conn: Db.Connection) -> Void
  create = "create table t (id integer primary key, a integer, f real, s text, b blob, n text)"
  _ = Db.execute(conn, create, []).unwrap!
  fill = (
    "with recursive c(x) as (select 1 union all select x + 1 from c limit #{WIDE_ROWS}) " +
    "insert into t select x, x * 3, x / 8.0, 'row ' || x, zeroblob(8), null from c"
  )

  _ = Db.execute(conn, fill, []).unwrap!
end

def one_row(conn: Db.Connection) -> Timing
  started = Time.monotonic_ms()
  for n in 1..ONE_ROW_QUERIES
    rows = Db.query(conn, "select id, s from t where id = ?", [Db.Value.Int(n)]).unwrap!
    check(rows.size == 1)
  end

  return timing("one-row query", started, ONE_ROW_QUERIES, "us per query")
end

def twenty_rows(conn: Db.Connection) -> Timing
  started = Time.monotonic_ms()
  for n in 1..TWENTY_ROW_QUERIES
    rows = Db.query(conn, "select id, a, s from t where id > ? limit #{ROW_SIZE}", [Db.Value.Int(n)]).unwrap!
    check(rows.size == ROW_SIZE)
  end

  return timing("20-row query", started, TWENTY_ROW_QUERIES, "us per query")
end

def wide(conn: Db.Connection) -> Timing
  started = Time.monotonic_ms()
  for _ in 1..WIDE_QUERIES
    rows = Db.query(conn, "select id, a, f, s, b, n from t", []).unwrap!
    check(rows.size == WIDE_ROWS)
  end

  return timing("wide", started, WIDE_QUERIES * WIDE_ROWS, "us per row")
end

# The benchmark stops if a query gives the wrong number of rows: a fast wrong answer is no result.
def check(passed: Bool) -> Void
  if not passed
    System.exit(1)
  end
end

def timing(name: String, started: Int, count: Int, unit: String) -> Timing
  ms = Time.monotonic_ms() - started
  return Timing(name: name, ms: ms, per: (ms * 1000) / count, unit: unit)
end

def report(cache: Int, timings: List[Timing]) -> Void
  puts("statement_cache=#{cache}")
  for t in timings
    puts("  #{t.name}: #{t.ms} ms, #{t.per} #{t.unit}")
  end
end
