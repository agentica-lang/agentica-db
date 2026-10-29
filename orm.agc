## A small typed layer over `Db`: plain structs in and out, SQL with bound `?` parameters (see `Db`).
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
## the key is a field, and the table has every column. Run it once at start up. It reads no row.
export def check[T](conn: Db.Connection, schema: Schema[T]) -> Result[Void]
  try valid(schema)
  names = schema.members.map do |member| Dialect.quote(conn, member.name) end
  sql = "select #{names.join(", ")} from #{Dialect.quote(conn, schema.table)} where 1 = 0"
  case Db.query(conn, sql, [])
    ok(_) -> return ok()
    error(message) -> return fail(schema, message)
  end
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

  if not schema.members.any? do |member| member.name == schema.primary_key end
    return fail(schema, "the primary key #{schema.primary_key} is not a column")
  end

  return ok()
end

def fail[T, R](schema: Schema[T], message: String) -> Result[R]
  return error("orm error: #{schema.table}: #{message}")
end
