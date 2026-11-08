## A measurement of the MySQL drivers (temporary, for the pull request): a one-row query and a 1000-row query, each
## the median of 5 rounds. Run it with AGENTICA_DB_MYSQL_URL set, once per AGENTICA_DB_MYSQL_DRIVER.

import Db from "db"

ROUNDS = 5
ONE_ROW_QUERIES = 1000
WIDE_QUERIES = 40
ROWS = 1000

def main() -> Void
  case run()
    ok(line) -> puts(line)
    error(message) -> puts("failed: #{message}")
  end
end

def run() -> Result[String]
  conn = try Db.open(System.env("AGENTICA_DB_MYSQL_URL").unwrap_or(""))
  try Db.execute(conn, "create temporary table t (id integer primary key, name varchar(50), score double)", [])
  for i in 1..ROWS
    try Db.execute(
      conn,
      "insert into t values (?, ?, ?)",
      [Db.Value.Int(i), Db.Value.Text("name #{i}"), Db.Value.Float(i.to_f / 3.0)],
    )
  end

  try one_row(conn, 100)
  try wide(conn, 5)
  ones: List[Int] = []
  wides: List[Int] = []
  for _ in 0...ROUNDS
    ones = ones.push(try one_row(conn, ONE_ROW_QUERIES))
    wides = wides.push(try wide(conn, WIDE_QUERIES))
  end

  driver = System.env("AGENTICA_DB_MYSQL_DRIVER").unwrap_or("native")
  return ok("#{driver}: one row #{median(ones)} us, #{ROWS} rows #{median(wides)} us")
end

# Microseconds per query.
def one_row(conn: Db.Connection, count: Int) -> Result[Int]
  started = Time.monotonic_ns()
  for i in 0...count
    rows = try Db.query(conn, "select id, name, score from t where id = ?", [Db.Value.Int(i % ROWS + 1)])
    if rows.size != 1
      return error("one row expected")
    end
  end

  return ok((Time.monotonic_ns() - started) / 1000 / count)
end

def wide(conn: Db.Connection, count: Int) -> Result[Int]
  started = Time.monotonic_ns()
  for _ in 0...count
    rows = try Db.query(conn, "select id, name, score from t", [])
    if rows.size != ROWS
      return error("#{ROWS} rows expected")
    end
  end

  return ok((Time.monotonic_ns() - started) / 1000 / count)
end

def median(values: List[Int]) -> Int
  return values.sort[values.size / 2]
end
