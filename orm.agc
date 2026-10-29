## A small typed layer over `Db`: plain structs in and out, SQL with bound `?` parameters (see `Db`). `query` runs
## your sql; `find`, the writes (`insert`, `update`, `delete`, `patch`) and the query builder (`from`, `where_eq`, ...,
## `all`) write theirs from the schema, with quoted names.
##
## A schema ties a struct to a table: `Orm.schema("users", User.members, JSON.codec(User))`. Every function takes
## the `Db.Connection`, so a transaction body or a pooled connection passes its own. The functions give values and
## never change one. An error is `error("orm error: <table>: <message>")`; an error of the database is the one of
## `Db`.
##
## The mapping: the table is a plain struct, a column has the name of its field (the Orm quotes it), and the key is
## `id` unless `.with(primary_key: "other")`. A generated key is a field with a default, `id: Int = 0`. A column that
## can be NULL is a `JsonField[T]` field: NULL is `Null`, a column the query does not select is `Absent`. The field
## types are Int, Float, Bool and String; a Bool column of SQLite and MySQL (0 or 1) reads as a Bool.

import Build from "orm/build"
import Codec from "orm/codec"
import Db from "db"
import Dialect from "orm/dialect"

## The table of a struct `T`: its name, its fields (`T.members`), the codec that builds a `T`, the key column and
## whether the database generates the key. Make one with `schema`; change an option with `.with(...)`.
export struct Schema[T]
  table: String
  members: List[StructMember]
  codec: JSON.Codec[T]
  primary_key: String = "id"
  generated: Bool = true
end

## Some value, or none.
export enum Option[T]
  Some(T)
  None
end

## A query over a schema, built with `from` and the functions below and run by `all`, `one`, `count`, `update_all` or
## `delete_all`. It holds the conditions, the order and the page, and the first problem found while it was built (a
## column that is not in the schema, a value of another kind): that problem is the error of the call that ends it.
export struct Query[T]
  schema: Schema[T]
  plan: Build.Plan
  failure: String = ""
end

# The `name = ?` pieces of an update and their values.
struct Sets
  sql: List[String]
  params: List[Db.Value]
end

## The schema of `table` for the struct whose `members` and `codec` are given:
## `Orm.schema("users", User.members, JSON.codec(User))`. Nothing is checked here; `check` does.
export def schema[T](table: String, members: List[StructMember], codec: JSON.Codec[T]) -> Schema[T]
  return Schema(table: table, members: members, codec: codec)
end

## Checks the schema and then the table: the names are plain identifiers, every field is a type a column can hold,
## the key is a field, and the table has every column. Run it once at start up. It reads no row. The first three are
## `orm error: <table>: <message>`; a table or a column that is missing is the error of `Db`, unchanged.
export def check[T](conn: Db.Connection, schema: Schema[T]) -> Result[Void]
  try valid(schema)
  columns = try columns_sql(conn, schema)
  table = try quoted(conn, schema, schema.table)
  try Db.query(conn, "select #{columns} from #{table} where 1 = 0", [])
  return ok()
end

## Runs the sql and reads each row into a `T`. The sql is yours, with `?` for the parameters; the columns it names
## are matched with the fields by name.
export def query[T](conn: Db.Connection, schema: Schema[T], sql: String, params: List[Db.Value]) -> Result[List[T]]
  rows = try Db.query(conn, sql, params)
  found: List[T] = []
  for row in rows
    found = found.push(try read(schema, row))
  end

  return ok(found)
end

## Runs the sql and reads each row with `decode`, for a result that is not one struct (a join, a count). The error
## of `decode` is the error of the call.
export def query_as[R](conn: Db.Connection, sql: String, params: List[Db.Value],
                       decode: Fn[Db.Row, Result[R]]) -> Result[List[R]]
  rows = try Db.query(conn, sql, params)
  found: List[R] = []
  for row in rows
    found = found.push(try decode.call(row))
  end

  return ok(found)
end

## The row whose key is `id`: `Option.Some(row)`, or `Option.None` when there is no such row (a 404, not a 500). The
## `id` must be the kind of the key field (`Db.Value.Int` for an Int key), else it is an error.
export def find[T](conn: Db.Connection, schema: Schema[T], id: Db.Value) -> Result[Option[T]]
  try valid(schema)
  try key_kind(schema, id)
  return one(where_eq(from(schema), schema.primary_key, id), conn)
