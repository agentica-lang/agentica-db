import Db from "../db"
import Shared from "shared"
import {Value} from "../value"

URL_VARIABLE = "AGENTICA_DB_POSTGRES_URL"
BIG_ROWS = 5_000
BIG_TEXT = 200_000
BIG_BLOB = 20_000
TICKS = 40
TICK_MS = 20
MAX_TICK_GAP_MS = 300
UNREACHABLE_URL = "postgres://nobody@127.0.0.1:1/none?sslmode=disable&connect_timeout=2"
UNIQUE_PREFIX = "postgres error 23505: duplicate key value violates unique constraint"
SYNTAX_MESSAGE = "postgres error 42601: syntax error at or near \"selec\""

MIXED_TYPES_SQL = (
  "select 12.50::numeric as n, date '2024-02-29' as d, timestamp '2024-02-29 13:14:15' as ts, " +
  "'123e4567-e89b-12d3-a456-426614174000'::uuid as u, '{\"a\": 1}'::json as j, '{\"a\":1}'::jsonb as jb, " +
  "array[1, 2]::int[] as a, 'ab'::char(3) as c, 'x'::name as nm, interval '1 day' as iv, 7::oid as o"
)

# A value and the type of the column that holds it.
struct Sample
  kind: String
  value: Value
end

def flavor(url: String) -> Shared.Flavor
  return Shared.Flavor(
    name: "postgres",
    url: url,
    id_column: "id serial primary key",
    unique_prefix: UNIQUE_PREFIX,
    syntax_message: SYNTAX_MESSAGE,
  )
end

def main() -> Void
  case System.env(URL_VARIABLE)
    ok(url) -> Test.run(specific(url).concat(Shared.cases(flavor(url))))
    error(_) -> Test.run(skipped())
  end
end

# The postgres tests need a server: CI sets the variable and fails without it; elsewhere they are skipped, and the
# name of this test says so in the run output.
def skipped() -> List[TestCase]
  return [
    Test.test("postgres tests skipped: AGENTICA_DB_POSTGRES_URL is not set") do
      in_ci = System.env("CI").unwrap_or("") == "true"
      Test.assert(not in_ci, "CI must set AGENTICA_DB_POSTGRES_URL, or the postgres tests do not run")
    end,
  ]
end

# The url of the server with one more libpq parameter.
def with_parameter(url: String, parameter: String) -> String
  if url.include?("?")
    return "#{url}&#{parameter}"
  end
  return "#{url}?#{parameter}"
end

def value_of(rows: List[Map[String, Value]], column: String) -> Value
  return rows[0][column]
end

def scalar(conn: Db.Connection, sql: String, params: List[Value]) -> Result[Value]
  rows = try Db.query(conn, sql, params)
  return ok(value_of(rows, "v"))
end

def starts_with(result: Result[Value], prefix: String) -> Result[Void]
  try Test.error?(result)
  return Test.assert(result.message.start_with?(prefix), "error was: #{result.message}")
end

# Writes the value into a column of the type and reads it back.
def round_trip(conn: Db.Connection, kind: String, value: Value) -> Result[Value]
  try Db.execute(conn, "create temp table rt (v #{kind})", [])
  inserted = Db.execute(conn, "insert into rt (v) values (?)", [value])
  rows = Db.query(conn, "select v from rt", [])
  try Db.execute(conn, "drop table rt", [])
  try inserted
  return ok(value_of(try rows, "v"))
end

def float_of(value: Value) -> Float
  case value
    Value.Float(x) -> return x
    _ -> return 0.0
  end
end

def not_a_number?(value: Value) -> Bool
  case value
    Value.Float(x) -> return x != x
    _ -> return false
  end
end

