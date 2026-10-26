import Db from "../db"
import Shared from "shared"
import {Value} from "../value"

SCRATCH_DIR = "tmp"
BIG_ROWS = 5_000

def memory() -> Result[Db.Connection]
  return Db.open("sqlite::memory:")
end

def vertical_tab_message() -> String
  return "sqlite error 1: unrecognized token: \"#{String.from_code(11)}\""
end

def infinity(conn: Db.Connection) -> Result[Float]
  rows = try Db.query(conn, "select 9e999 as v", [])
  case rows[0]["v"]
    Value.Float(x) -> return ok(x)
    _ -> return error("not a float")
  end
end

def round_trip(conn: Db.Connection, value: Value) -> Result[Value]
  try Db.execute(conn, "delete from t", [])
  try Db.execute(conn, "insert into t values (?)", [value])
  rows = try Db.query(conn, "select v from t", [])
  return ok(rows[0]["v"])
end

def refused(conn: Db.Connection, sql: String, params: List[Value], message: String) -> Result[Void]
  failed = Db.execute(conn, sql, params)
  try Test.error?(failed)
  return Test.eq(failed.message, message)
end

# Runs in a task of its own: the runtime error of a closed handle ends only that task.
def select_one(conn: Db.Connection) -> Result[Int]
  return Db.execute(conn, "select 1", [])
end

def flavor() -> Shared.Flavor
  return Shared.Flavor(
    name: "sqlite",
    url: "sqlite::memory:",
    id_column: "id integer primary key",
    unique_prefix: "sqlite error 19: ",
    syntax_message: "sqlite error 1: near \"selec\": syntax error",
  )
end

def main() -> Void
  Test.run(specific().concat(Shared.cases(flavor())))
end