end

## An empty query over the schema: every row, in the order of the database.
export def from[T](schema: Schema[T]) -> Query[T]
  return Query(schema: schema, plan: Build.Plan())
end

## Keeps the rows for which `sql` holds, with `?` for the `params`. The sql is yours (a constant of your program, as
## for `query`): a column of a request must go through `where_eq` or `where_in`, which check it. All the conditions
## must hold.
export def where[T](q: Query[T], sql: String, params: List[Db.Value]) -> Query[T]
  return with_cond(q, Build.Cond.Raw(sql, params))
end

## Keeps the rows whose `column` equals `value`; `Db.Value.Null` keeps the rows where it is NULL. The column must be
## in the schema and the value the kind of the column.
export def where_eq[T](q: Query[T], column: String, value: Db.Value) -> Query[T]
  case member_of(q.schema, column)
    error(message) -> return failed(q, message)
    ok(member) ->
      if not Codec.accepts?(member.type, value)
        return failed(q, wrong_kind("column", member, value))
      end

      return with_cond(q, Build.Cond.Eq(column, value))
  end
end

## Keeps the rows whose `column` is one of `values`; no value keeps no row. The same checks as `where_eq`.
export def where_in[T](q: Query[T], column: String, values: List[Db.Value]) -> Query[T]
  case member_of(q.schema, column)
    error(message) -> return failed(q, message)
    ok(member) ->
      for value in values
        if not Codec.accepts?(member.type, value)
          return failed(q, wrong_kind("column", member, value))
        end
      end

      return with_cond(q, Build.Cond.In(column, values))
  end
end

## Orders by `column`, after the columns already given. The column must be in the schema.
export def order_by[T](q: Query[T], column: String) -> Query[T]
  return ordered(q, column, false)
end

## Orders by `column`, largest first.
export def order_by_desc[T](q: Query[T], column: String) -> Query[T]
  return ordered(q, column, true)
end

## Keeps the first `count` rows of the order. A negative count is an error.
export def limit[T](q: Query[T], count: Int) -> Query[T]
  if count < 0
    return failed(q, "limit must not be negative")
  end

  return q.with(plan: q.plan.with(limit: count))
end

## Skips the first `count` rows of the order. A negative count is an error.
export def offset[T](q: Query[T], count: Int) -> Query[T]
  if count < 0
    return failed(q, "offset must not be negative")
  end

  return q.with(plan: q.plan.with(offset: count))
end

## The rows of the query, each read into a `T`. Without `order_by` the order is the one of the database.
export def all[T](q: Query[T], conn: Db.Connection) -> Result[List[T]]
  try ready(q)
  columns = try columns_sql(conn, q.schema)
  table = try quoted(conn, q.schema, q.schema.table)
  where_part = try builder(Build.where_piece(conn, q.plan), q.schema)
  tail = try builder(Build.tail_piece(conn, q.plan), q.schema)
  sql = "select #{columns} from #{table}#{where_part.sql}#{tail.sql}"
  return query(conn, q.schema, sql, where_part.params.concat(tail.params))
end

## The first row of the query: `Option.Some(row)`, or `Option.None` when no row is kept.
export def one[T](q: Query[T], conn: Db.Connection) -> Result[Option[T]]
  rows = try all(q.with(plan: q.plan.with(limit: 1)), conn)
  if rows.empty?
    return ok(Option.None)
  end

  return ok(Option.Some(rows[0]))
end

## The number of rows the conditions keep; the order, the limit and the offset do not count.
export def count[T](q: Query[T], conn: Db.Connection) -> Result[Int]
  try ready(q)
  table = try quoted(conn, q.schema, q.schema.table)
  where_part = try builder(Build.where_piece(conn, q.plan), q.schema)
  rows = try Db.query(conn, "select count(*) as n from #{table}#{where_part.sql}", where_part.params)
  case rows[0]["n"]
    Db.Value.Int(n) -> return ok(n)
    _ -> return fail(q.schema, "the database gave no count")
  end
