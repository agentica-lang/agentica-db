import Db from "../db"
import {Value} from "../value"

SCRATCH_DIR = "tmp"
BIG_ROWS = 5_000

def memory() -> Result[Db.Connection]
  return Db.open("sqlite::memory:")
end

def users() -> Result[Db.Connection]
  conn = try memory()
  try Db.execute(conn, "create table users (id integer primary key, name text not null unique, age integer)", [])
  return ok(conn)
end

def add_user(conn: Db.Connection, name: String, age: Value) -> Result[Int]
  return Db.execute(conn, "insert into users (name, age) values (?, ?)", [Value.Text(name), age])
end

def names(conn: Db.Connection) -> Result[List[String]]
  rows = try Db.query(conn, "select name from users order by id", [])
  return ok(rows.map do |row| name_of(row) end)
end

def name_of(row: Map[String, Value]) -> String
  case row["name"]
    Value.Text(name) -> return name
    _ -> return "?"
  end
end

def error_starts_with(result: Result[Int], prefix: String) -> Result[Void]
  try Test.error?(result)
  return Test.assert(result.message.start_with?(prefix), "error was: #{result.message}")
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

def main() -> Void
  Test.run([
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
    Test.test("a null reads back as null and matches is null") do
      conn = try users()
      try add_user(conn, "ana", Value.Null)
      try add_user(conn, "bob", Value.Int(30))
      nulls = try Db.query(conn, "select name from users where age is null", [])
      try Test.eq(nulls, [{"name": Value.Text("ana")}])
      Test.eq(Db.query(conn, "select age from users where name = ?", [Value.Text("ana")]), ok([{"age": Value.Null}]))
    end,
    Test.test("rows come in order with their columns in order") do
      conn = try users()
      try add_user(conn, "zed", Value.Int(1))
      try add_user(conn, "amy", Value.Int(2))
      rows = try Db.query(conn, "select name as who, age, id from users order by name", [])
      try Test.eq(rows.size, 2)
      try Test.eq(rows[0].keys, ["who", "age", "id"])
      Test.eq(names(conn), ok(["zed", "amy"]))
    end,
    Test.test("a statement without a result gives no rows") do
      conn = try memory()
      Test.eq(Db.query(conn, "create table t (x)", []), ok([]))
    end,
    Test.test("a big result set comes back whole") do
      conn = try memory()
      sql = "with recursive c(x) as (select 1 union all select x + 1 from c where x < ?) select x from c"
      rows = try Db.query(conn, sql, [Value.Int(BIG_ROWS)])
      try Test.eq(rows.size, BIG_ROWS)
      Test.eq(rows[BIG_ROWS - 1], {"x": Value.Int(BIG_ROWS)})
    end,
    Test.test("execute counts the rows a statement changed") do
      conn = try users()
      try Test.eq(add_user(conn, "a", Value.Int(1)), ok(1))
      try add_user(conn, "b", Value.Int(1))
      try add_user(conn, "c", Value.Int(2))
      try Test.eq(Db.execute(conn, "update users set age = 9 where age = ?", [Value.Int(1)]), ok(2))
      try Test.eq(Db.execute(conn, "delete from users where age = ?", [Value.Int(100)]), ok(0))
      try Test.eq(Db.execute(conn, "create table other (x)", []), ok(0))
      Test.eq(Db.execute(conn, "delete from users", []), ok(3))
    end,
    Test.test("a transaction that returns ok commits") do
      conn = try users()
      done = Db.transaction(conn) do |tx|
        try add_user(tx, "ana", Value.Null)
        try add_user(tx, "bob", Value.Null)
        ok()
      end
      try Test.ok?(done)
      Test.eq(names(conn), ok(["ana", "bob"]))
    end,
    Test.test("a transaction that returns an error rolls back and gives that error") do
      conn = try users()
      try add_user(conn, "kept", Value.Null)
      done = Db.transaction(conn) do |tx|
        try add_user(tx, "lost", Value.Null)
        error("stop here")
      end
      try Test.eq(done, error("stop here"))
      Test.eq(names(conn), ok(["kept"]))
    end,
    Test.test("a failed statement inside a transaction rolls it back") do
      conn = try users()
      try add_user(conn, "dup", Value.Null)
      done = Db.transaction(conn) do |tx|
        try add_user(tx, "other", Value.Null)
        try add_user(tx, "dup", Value.Null)
        ok()
      end
      try Test.error?(done)
      try Test.assert(done.message.start_with?("sqlite error 19: "), "error was: #{done.message}")
      Test.eq(names(conn), ok(["dup"]))
    end,
    Test.test("transactions do not nest, and a new one works after the refusal") do
      conn = try users()
      done = Db.transaction(conn) do |tx|
        try add_user(tx, "inner", Value.Null)
        Db.transaction(tx) do |inner|
          ok()
        end
      end
      try Test.error?(done)
      try Test.eq(names(conn), ok([]))
      again = Db.transaction(conn) do |tx|
        try add_user(tx, "later", Value.Null)
        ok()
      end
      try Test.ok?(again)
      Test.eq(names(conn), ok(["later"]))
    end,
    Test.test("a syntax error gives the sqlite code and message") do
      conn = try memory()
      failed = Db.query(conn, "select from nowhere", [])
      try Test.error?(failed)
      Test.eq(failed.message, "sqlite error 1: near \"from\": syntax error")
    end,
    Test.test("a constraint violation gives code 19") do
      conn = try users()
      try add_user(conn, "ana", Value.Null)
      error_starts_with(add_user(conn, "ana", Value.Null), "sqlite error 19: ")
    end,
    Test.test("bad input is an error, not a halt") do
      conn = try memory()
      nul = String.from_code(0)
      try refused(conn, "select ?", [], "sqlite error: the sql has 1 parameter, got 0")
      try refused(conn, "select 1", [Value.Int(1)], "sqlite error: the sql has 0 parameters, got 1")
      try refused(conn, "select ?", [Value.Text("a#{nul}b")], "sqlite error: a text parameter contains a NUL character")
      try refused(conn, "select ?", [Value.Blob([256])], "sqlite error: a blob parameter has an item outside 0..255")
      try refused(conn, "select 1#{nul}", [], "sqlite error: the sql contains a NUL character")
      try refused(conn, "  -- nothing\n /* here */ ; ", [], "sqlite error: the sql has no statement")
      try refused(conn, "-- only a comment", [], "sqlite error: the sql has no statement")
      try refused(conn, String.from_code(12), [], "sqlite error: the sql has no statement")
      try refused(conn, String.from_code(11), [], vertical_tab_message())
      try refused(conn, "select 1; select 2", [], "sqlite error: the sql has more than one statement")
      try refused(conn, "select 1; selec 2", [], "sqlite error: the sql has more than one statement")
      two = "create table t(a); insert into t values (1)"
      try refused(conn, two, [], "sqlite error: the sql has more than one statement")
      try Test.eq(Db.query(conn, "select 1 as one -- done", []), ok([{"one": Value.Int(1)}]))
      Test.eq(Db.query(conn, "select 1 as one; -- done", []), ok([{"one": Value.Int(1)}]))
    end,
    Test.test("parameters are values, never sql") do
      conn = try users()
      try add_user(conn, "x'); drop table users; --", Value.Null)
      Test.eq(names(conn), ok(["x'); drop table users; --"]))
    end,
    Test.test("closing twice is safe") do
      conn = try memory()
      Db.close(conn)
      Db.close(conn)
      return ok()
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
    Test.test("a result with a repeated column name is an error") do
      conn = try memory()
      failed = Db.query(conn, "select 1 as a, 2 as a", [])
      try Test.error?(failed)
      Test.eq(failed.message, "sqlite error: the result has the column a twice, alias one of them")
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
  ])
end