def specific() -> List[TestCase]
  return [
    Test.test("every value kind is written with parameters and read back") do
      conn = try memory()
      try Db.execute(conn, "create table t (i integer, f real, s text, b blob, n text, flag integer)", [])
      inserted = Db.execute(conn, "insert into t values (?, ?, ?, ?, ?, ?)", [
        Value.Int(9_223_372_036_854_775_807),
        Value.Float(-0.25),
        Value.Text("héllo ✓ 日本"),
        Value.Blob([0, 1, 255, 0, 128]),
        Value.Null,
        Value.Bool(true),
      ])
      try Test.eq(inserted, ok(1))
      rows = Db.query(conn, "select i, f, s, b, n, flag from t", [])
      Test.eq(rows, ok([{
        "i": Value.Int(9_223_372_036_854_775_807),
        "f": Value.Float(-0.25),
        "s": Value.Text("héllo ✓ 日本"),
        "b": Value.Blob([0, 1, 255, 0, 128]),
        "n": Value.Null,
        "flag": Value.Int(1),
      }]))
    end,
    Test.test("values read back unchanged") do
      conn = try memory()
      try Db.execute(conn, "create table t (id integer primary key, v)", [])
      samples = [
        Value.Null,
        Value.Int(0),
        Value.Int(-1),
        Value.Int(-9_223_372_036_854_775_807),
        Value.Float(0.1),
        Value.Float(1_000_000_000_000_000_000_000_000.5),
        Value.Text(""),
        Value.Text("quote ' and \" and ? and ;"),
        Value.Text("line\nbreak\ttab ünï 🚀"),
        Value.Blob([]),
        Value.Blob([255]),
        Value.Blob(List.repeat(7, 5000)),
      ]
      for sample in samples
        try Db.execute(conn, "delete from t", [])
        try Db.execute(conn, "insert into t (v) values (?)", [sample])
        rows = try Db.query(conn, "select v from t", [])
        try Test.eq(rows, [{"v": sample}])
      end
      return ok()
    end,
    Test.test("sqlite reads a form feed as space and refuses a vertical tab") do
      conn = try memory()
      try refused(conn, String.from_code(12), [], "sqlite error: the sql has no statement")
      refused(conn, String.from_code(11), [], vertical_tab_message())
    end,
    Test.test("using a closed connection ends only the task that used it") do
      conn = try memory()
      Db.close(conn)
      task = Task.spawn(&select_one, conn)
      failed = Task.await(task)
      try Test.error?(failed)
      Test.assert(failed.message.include?("RUNTIME-NATIVE-CLOSED"), "error was: #{failed.message}")
    end,
    Test.test("a file database keeps its rows after it is closed and opened again") do
      try Dir.mkdir(SCRATCH_DIR, 1000)
      path = try Path.join([SCRATCH_DIR, "file-#{System.pid}.db"])
      conn = try Db.open("sqlite:#{path}")
      try Db.execute(conn, "create table t (x integer)", [])
      try Db.execute(conn, "insert into t values (?)", [Value.Int(42)])
      Db.close(conn)
      again = try Db.open("sqlite:#{path}")
      rows = Db.query(again, "select x from t", [])
      Db.close(again)
      try Path.remove(path, 1000)
      Test.eq(rows, ok([{"x": Value.Int(42)}]))
    end,
    Test.test("a missing directory fails to open with the sqlite code") do
      failed = Db.open("sqlite:/no/such/dir/x.db")
      try Test.error?(failed)
      Test.eq(failed.message, "sqlite error 14: unable to open database file")
    end,
    Test.test("an unknown url scheme is an error") do
      failed = Db.open("ftp://host/db")
      try Test.error?(failed)
      try Test.assert(failed.message.start_with?("db error: "), "error was: #{failed.message}")
      Test.assert(failed.message.include?("ftp://host/db"), "error was: #{failed.message}")
    end,
    Test.test("only sqlite:PATH is accepted") do
      for url in ["sqlite:///tmp/x.db", "sqlite:", "sqlite"]
        failed = Db.open(url)
        try Test.error?(failed)
        try Test.assert(failed.message.start_with?("db error: "), "error was: #{failed.message}")
      end
      return ok()
    end,
    Test.test("a statement is finalized when a row fails, so the table can be dropped") do
      conn = try memory()
      try Db.execute(conn, "create table t (x integer)", [])
      try Db.execute(conn, "insert into t values (1), (2), (3), (4)", [])
      # abs(min int) is an integer overflow, raised on the third row.
      sql = "select case when x = 3 then abs(-9223372036854775807 - 1) else x end as y from t order by x"
      failed = Db.query(conn, sql, [])
      try Test.error?(failed)
      try Test.assert(failed.message.start_with?("sqlite error 1: "), "error was: #{failed.message}")
      Test.eq(Db.execute(conn, "drop table t", []), ok(0))
    end,
    Test.test("probe statements are finalized, so the table can be dropped") do
      conn = try memory()
      try Db.execute(conn, "create table t (a)", [])
      try Test.error?(Db.query(conn, "select * from t; select 2", []))
      try Test.error?(Db.query(conn, "-- nothing", []))
      try Test.error?(Db.execute(conn, "select * from t; selec 2", []))
      try Test.ok?(Db.query(conn, "select * from t", []))
      Test.eq(Db.execute(conn, "drop table t", []), ok(0))
    end,
    Test.test("text with an embedded NUL reads back whole") do
      conn = try memory()
      nul = String.from_code(0)
      rows = Db.query(conn, "select 'a' || char(0) || 'b' as s", [])
      Test.eq(rows, ok([{"s": Value.Text("a#{nul}b")}]))
    end,
    Test.test("bool false, the smallest int, infinity and NaN") do
      conn = try memory()
      try Db.execute(conn, "create table t (v)", [])
      inf = try infinity(conn)
      try Test.eq(round_trip(conn, Value.Bool(false)), ok(Value.Int(0)))
      smallest = -9_223_372_036_854_775_807 - 1
      try Test.eq(round_trip(conn, Value.Int(smallest)), ok(Value.Int(smallest)))
      try Test.eq(round_trip(conn, Value.Float(inf)), ok(Value.Float(inf)))
      # SQLite stores NaN as NULL.
      Test.eq(round_trip(conn, Value.Float(inf - inf)), ok(Value.Null))
    end,
  ]
end