end

## Sets the columns of `changes` (a `Json` object, as for `patch`) in every row the conditions keep, and gives the rows
## changed. Without a condition it is every row. The order, the limit and the offset are errors here.
export def update_all[T](q: Query[T], conn: Db.Connection, changes: Json) -> Result[Int]
  try ready(q)
  try unpaged(q, "update_all")
  sets = try change_sets(conn, q.schema, changes)
  table = try quoted(conn, q.schema, q.schema.table)
  where_part = try builder(Build.where_piece(conn, q.plan), q.schema)
  sql = "update #{table} set #{sets.sql.join(", ")}#{where_part.sql}"
  return Db.execute(conn, sql, sets.params.concat(where_part.params))
end

## Deletes every row the conditions keep and gives the rows removed. Without a condition it is every row. The order,
## the limit and the offset are errors here.
export def delete_all[T](q: Query[T], conn: Db.Connection) -> Result[Int]
  try ready(q)
  try unpaged(q, "delete_all")
  table = try quoted(conn, q.schema, q.schema.table)
  where_part = try builder(Build.where_piece(conn, q.plan), q.schema)
  return Db.execute(conn, "delete from #{table}#{where_part.sql}", where_part.params)
end

## Inserts the row of `value` and gives it back as the database stored it. A generated key is left out of the insert
## (whatever the value holds), and so is a `JsonField` that is `Absent`: the default of the database applies. The
## row comes back with the real key, read again by it, so the two statements should share a transaction when other
## writers matter. A non-finite Float in the value halts at the encode of the codec (`RUNTIME-JSON-ENCODE`).
export def insert[T](conn: Db.Connection, schema: Schema[T], value: T) -> Result[T]
  try valid(schema)
  object = schema.codec.from(value)
  names: List[String] = []
  params: List[Db.Value] = []
  key = Db.Value.Null
  for member in schema.members
    found = JSON.get(object, member.name)
    if found.ok? and not (schema.generated and member.name == schema.primary_key)
      names = names.push(try quoted(conn, schema, member.name))
      params = params.push(try bound(schema, member, found.unwrap!))
      if member.name == schema.primary_key
        key = params.last
      end
    end
  end

  if names.empty?
    return fail(schema, "no column to insert")
  end

  table = try quoted(conn, schema, schema.table)
  marks = params.map do |param| "?" end.join(", ")
  sql = "insert into #{table} (#{names.join(", ")}) values (#{marks})"
  if schema.generated
    id = try generated_key(conn, schema, sql, params)
    return reload(conn, schema, Db.Value.Int(id))
  end

  try Db.execute(conn, sql, params)
  return reload(conn, schema, key)
end

## Sets every column of the row whose key is the key of `value` and gives the rows changed, 0 when there is no such
## row. A `JsonField` that is `Absent` keeps its column; `Null` clears it. A value with no field but the key and
## `Absent` ones has nothing to set: `no column to update`.
export def update[T](conn: Db.Connection, schema: Schema[T], value: T) -> Result[Int]
  try valid(schema)
  object = schema.codec.from(value)
  sets: List[String] = []
  params: List[Db.Value] = []
  key = Db.Value.Null
  for member in schema.members
    found = JSON.get(object, member.name)
    if member.name == schema.primary_key
      key = try bound(schema, member, try or_fail(schema, found, "the value has no key"))
    elsif found.ok?
      sets = sets.push("#{try quoted(conn, schema, member.name)} = ?")
      params = params.push(try bound(schema, member, found.unwrap!))
    end
  end

  if sets.empty?
    return fail(schema, "no column to update")
  end

  return update_by_key(conn, schema, sets, params.push(key))
end

## Deletes the row whose key is `id` and gives the rows removed, 0 when there is no such row. The `id` must be the
## kind of the key field (`Db.Value.Int` for an Int key), else it is an error.
export def delete[T](conn: Db.Connection, schema: Schema[T], id: Db.Value) -> Result[Int]
  try valid(schema)
  try key_kind(schema, id)
  table = try quoted(conn, schema, schema.table)
  key = try quoted(conn, schema, schema.primary_key)
  return Db.execute(conn, "delete from #{table} where #{key} = ?", [id])
