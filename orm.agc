## A small typed layer over `Db`: plain structs in and out, SQL with bound `?` parameters (see `Db`). The reads run
## your sql; the writes (`insert`, `update`, `delete`, `patch`) write theirs from the schema, with quoted names.
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
  names: List[String] = []
  for member in schema.members
    names = names.push(try quoted(conn, schema, member.name))
  end

  table = try quoted(conn, schema, schema.table)
  try Db.query(conn, "select #{names.join(", ")} from #{table} where 1 = 0", [])
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

  return update_by_key(conn, schema, sets, params.push(id))
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
  names: List[String] = []
  for member in schema.members
    names = names.push(try quoted(conn, schema, member.name))
  end

  table = try quoted(conn, schema, schema.table)
  column = try quoted(conn, schema, schema.primary_key)
  rows = try query(conn, schema, "select #{names.join(", ")} from #{table} where #{column} = ?", [key])
  if rows.empty?
    return fail(schema, "the inserted row was not found by its key #{schema.primary_key}")
  end

  return ok(rows[0])
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
