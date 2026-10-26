## The tests that every adapter must pass, run through `Db` with a different `Flavor` for each.

import Db from "../db"
import {Value} from "../value"

BIG_ROWS = 5_000
BIG_SQL = (
  "with recursive c(x) as (select 1 union all select x + 1 from c where x < cast(? as integer))" +
  " select x from c"
)

## What differs between the adapters in the shared tests.
export struct Flavor
  name: String
  url: String
  id_column: String
  unique_prefix: String
  syntax_message: String
end

## The shared tests of one adapter.
export def cases(flavor: Flavor) -> List[TestCase]
  return [
    Test.test("a null reads back as null and matches is null") do
      conn = try users(flavor)
      try add_user(conn, "ana", Value.Null)
      try add_user(conn, "bob", Value.Int(30))
      nulls = try Db.query(conn, "select name from users where age is null", [])
      try Test.eq(nulls, [{"name": Value.Text("ana")}])
      Test.eq(Db.query(conn, "select age from users where name = ?", [Value.Text("ana")]), ok([{"age": Value.Null}]))
    end,
    Test.test("rows come in order with their columns in order") do
      conn = try users(flavor)
      try add_user(conn, "zed", Value.Int(1))
      try add_user(conn, "amy", Value.Int(2))
      rows = try Db.query(conn, "select name as who, age, id from users order by name", [])
      try Test.eq(rows.size, 2)
      try Test.eq(rows[0].keys, ["who", "age", "id"])
      Test.eq(names(conn), ok(["zed", "amy"]))
    end,
    Test.test("a statement without a result gives no rows") do
      conn = try connect(flavor)
      Test.eq(Db.query(conn, "create temp table t (x integer)", []), ok([]))
    end,
    Test.test("a big result set comes back whole") do
      conn = try connect(flavor)
      rows = try Db.query(conn, BIG_SQL, [Value.Int(BIG_ROWS)])
      try Test.eq(rows.size, BIG_ROWS)
      Test.eq(rows[BIG_ROWS - 1], {"x": Value.Int(BIG_ROWS)})
    end,
    Test.test("execute counts the rows a statement changed") do
      conn = try users(flavor)
      try Test.eq(add_user(conn, "a", Value.Int(1)), ok(1))
      try add_user(conn, "b", Value.Int(1))
      try add_user(conn, "c", Value.Int(2))
      try Test.eq(Db.execute(conn, "update users set age = 9 where age = ?", [Value.Int(1)]), ok(2))
      try Test.eq(Db.execute(conn, "delete from users where age = ?", [Value.Int(100)]), ok(0))
      try Test.eq(Db.execute(conn, "create temp table other (x integer)", []), ok(0))
      Test.eq(Db.execute(conn, "delete from users", []), ok(3))
    end,
    Test.test("a transaction that returns ok commits") do
      conn = try users(flavor)
      done = Db.transaction(conn) do |tx|
        try add_user(tx, "ana", Value.Null)
        try add_user(tx, "bob", Value.Null)
        ok()
      end
      try Test.ok?(done)
      Test.eq(names(conn), ok(["ana", "bob"]))
    end,
    Test.test("a transaction that returns an error rolls back and gives that error") do
      conn = try users(flavor)
      try add_user(conn, "kept", Value.Null)
      done = Db.transaction(conn) do |tx|
        try add_user(tx, "lost", Value.Null)
        error("stop here")
      end
      try Test.eq(done, error("stop here"))
      Test.eq(names(conn), ok(["kept"]))
    end,
    Test.test("a failed statement inside a transaction rolls it back") do
      conn = try users(flavor)
      try add_user(conn, "dup", Value.Null)
      done = Db.transaction(conn) do |tx|
        try add_user(tx, "other", Value.Null)
        try add_user(tx, "dup", Value.Null)
        ok()
      end
      try Test.error?(done)
      try Test.assert(done.message.start_with?(flavor.unique_prefix), "error was: #{done.message}")
      Test.eq(names(conn), ok(["dup"]))
    end,
    Test.test("transactions do not nest, and a new one works after the refusal") do
      conn = try users(flavor)
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
    Test.test("a syntax error gives the engine code and message") do
      conn = try connect(flavor)
      failed = Db.query(conn, "selec 1", [])
      try Test.error?(failed)
      Test.eq(failed.message, flavor.syntax_message)
    end,
    Test.test("a constraint violation gives the engine code") do
      conn = try users(flavor)
      try add_user(conn, "ana", Value.Null)
      error_starts_with(add_user(conn, "ana", Value.Null), flavor.unique_prefix)
    end,
    Test.test("bad input is an error, not a halt") do
      conn = try connect(flavor)
      nul = String.from_code(0)
      name = flavor.name
      try refused(conn, "select ?", [], "#{name} error: the sql has 1 parameter, got 0")
      try refused(conn, "select 1", [Value.Int(1)], "#{name} error: the sql has 0 parameters, got 1")
      text_nul = "#{name} error: a text parameter contains a NUL character"
      try refused(conn, "select ?", [Value.Text("a#{nul}b")], text_nul)
      blob_range = "#{name} error: a blob parameter has an item outside 0..255"
      try refused(conn, "select ?", [Value.Blob([256])], blob_range)
      try refused(conn, "select 1#{nul}", [], "#{name} error: the sql contains a NUL character")
      no_statement = "#{name} error: the sql has no statement"
      try refused(conn, "  -- nothing\n /* here */ ; ", [], no_statement)
      try refused(conn, "-- only a comment", [], no_statement)
      try refused(conn, "", [], no_statement)
      more = "#{name} error: the sql has more than one statement"
      try refused(conn, "select 1; select 2", [], more)
      try refused(conn, "select 1; selec 2", [], more)
      try refused(conn, "create temp table t(a); insert into t values (1)", [], more)
      try Test.eq(Db.query(conn, "select 1 as one -- done", []), ok([{"one": Value.Int(1)}]))
      Test.eq(Db.query(conn, "select 1 as one; -- done", []), ok([{"one": Value.Int(1)}]))
    end,
    Test.test("parameters are values, never sql") do
      conn = try users(flavor)
      try add_user(conn, "x'); drop table users; --", Value.Null)
      Test.eq(names(conn), ok(["x'); drop table users; --"]))
    end,
    Test.test("closing twice is safe") do
      conn = try connect(flavor)
      Db.close(conn)
      Db.close(conn)
      return ok()
    end,
    Test.test("a result with a repeated column name is an error") do
      conn = try connect(flavor)
      failed = Db.query(conn, "select 1 as a, 2 as a", [])
      try Test.error?(failed)
      Test.eq(failed.message, "#{flavor.name} error: the result has the column a twice, alias one of them")
    end,
  ]
end

## Opens a connection of the flavor.
export def connect(flavor: Flavor) -> Result[Db.Connection]
  return Db.open(flavor.url)
end

def users(flavor: Flavor) -> Result[Db.Connection]
  conn = try connect(flavor)
  sql = "create temp table users (#{flavor.id_column}, name text not null unique, age integer)"
  try Db.execute(conn, sql, [])
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

def refused(conn: Db.Connection, sql: String, params: List[Value], message: String) -> Result[Void]
  failed = Db.execute(conn, sql, params)
  try Test.error?(failed)
  return Test.eq(failed.message, message)
end