end

## Changes the columns for the keys that `changes` has, in the row whose key is `id`, and gives the rows changed (0
## when there is no such row). A key that is a column of the schema is set to its value, `null` clears a `JsonField`
## column, and a column the object leaves out keeps its value. The values are checked as the fields are: the kind of
## the field, and an Int into a Float only when exact. A key that is not a column, or the primary key, is an error, so
## the body of a request can be passed as it is.
export def patch[T](conn: Db.Connection, schema: Schema[T], id: Db.Value, changes: Json) -> Result[Int]
  try valid(schema)
  try key_kind(schema, id)
  sets = try change_sets(conn, schema, changes)
  return update_by_key(conn, schema, sets.sql, sets.params.push(id))
end

# The name in quotes; a name that is not a plain identifier is an error of the Orm.
def quoted[T](conn: Db.Connection, schema: Schema[T], name: String) -> Result[String]
  case Dialect.quote(conn, name)
    ok(text) -> return ok(text)
    error(message) -> return fail(schema, message)
  end
end

# The key the insert generated. The error of the database is returned as it is; no key at all is an error of the Orm.
def generated_key[T](conn: Db.Connection, schema: Schema[T], sql: String, params: List[Db.Value]) -> Result[Int]
  column = try quoted(conn, schema, schema.primary_key)
  case Dialect.insert_generated(conn, sql, params, column)
    ok(id) -> return ok(id)
    error(message) if message == Dialect.NO_KEY -> return fail(schema, message)
    error(message) -> return error(message)
  end
end

# The key given to `delete` and `patch` must be the kind of the key field, so a wrong key is an error of the Orm and
# not a quiet no-match (or a conversion by the database).
def key_kind[T](schema: Schema[T], id: Db.Value) -> Result[Void]
  keys = schema.members.select do |member| member.name == schema.primary_key end
  if Codec.field_kind(keys[0].type) != Codec.value_kind(id)
    return fail(schema, "the key #{schema.primary_key} has type #{keys[0].type}, not #{Codec.value_kind(id)}")
  end

  return ok()
end

def bound[T](schema: Schema[T], member: StructMember, json: Json) -> Result[Db.Value]
  case Codec.to_value(member, json)
    ok(value) -> return ok(value)
    error(message) -> return fail(schema, message)
  end
end

def or_fail[T](schema: Schema[T], found: Result[Json], message: String) -> Result[Json]
  case found
    ok(json) -> return ok(json)
    error(_) -> return fail(schema, message)
  end
end

# The text of a Json value. It relies on `JSON.encode` writing the keys of a parsed object in sorted order (and the
# parse of the encode gives a parsed object), so two objects with the same entries have the same text, whatever order
# their keys came in.
def canonical(json: Json) -> Result[String]
  return ok(JSON.encode(try JSON.parse(JSON.encode(json))))
end

# Runs `update` with the `sets` (`"name = ?"`) over the row whose key is the last of the params.
def update_by_key[T](conn: Db.Connection, schema: Schema[T], sets: List[String], params: List[Db.Value]) -> Result[Int]
  table = try quoted(conn, schema, schema.table)
  column = try quoted(conn, schema, schema.primary_key)
  return Db.execute(conn, "update #{table} set #{sets.join(", ")} where #{column} = ?", params)
end

# The row of the key, read again with all the columns of the schema.
def reload[T](conn: Db.Connection, schema: Schema[T], key: Db.Value) -> Result[T]
  case try find(conn, schema, key)
    Option.Some(row) -> return ok(row)
    Option.None -> return fail(schema, "the inserted row was not found by its key #{schema.primary_key}")
  end
end

# The quoted names of all the columns of the schema, apart by commas.
def columns_sql[T](conn: Db.Connection, schema: Schema[T]) -> Result[String]
  names: List[String] = []
  for member in schema.members
    names = names.push(try quoted(conn, schema, member.name))
  end

  return ok(names.join(", "))
end

def with_cond[T](q: Query[T], cond: Build.Cond) -> Query[T]
  return q.with(plan: q.plan.with(conds: q.plan.conds.push(cond)))
end

