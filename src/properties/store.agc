## A row through a database: the cells of `value_gens.agc` written with bound parameters and read back, against the
## cells that the database promises to give back (`held`, the cells themselves but for what SQLite does to a NaN and
## a negative zero). The table of an adapter has the types that the adapter has; a type with no `Value` variant
## (decimal, date, time) is written and read as text. CI runs it once per driver, and both give the same model, so
## the drivers agree.

import Db from "pkg/db/db"
import Cells from "pkg/db/specs/cells"
import Prop from "pkg/prop/prop"
import Gens from "value_gens"

## The databases a property runs on.
export enum Adapter
  Sqlite
  Postgres
  Mysql
end

struct Column
  name: String
  type: String
end

## Writes generated rows to a database of `adapter` and reads them back, `runs` times, and checks that each row reads
## back as `held` says (`Prop.oracle`: a failure names the shrunk row and the seed). PostgreSQL and MySQL need their
## url variable.
export def reads_back(adapter: Adapter, runs: Int) -> Result[Void]
  conn = try connect(adapter)
  columns = columns_of(adapter)
  made = Db.execute(conn, create_sql(columns), [])
  if not made.ok?
    Db.close(conn)
    return error(made.message)
  end

  checked = Prop.oracle(row_gen(adapter), through(conn, columns), Prop.Config(runs: runs)) do |cells|
    held(adapter, cells)
  end

  Db.close(conn)
  return checked
end

## The generator of a row of the table of `adapter`: a list of cells, one for each column.
export def row_gen(adapter: Adapter) -> Prop.Gen[List[String]]
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

  return Prop.map(Prop.pair(core, temporal)) do |pair|
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

def connect(adapter: Adapter) -> Result[Db.Connection]
  case adapter
    Adapter.Sqlite -> return Db.open("sqlite::memory:")
    Adapter.Postgres -> return Db.open(try System.env("AGENTICA_DB_POSTGRES_URL"))
    Adapter.Mysql -> return Db.open(try System.env("AGENTICA_DB_MYSQL_URL"))
  end
end

def columns_of(adapter: Adapter) -> List[Column]
  core = [Column(name: "i", type: "bigint"), Column(name: "f", type: "double precision")]
  case adapter
    Adapter.Sqlite -> return core.concat([Column(name: "s", type: "text"), Column(name: "b", type: "blob")])
    Adapter.Postgres ->
      return core.concat([
        Column(name: "s", type: "text"),
        Column(name: "b", type: "bytea"),
        Column(name: "n", type: "numeric(20, 4)"),
        Column(name: "d", type: "date"),
        Column(name: "ts", type: "timestamp"),
        Column(name: "tm", type: "time"),
      ])
    Adapter.Mysql ->
      return core.concat([
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
# CI showed a -0.0 reading back as 0.0 on MySQL 8.4 and MariaDB 11 (PostgreSQL keeps it, and SQLite does it on purpose,
# see `held`). Whether the server or the FFI driver does it is open (agentica-lang/agentica-db#84), so a negative zero
# is left out of the MySQL generator until that issue says.
def float_kinds(adapter: Adapter) -> Gens.FloatKinds
  case adapter
    Adapter.Sqlite -> return Gens.FloatKinds(nan: true, infinite: true, negative_zero: true)
    Adapter.Postgres -> return Gens.FloatKinds(nan: true, infinite: true, negative_zero: true)
    Adapter.Mysql -> return Gens.FloatKinds(nan: false, infinite: false, negative_zero: false)
  end
end

# SQLite stores a NaN as NULL (specs/sqlite.feature) and a -0.0 as the integer 0, which reads back as 0.0: SQLite does
# it itself, and the sqlite3 module of Python shows the same. Everything else comes back as it was written.
def held(adapter: Adapter, cells: List[String]) -> List[String]
  if adapter != Adapter.Sqlite
    return cells
  end

  return cells.map do |cell| sqlite_held(cell) end
end

def sqlite_held(cell: String) -> String
  case cell
    "Float NaN" -> return "Null"
    "Float -0.0" -> return "Float 0.0"
    _ -> return cell
  end
end

# The row as the database gives it back, for `Prop.oracle`, which compares the lists as JSON: a failure of the database
# is a one item list that says so. `as_fn` makes a function value of the block, which closes over the connection (the
# fast function of the law cannot be a block, the last one is).
def through(conn: Db.Connection, columns: List[Column]) -> Fn[List[String], List[String]]
  return as_fn() do |cells| stored(conn, columns, cells) end
end

def as_fn[A, B](f: Fn[A, B]) -> Fn[A, B]
  return f
end

def stored(conn: Db.Connection, columns: List[Column], cells: List[String]) -> List[String]
  case read_back(conn, columns, write_row(conn, columns, cells))
    ok(back) -> return back
    error(message) -> return ["error: #{message}"]
  end
end

def write_row(conn: Db.Connection, columns: List[Column], cells: List[String]) -> Result[Int]
  try Db.execute(conn, "delete from t", [])
  params = try Cells.parse_all(cells)
  marks = columns.map do |_| "?" end.join(", ")
  names = columns.map do |column| column.name end.join(", ")
  return Db.execute(conn, "insert into t (#{names}) values (#{marks})", params)
end

def read_back(conn: Db.Connection, columns: List[Column], written: Result[Int]) -> Result[List[String]]
  count = try written
  if count != 1
    return error("the insert changed #{count} rows, not 1")
  end

  names = columns.map do |column| column.name end
  rows = try Db.query(conn, "select #{names.join(", ")} from t", [])
  if rows.length != 1
    return error("the table holds #{rows.length} rows, not 1")
  end

  return ok(names.map do |name| render(rows[0].get(name, Db.Value.Null)) end)
end

def create_sql(columns: List[Column]) -> String
  definitions = columns.map do |column| "#{column.name} #{column.type}" end.join(", ")
  return "create temporary table t (#{definitions})"
end

# A cell as `value_gens.agc` writes it, with no cut for a long text.
def render(value: Db.Value) -> String
  case value
    Db.Value.Null -> return "Null"
    Db.Value.Int(n) -> return "Int #{n}"
    Db.Value.Float(x) -> return Gens.float_text(x)
    Db.Value.Text(text) -> return "Text #{text}"
    Db.Value.Blob(bytes) -> return "Blob #{bytes.to_a.map do |byte| byte.to_s end.join(",")}"
    Db.Value.Bool(flag) -> return "Bool #{flag}"
  end
end
