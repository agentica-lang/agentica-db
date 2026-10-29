## Turns a result row into the Json of a struct, so that `JSON.codec` can decode it. The values of a row are the
## types of the database (Int, Float, Text, Bool, Null), and a struct field asks for more: a Bool column of SQLite and
## MySQL comes back as 0 or 1, and a NULL goes into a `JsonField`. Only the fields of the struct are read: a column
## the struct does not have is ignored, and a field with no column is left out of the Json, so a `JsonField` is
## `Absent` and any other field is an error of the decode.

import Db from "../db"

JSON_FIELD = "JsonField["
# The largest Int a Float holds exactly (2^53); a bigger one could round.
MAX_EXACT = 9007199254740992

## The Json object of `row` for the fields `members`. The value of a column goes in as it is whenever no conversion
## applies (a Text for an Int field), so the decode reports the wrong type with the path of the field. A field that is
## not a `JsonField` needs its column, and the column needs a value: `<field>: missing column` and `<field>: NULL ...`.
export def to_json(members: List[StructMember], row: Db.Row) -> Result[Json]
  fields: Map[String, Json] = {}
  for member in members
    if row.key?(member.name)
      fields = fields.put(member.name, try field_json(member, row[member.name]))
    elsif not json_field?(member.type)
      return error("#{member.name}: missing column")
    end
  end

  return ok(JSON.object(fields))
end

## Whether a field of this type can come from one column: Int, Float, Bool or String, alone or in a `JsonField`.
export def column_type?(type: String) -> Bool
  return ["Int", "Float", "Bool", "String"].any? do |name| name == inner_type(type) end
end

def json_field?(type: String) -> Bool
  return type.start_with?(JSON_FIELD) and type.end_with?("]")
end

# `JsonField[Int]` is `Int`: a NULL is the only difference.
def inner_type(type: String) -> String
  if json_field?(type)
    return type.slice(JSON_FIELD.length, type.length - JSON_FIELD.length - 1)
  end

  return type
end

def field_json(member: StructMember, value: Db.Value) -> Result[Json]
  wanted = inner_type(member.type)
  case value
    Db.Value.Int(n) if wanted == "Bool" and (n == 0 or n == 1) -> return ok(JSON.from(n == 1))
    Db.Value.Int(n) if wanted == "Float" -> return exact(member, n)
    Db.Value.Int(n) -> return ok(JSON.from(n))
    Db.Value.Float(x) -> return finite(member, x)
    Db.Value.Text(text) -> return ok(JSON.from(text))
    Db.Value.Bool(flag) -> return ok(JSON.from(flag))
    Db.Value.Blob(bytes) -> return ok(JSON.from(bytes))
    Db.Value.Null if json_field?(member.type) -> return ok(JSON.null())
    Db.Value.Null -> return error("#{member.name}: NULL in a field that is not a JsonField")
  end
end

# An Int goes into a Float field only when the Float holds it exactly.
def exact(member: StructMember, n: Int) -> Result[Json]
  if n > MAX_EXACT or n < 0 - MAX_EXACT
    return error("#{member.name}: #{n} does not fit a Float exactly")
  end

  return ok(JSON.from(n.to_f))
end

# A Json number is finite: PostgreSQL can give NaN and Infinity.
def finite(member: StructMember, x: Float) -> Result[Json]
  if x - x != 0.0
    return error("#{member.name}: not a finite Float")
  end

  return ok(JSON.from(x))
end