def ordered[T](q: Query[T], column: String, desc: Bool) -> Query[T]
  case member_of(q.schema, column)
    error(message) -> return failed(q, message)
    ok(_) -> return q.with(plan: q.plan.with(orders: q.plan.orders.push(Build.Order(column: column, desc: desc))))
  end
end

# The query with the first problem it met: later ones do not replace it.
def failed[T](q: Query[T], message: String) -> Query[T]
  if q.failure.empty?
    return q.with(failure: message)
  end

  return q
end

def member_of[T](schema: Schema[T], column: String) -> Result[StructMember]
  found = schema.members.select do |member| member.name == column end
  if found.empty?
    return error("#{column} is not a column of the table")
  end

  return ok(found[0])
end

def wrong_kind(what: String, member: StructMember, value: Db.Value) -> String
  return "the #{what} #{member.name} has type #{member.type}, not #{Codec.value_kind(value)}"
end

# What every end of a query checks first: the problem met while it was built, and the schema.
def ready[T](q: Query[T]) -> Result[Void]
  if not q.failure.empty?
    return fail(q.schema, q.failure)
  end

  return valid(q.schema)
end

# A write over a set of rows is one statement with no order or page (a delete with a limit is not portable).
def unpaged[T](q: Query[T], what: String) -> Result[Void]
  if Build.paged?(q.plan)
    return fail(q.schema, "#{what} cannot use order_by, limit or offset")
  end

  return ok()
end

# The sql of the builder is made of names the schema vouched for, but `Dialect.quote` still refuses a bad one.
def builder[T](found: Result[Build.Piece], schema: Schema[T]) -> Result[Build.Piece]
  case found
    ok(piece) -> return ok(piece)
    error(message) -> return fail(schema, message)
  end
end

# The `name = ?` pieces for the keys of `changes` (a Json object): the columns of the schema, not the key, with values
# of the kind of the field.
def change_sets[T](conn: Db.Connection, schema: Schema[T], changes: Json) -> Result[Sets]
  if JSON.kind(changes) != "object"
    return fail(schema, "the changes are not a JSON object")
  end

  sets: List[String] = []
  params: List[Db.Value] = []
  known: Map[String, Json] = {}
  for member in schema.members
    found = JSON.get(changes, member.name)
    if found.ok? and member.name == schema.primary_key
      return fail(schema, "the primary key #{schema.primary_key} cannot be changed")
    elsif found.ok?
      known = known.put(member.name, found.unwrap!)
      sets = sets.push("#{try quoted(conn, schema, member.name)} = ?")
      params = params.push(try bound(schema, member, found.unwrap!))
    end
  end

  # Json has no list of keys: an object with only the known keys is the same object when no key was unknown.
  if (try canonical(JSON.object(known))) != (try canonical(changes))
    return fail(schema, "the changes have a key that is not a column")
  end

  if sets.empty?
    return fail(schema, "no column to change")
  end

  return ok(Sets(sql: sets, params: params))
end

def read[T](schema: Schema[T], row: Db.Row) -> Result[T]
  json = Codec.to_json(schema.members, row)
  case json
    error(message) -> return fail(schema, message)
    ok(object) ->
      case schema.codec.decode(object)
        ok(value) -> return ok(value)
        error(message) -> return fail(schema, message)
      end
  end
end

def valid[T](schema: Schema[T]) -> Result[Void]
  if not Dialect.valid_name?(schema.table)
    return fail(schema, "the table name is not a plain identifier")
  end

  for member in schema.members
    if not Dialect.valid_name?(member.name)
      return fail(schema, "the column name #{member.name.inspect} is not a plain identifier")
    end

    if not Codec.column_type?(member.type)
      return fail(schema, "the field #{member.name} has the type #{member.type}, which a column cannot hold")
    end
  end

  keys = schema.members.select do |member| member.name == schema.primary_key end
  if keys.empty?
    return fail(schema, "the primary key #{schema.primary_key} is not a column")
  end

  if schema.generated and keys[0].type != "Int"
    return fail(schema, "the generated key #{schema.primary_key} must be an Int")
  end

  return ok()
end

def fail[T, R](schema: Schema[T], message: String) -> Result[R]
  return error("orm error: #{schema.table}: #{message}")
end
