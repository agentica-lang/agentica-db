## A row through a database: the cells of `value_gens.agc` written with bound parameters and read back, against the
## cells that the database promises to give back (`held`, the cells themselves but for what SQLite does to a NaN and
## a negative zero). The table of an adapter has the types that the adapter has; a type with no `Value` variant
## (decimal, date, time) is written and read as text. CI runs it once per driver, and both give the same model, so
## the drivers agree.

import Db from "pkg/db/db"
import Mysql from "pkg/db/mysql"
import Postgres from "pkg/db/postgres"
import Sqlite from "pkg/db/sqlite"
import Cells from "pkg/db/specs/cells"
import Prop from "pkg/prop/prop"
import Gens from "value_gens"

## The databases a property runs on.
enum Adapter
  Sqlite
  Postgres
  Mysql
end

## Writes generated rows to a database of `adapter` and reads them back, `runs` times, and checks that each row reads
## back as `held` says (`Prop.oracle`: a failure names the shrunk row and the seed). PostgreSQL and MySQL need their
## url variable.
def reads_back(adapter: Adapter, runs: Int) -> Result[Void]
  conn = try connect(adapter)
  columns = columns_of(adapter)
  made = Db.execute(conn, create_sql(columns), [])
  if not made.ok?
    Db.close(conn)
    return error(made.message)
  end

  unsigned_zero = adapter == Adapter.Sqlite or mariadb?(conn, adapter)
  checked = Prop.oracle(row_gen(adapter), through(conn, columns), Prop.Config(runs: runs)) do |cells|
    held(adapter, unsigned_zero, cells)
  end

  Db.close(conn)
  checked
end

## The generator of a row of the table of `adapter`: a list of cells, one for each column.
def row_gen(adapter: Adapter) -> Prop.Gen[List[String]]
  kinds = float_kinds(adapter)

  core = Prop.pair(Prop.pair(Gens.int_cell(), Gens.float_cell(kinds)), Prop.pair(Gens.text_cell(), Gens.blob_cell()))
  if adapter == Adapter.Sqlite
    return Prop.map(core) do |pairs|
      [pairs.first.first, pairs.first.second, pairs.second.first, pairs.second.second]
    end
  end

  temporal = Prop.pair(
    Prop.pair(Gens.decimal_cell(), Gens.date_cell()),
    Prop.pair(Gens.timestamp_cell(), Gens.time_cell()),
  )

  Prop.map(Prop.pair(core, temporal)) do |pair|
    [
      pair.first.first.first,
      pair.first.first.second,
      pair.first.second.first,
      pair.first.second.second,
      pair.second.first.first,
      pair.second.first.second,
      pair.second.second.first,
      pair.second.second.second,
    ]
  end
end

private

struct Column
  name: String
  type: String
end

def connect(adapter: Adapter) -> Result[Db.Connection]
  case adapter
    Adapter.Sqlite -> Db.open("sqlite::memory:", [Sqlite.driver()])
    Adapter.Postgres -> Db.open(try System.env("AGENTICA_DB_POSTGRES_URL"), [Postgres.driver()])
    Adapter.Mysql -> Db.open(try System.env("AGENTICA_DB_MYSQL_URL"), [Mysql.driver()])
  end
end

def columns_of(adapter: Adapter) -> List[Column]
  core = [Column(name: "i", type: "bigint"), Column(name: "f", type: "double precision")]
  case adapter
    Adapter.Sqlite -> core.concat([Column(name: "s", type: "text"), Column(name: "b", type: "blob")])
    Adapter.Postgres ->
      core.concat([
        Column(name: "s", type: "text"),
        Column(name: "b", type: "bytea"),
        Column(name: "n", type: "numeric(20, 4)"),
        Column(name: "d", type: "date"),
        Column(name: "ts", type: "timestamp"),
        Column(name: "tm", type: "time"),
      ])
    Adapter.Mysql ->
      core.concat([
        Column(name: "s", type: "longtext"),
        Column(name: "b", type: "longblob"),
        Column(name: "n", type: "decimal(20, 4)"),
        Column(name: "d", type: "date"),
        Column(name: "ts", type: "datetime"),
        Column(name: "tm", type: "time"),
      ])
  end