def specific(url: String) -> List[TestCase]
  return [
    Test.test("every value kind is written with parameters and read back") do
      conn = try Shared.connect(flavor(url))
      try Db.execute(conn, "create temp table t (i bigint, f float8, s text, b bytea, n text, flag boolean)", [])
      inserted = Db.execute(conn, "insert into t values (?, ?, ?, ?, ?, ?)", [
        Value.Int(9_223_372_036_854_775_807),
        Value.Float(-0.25),
        Value.Text("héllo ✓ 日本 🚀"),
        Value.Blob([0, 1, 255, 0, 128]),
        Value.Null,
        Value.Bool(true),
      ])
      try Test.eq(inserted, ok(1))
      rows = Db.query(conn, "select i, f, s, b, n, flag from t", [])
      Test.eq(rows, ok([{
        "i": Value.Int(9_223_372_036_854_775_807),
        "f": Value.Float(-0.25),
        "s": Value.Text("héllo ✓ 日本 🚀"),
        "b": Value.Blob([0, 1, 255, 0, 128]),
        "n": Value.Null,
        "flag": Value.Bool(true),
      }]))
    end,
    Test.test("values read back unchanged") do
      conn = try Shared.connect(flavor(url))
      smallest = -9_223_372_036_854_775_807 - 1
      samples = [
        Sample(kind: "bigint", value: Value.Int(0)),
        Sample(kind: "bigint", value: Value.Int(-1)),
        Sample(kind: "bigint", value: Value.Int(smallest)),
        Sample(kind: "integer", value: Value.Int(2_147_483_647)),
        Sample(kind: "smallint", value: Value.Int(-32_768)),
        Sample(kind: "float8", value: Value.Float(0.1)),
        Sample(kind: "float8", value: Value.Float(1_000_000_000_000_000_000_000_000.5)),
        Sample(kind: "float8", value: Value.Float(0.0000001)),
        Sample(kind: "float8", value: Value.Float(-123456.789)),
        Sample(kind: "float4", value: Value.Float(0.5)),
        Sample(kind: "text", value: Value.Text("")),
        Sample(kind: "text", value: Value.Text("quote ' and \" and ? and ; and \\ and $1")),
        Sample(kind: "text", value: Value.Text("line\nbreak\ttab ünï 🚀")),
        Sample(kind: "varchar(5)", value: Value.Text("short")),
        Sample(kind: "bytea", value: Value.Blob([])),
        Sample(kind: "bytea", value: Value.Blob([0])),
        Sample(kind: "bytea", value: Value.Blob([255])),
        Sample(kind: "bytea", value: Value.Blob([0, 255, 0, 92, 120, 39])),
        Sample(kind: "bytea", value: Value.Blob(List.repeat(7, BIG_BLOB))),
        Sample(kind: "boolean", value: Value.Bool(true)),
        Sample(kind: "boolean", value: Value.Bool(false)),
      ]
      for sample in samples
        try Test.eq(round_trip(conn, sample.kind, sample.value), ok(sample.value))
      end
      return ok()
    end,
    Test.test("infinity and NaN round trip, and come back from the server's own spellings") do
      conn = try Shared.connect(flavor(url))
      inf = try scalar(conn, "select 'Infinity'::float8 as v", [])
      minus = try scalar(conn, "select '-Infinity'::float8 as v", [])
      nan = try scalar(conn, "select 'NaN'::float8 as v", [])
      try Test.assert(not_a_number?(nan), "NaN did not read as NaN: #{nan}")
      try Test.eq(minus, Value.Float(0.0 - float_of(inf)))
      try Test.eq(round_trip(conn, "float8", inf), ok(inf))
      try Test.eq(round_trip(conn, "float8", minus), ok(minus))
      back = try round_trip(conn, "float8", nan)
      Test.assert(not_a_number?(back), "NaN did not round trip: #{back}")
    end,
    Test.test("a float is read exactly, with or without an exponent") do
      conn = try Shared.connect(flavor(url))
      literals = ["5e-324", "1.7976931348623157e308", "-1.5e-07", "1e+20", "2.2250738585072014e-308", "0.1", "-0",
                  "123456789.123456789", "9007199254740993"]
      for literal in literals
        read = try scalar(conn, "select '#{literal}'::float8 as v", [])
        same = scalar(conn, "select ?::float8 = '#{literal}'::float8 as v", [read])
        try Test.eq(same, ok(Value.Bool(true)))
      end
      return ok()
    end,
    Test.test("a bool is a real boolean here") do
      conn = try Shared.connect(flavor(url))
      try Test.eq(scalar(conn, "select ?::boolean as v", [Value.Bool(false)]), ok(Value.Bool(false)))
      try Test.eq(scalar(conn, "select 't'::boolean as v", []), ok(Value.Bool(true)))
      Test.eq(scalar(conn, "select 1 = 2 as v", []), ok(Value.Bool(false)))
    end,
    Test.test("bytea reads back whole in the hex and the escape output formats") do
      conn = try Shared.connect(flavor(url))
      sql = "select '\\x00ff0a5c27'::bytea as v"
      expected = ok(Value.Blob([0, 255, 10, 92, 39]))
      try Test.eq(scalar(conn, sql, []), expected)
      try Db.execute(conn, "set bytea_output = 'escape'", [])
      Test.eq(scalar(conn, sql, []), expected)
    end,
    Test.test("a null of every type reads back as null") do
      conn = try Shared.connect(flavor(url))
      for kind in ["integer", "float8", "text", "bytea", "boolean", "numeric", "uuid"]
        try Test.eq(scalar(conn, "select cast(null as #{kind}) as v", []), ok(Value.Null))
        try Test.eq(round_trip(conn, kind, Value.Null), ok(Value.Null))
      end
      return ok()
    end,
    Test.test("a type without a variant comes back as text") do
      conn = try Shared.connect(flavor(url))
      rows = try Db.query(conn, MIXED_TYPES_SQL, [])
      Test.eq(rows, [{
        "n": Value.Text("12.50"),
        "d": Value.Text("2024-02-29"),
        "ts": Value.Text("2024-02-29 13:14:15"),
        "u": Value.Text("123e4567-e89b-12d3-a456-426614174000"),
        "j": Value.Text("{\"a\": 1}"),
        "jb": Value.Text("{\"a\": 1}"),
        "a": Value.Text("{1,2}"),
        "c": Value.Text("ab "),
        "nm": Value.Text("x"),
        "iv": Value.Text("1 day"),
        "o": Value.Text("7"),
      }])
    end,
    Test.test("text parameters are accepted by columns of those types") do
      conn = try Shared.connect(flavor(url))
      try Db.execute(conn, "create temp table t (n numeric, d date, u uuid, j jsonb)", [])
      uuid = "123e4567-e89b-12d3-a456-426614174000"
      try Db.execute(conn, "insert into t values (?, ?, ?, ?)", [
        Value.Text("12.50"),
        Value.Text("2024-02-29"),
        Value.Text(uuid),
        Value.Text("{\"a\": [1, 2]}"),
      ])
      rows = Db.query(conn, "select n, d, u, j from t", [])
      Test.eq(rows, ok([{
        "n": Value.Text("12.50"),
        "d": Value.Text("2024-02-29"),
        "u": Value.Text(uuid),
        "j": Value.Text("{\"a\": [1, 2]}"),
      }]))
    end,
    Test.test("integer widths come back as ints and float4 as a float") do
      conn = try Shared.connect(flavor(url))
      rows = Db.query(conn, "select 1::int2 as a, 2::int4 as b, 3::int8 as c, 0.5::float4 as d", [])
      Test.eq(rows, ok([{"a": Value.Int(1), "b": Value.Int(2), "c": Value.Int(3), "d": Value.Float(0.5)}]))
    end,
    Test.test("a big result, a big text and a big blob come back whole") do
      conn = try Shared.connect(flavor(url))
      rows = try Db.query(conn, "select x from generate_series(1, cast(? as integer)) as x", [Value.Int(BIG_ROWS)])
      try Test.eq(rows.size, BIG_ROWS)
      try Test.eq(rows[BIG_ROWS - 1], {"x": Value.Int(BIG_ROWS)})
      text = List.repeat("héllo", BIG_TEXT / 5).join("")
      try Test.eq(scalar(conn, "select ?::text as v", [Value.Text(text)]), ok(Value.Text(text)))
      blob = List.repeat(255, BIG_BLOB)
      Test.eq(scalar(conn, "select ?::bytea as v", [Value.Blob(blob)]), ok(Value.Blob(blob)))
    end,
    Test.test("utf-8 survives a connection that asks for another client encoding") do
      conn = try Db.open(with_parameter(url, "client_encoding=LATIN1"))
      text = "héllo ✓ 日本 🚀"
      try Test.eq(scalar(conn, "select ?::text as v", [Value.Text(text)]), ok(Value.Text(text)))
      Test.eq(scalar(conn, "select current_setting('client_encoding') as v", []), ok(Value.Text("UTF8")))
    end,
    Test.test("a placeholder is translated only outside literals, identifiers and comments") do
      conn = try Shared.connect(flavor(url))
      one = [Value.Int(5)]
      expected = ok([{"q": Value.Text("?"), "n": Value.Int(5)}])
      try Test.eq(Db.query(conn, "select '?' as q, ?::int as n", one), expected)
      try Test.eq(Db.query(conn, "select 'it''s ?' || '' as q, ?::int as n", one),
                  ok([{"q": Value.Text("it's ?"), "n": Value.Int(5)}]))
      try Test.eq(Db.query(conn, "select $$?$$ as q, ?::int as n", one), expected)
      try Test.eq(Db.query(conn, "select $t$ $$ ? $t$ as q, ?::int as n", one),
                  ok([{"q": Value.Text(" $$ ? "), "n": Value.Int(5)}]))
      try Test.eq(Db.query(conn, "select E'\\'?' as q, ?::int as n", one),
                  ok([{"q": Value.Text("'?"), "n": Value.Int(5)}]))
      try Test.eq(Db.query(conn, "select '?' /* ? */ as q, -- ?\n ?::int as n", one), expected)
      try Test.eq(Db.query(conn, "select 1 as \"col?\", ?::int as n", one),
                  ok([{"col?": Value.Int(1), "n": Value.Int(5)}]))
      Test.eq(Db.query(conn, "select ?::int + ?::int as n", [Value.Int(2), Value.Int(3)]), ok([{"n": Value.Int(5)}]))
    end,
    Test.test("a parameter whose type the server cannot infer needs a cast") do
      conn = try Shared.connect(flavor(url))
      try starts_with(scalar(conn, "select ? is null as v", [Value.Int(1)]), "postgres error 42P18: ")
      Test.eq(scalar(conn, "select ?::bigint as v", [Value.Int(1)]), ok(Value.Int(1)))
    end,
    Test.test("the errors carry the SQLSTATE of the server") do
      conn = try Shared.connect(flavor(url))
      try Db.execute(conn, "create temp table t (a integer not null primary key)", [])
      missing = scalar(conn, "select * from nowhere", [])
      try starts_with(missing, "postgres error 42P01: relation \"nowhere\" does not exist")
      divided = scalar(conn, "select 1 / ?::int as v", [Value.Int(0)])
      try starts_with(divided, "postgres error 22012: division by zero")
      empty = scalar(conn, "insert into t values (null)", [])
      try starts_with(empty, "postgres error 23502: null value in column \"a\"")
      try Db.execute(conn, "insert into t values (1)", [])
      failed = Db.execute(conn, "insert into t values (1)", [])
      try Test.error?(failed)
      try Test.assert(failed.message.start_with?(UNIQUE_PREFIX), "error was: #{failed.message}")
      # The connection works after any of them.
      Test.eq(scalar(conn, "select 1 as v", []), ok(Value.Int(1)))
    end,
    Test.test("a COMMIT of a failed transaction is an error, not a commit") do
      conn = try Shared.connect(flavor(url))
      try Db.execute(conn, "create temp table t (a integer)", [])
      try Db.execute(conn, "BEGIN", [])
      try Db.execute(conn, "insert into t values (1)", [])
      try Test.error?(Db.execute(conn, "select 1 / 0", []))
      committed = Db.execute(conn, "COMMIT", [])
      try Test.error?(committed)
      try Test.assert(committed.message.start_with?("postgres error 25P02: "), "error was: #{committed.message}")
      Test.eq(Db.query(conn, "select a from t", []), ok([]))
    end,
    Test.test("the verb is found after newlines and comments") do
      conn = try Shared.connect(flavor(url))
      try Db.execute(conn, "create temp table t (a integer)", [])
      try Db.execute(conn, "BEGIN\nISOLATION LEVEL SERIALIZABLE", [])
      nested = Db.execute(conn, "/* again */ begin\n", [])
      try Test.error?(nested)
      try Test.assert(nested.message.start_with?("postgres error 25001: "), "error was: #{nested.message}")
      try Db.execute(conn, "insert into t values (1)", [])
      try Test.error?(Db.execute(conn, "select 1 / 0", []))
      # The transaction is in error: a nested BEGIN is still refused, and the COMMIT is not taken for a commit.
      try Test.error?(Db.execute(conn, "begin", []))
      committed = Db.execute(conn, "-- done\n\tCOMMIT\n", [])
      try Test.assert(committed.message.start_with?("postgres error 25P02: "), "error was: #{committed.message}")
      Test.eq(Db.query(conn, "select a from t", []), ok([]))
    end,
    Test.test("a transaction body that hides a failed statement does not commit") do
      conn = try Shared.connect(flavor(url))
      try Db.execute(conn, "create temp table t (a integer)", [])
      done = Db.transaction(conn) do |tx|
        try Db.execute(tx, "insert into t values (1)", [])
        Db.execute(tx, "select 1 / 0", [])
        ok()
      end
      try Test.error?(done)
      try Test.assert(done.message.start_with?("postgres error 25P02: "), "error was: #{done.message}")
      Test.eq(Db.query(conn, "select a from t", []), ok([]))
    end,
    Test.test("an explicit ROLLBACK and a COMMIT that works are not errors") do
      conn = try Shared.connect(flavor(url))
      try Db.execute(conn, "create temp table t (a integer)", [])
      try Db.execute(conn, "begin", [])
      try Db.execute(conn, "insert into t values (1)", [])
      try Db.execute(conn, "rollback", [])
      try Test.eq(Db.query(conn, "select a from t", []), ok([]))
      try Db.execute(conn, "begin", [])
      try Db.execute(conn, "insert into t values (2)", [])
      try Db.execute(conn, "end", [])
      Test.eq(Db.query(conn, "select a from t", []), ok([{"a": Value.Int(2)}]))
    end,
    Test.test("execute counts insert, update, delete and returning, not select") do
      conn = try Shared.connect(flavor(url))
      try Db.execute(conn, "create temp table t (a integer)", [])
      try Test.eq(Db.execute(conn, "insert into t values (1), (2), (3)", []), ok(3))
      try Test.eq(Db.execute(conn, "insert into t values (4) returning a", []), ok(1))
      try Test.eq(Db.execute(conn, "select a from t", []), ok(0))
      try Test.eq(Db.execute(conn, "update t set a = a + 10 where a > ?", [Value.Int(2)]), ok(2))
      try Test.eq(Db.execute(conn, "delete from t where a > ?", [Value.Int(100)]), ok(0))
      deleted = Db.query(conn, "delete from t where a > 10 returning a", [])
      Test.eq(deleted, ok([{"a": Value.Int(13)}, {"a": Value.Int(14)}]))
    end,
    Test.test("a COPY is refused and the connection still works") do
      conn = try Shared.connect(flavor(url))
      try Db.execute(conn, "create temp table t (a integer)", [])
      try Db.execute(conn, "insert into t values (1), (2)", [])
      out = Db.query(conn, "copy t to stdout", [])
      try Test.eq(out, error("postgres error: COPY is not supported"))
      incoming = Db.execute(conn, "copy t from stdin", [])
      try Test.eq(incoming, error("postgres error: COPY is not supported"))
      Test.eq(Db.query(conn, "select count(*) as v from t", []), ok([{"v": Value.Int(2)}]))
    end,
    Test.test("a postgresql:// url works too") do
      swapped = "postgresql://#{url.slice(11, url.length - 11)}"
      conn = try Db.open(swapped)
      Test.eq(scalar(conn, "select 1 as v", []), ok(Value.Int(1)))
    end,
    Test.test("using a closed connection is an error, and closing twice is safe") do
      conn = try Shared.connect(flavor(url))
      Db.close(conn)
      failed = Db.query(conn, "select 1", [])
      try Test.eq(failed, error("postgres error: the connection is closed"))
      Db.close(conn)
      return ok()
    end,
    Test.test("a connection moves to the task that owns it") do
      task = Task.spawn(&answer, url)
      Test.eq(Task.await(task), ok(Value.Int(42)))
    end,
    Test.test("other tasks run while a query waits for the server") do
      slow = Task.spawn(&sleep_query, url)
      ticks = Task.spawn(&longest_gap, TICKS)
      try Test.ok?(Task.await(slow))
      gap = Task.await(ticks)
      Test.assert(gap < MAX_TICK_GAP_MS, "the other task was stopped for #{gap} ms during the query")
    end,
    Test.test("a bad url or an unreachable server is a postgres error") do
      refused = Db.open(UNREACHABLE_URL)
      try Test.error?(refused)
      try Test.assert(refused.message.start_with?("postgres error: "), "error was: #{refused.message}")
      bad_port = Db.open("postgres://localhost:notaport/db")
      try Test.error?(bad_port)
      try Test.assert(bad_port.message.start_with?("postgres error: "), "error was: #{bad_port.message}")
      nul = Db.open("postgres://localhost/db#{String.from_code(0)}")
      try Test.error?(nul)
      Test.eq(nul.message, "postgres error: the url contains a NUL character")
    end,
  ]
end

def answer(url: String) -> Result[Value]
  conn = try Db.open(url)
  found = scalar(conn, "select ?::int as v", [Value.Int(42)])
  Db.close(conn)
  return found
end

def sleep_query(url: String) -> Result[Value]
  conn = try Db.open(url)
  found = scalar(conn, "select pg_sleep(0.5)::text as v", [])
  Db.close(conn)
  return found
end

# The longest time between two wake-ups of a task that sleeps 20 ms at a time for a second.
def longest_gap(ticks: Int) -> Int
  longest = 0
  last = Time.monotonic_ms()
  for _ in 0...ticks
    Task.sleep(TICK_MS)
    now = Time.monotonic_ms()
    if now - last > longest
      longest = now - last
    end
    last = now
  end
  return longest
end