end

# MySQL has no NaN and no infinity, and its adapter refuses them (specs/mysql.feature), so its generator makes none.
def float_kinds(adapter: Adapter) -> Gens.FloatKinds
  case adapter
    Adapter.Sqlite -> Gens.FloatKinds(nan: true, infinite: true, negative_zero: true)
    Adapter.Postgres -> Gens.FloatKinds(nan: true, infinite: true, negative_zero: true)
    Adapter.Mysql -> Gens.FloatKinds(nan: false, infinite: false, negative_zero: true)
  end
end

# SQLite stores a NaN as NULL (specs/sqlite.feature) and a -0.0 as the integer 0, which reads back as 0.0: SQLite does
# it itself, and the sqlite3 module of Python shows the same. A MariaDB server gives a -0.0 back as 0.0 too, also in
# its own client (`select -0e0`), while MySQL keeps the sign (agentica-lang/agentica-db#84). Everything else comes back
# as it was written.
def held(adapter: Adapter, unsigned_zero: Bool, cells: List[String]) -> List[String]
  cells.map do |cell| held_cell(adapter, unsigned_zero, cell) end
end

def held_cell(adapter: Adapter, unsigned_zero: Bool, cell: String) -> String
  case cell
    "Float NaN" if adapter == Adapter.Sqlite -> "Null"
    "Float -0.0" if unsigned_zero -> "Float 0.0"
    _ -> cell
  end
end

def mariadb?(conn: Db.Connection, adapter: Adapter) -> Bool
  return false if adapter != Adapter.Mysql

  rows: List[Db.Row] = Db.query(conn, "select version() as v", []).unwrap_or([])
  return false if rows.empty?

  case rows[0].get("v", Db.Value.Null)
    Db.Value.Text(version) -> version.include?("MariaDB")
    _ -> false
  end
end

# The row as the database gives it back, for `Prop.oracle`, which compares the lists as JSON: a failure of the database
# is a one item list that says so. The function closes over the connection.
def through(conn: Db.Connection, columns: List[Column]) -> Fn[List[String], List[String]]
  ->(cells) { stored(conn, columns, cells) }
end

def stored(conn: Db.Connection, columns: List[Column], cells: List[String]) -> List[String]
  case read_back(conn, columns, write_row(conn, columns, cells))
    ok(back) -> back
    error(message) -> ["error: #{message}"]
  end
end

def write_row(conn: Db.Connection, columns: List[Column], cells: List[String]) -> Result[Int]
  try Db.execute(conn, "delete from t", [])
  params = try Cells.parse_all(cells)
  holes = columns.map do |_| "?" end
  marks = holes.join(", ")
  column_names = columns.map do |column| column.name end
  names = column_names.join(", ")
  Db.execute(conn, "insert into t (#{names}) values (#{marks})", params)
end

def read_back(conn: Db.Connection, columns: List[Column], written: Result[Int]) -> Result[List[String]]
  count = try written
  return error("the insert changed #{count} rows, not 1") if count != 1

  names = columns.map do |column| column.name end
  rows = try Db.query(conn, "select #{names.join(", ")} from t", [])
  return error("the table holds #{rows.length} rows, not 1") if rows.length != 1

  ok(names.map do |name| render(rows[0].get(name, Db.Value.Null)) end)
end

def create_sql(columns: List[Column]) -> String
  typed = columns.map do |column| "#{column.name} #{column.type}" end
  definitions = typed.join(", ")
  "create temporary table t (#{definitions})"
end

# A cell as `value_gens.agc` writes it, with no cut for a long text.
def render(value: Db.Value) -> String
  case value
    Db.Value.Null -> "Null"
    Db.Value.Int(n) -> "Int #{n}"
    Db.Value.Float(x) -> Gens.float_text(x)
    Db.Value.Text(text) -> "Text #{text}"
    Db.Value.Blob(bytes) ->
      shown = bytes.to_a.map do |byte| byte.to_s end
      "Blob #{shown.join(",")}"
    Db.Value.Bool(flag) -> "Bool #{flag}"
  end
end
