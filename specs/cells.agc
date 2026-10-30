## The typed cells of the feature tables: a `Value` written as text, read and shown the same way.
##
## A cell is a tag and its text: `Null`, `Int 31`, `Float -0.25` (also `Infinity`, `-Infinity`, `NaN`), `Text ana`,
## `Bool true`, `Blob 0,1,255`, and `Repeat 5000 Blob 7` or `Repeat 40000 Text héllo` for a big value. A text can hold
## the markers `[NUL]`, `[TAB]`, `[LF]`, `[VT]`, `[FF]`, `[CR]` and `[SP]`: a table cell cannot hold those characters,
## and it drops the spaces at its end.

import {Row, Value} from "../value"

SHOW_LIMIT = 60
MARKERS = {
  "[NUL]": 0,
  "[TAB]": 9,
  "[LF]": 10,
  "[VT]": 11,
  "[FF]": 12,
  "[CR]": 13,
  "[SP]": 32,
}

## Replaces the markers of characters in `text` with the characters.
export def expand(text: String) -> String
  return MARKERS.keys.reduce(text) do |acc, marker| acc.replace(marker, String.from_code(MARKERS[marker])) end
end

## Reads a typed cell.
export def parse(cell: String) -> Result[Value]
  case cell.index_of(" ")
    none -> return parse_tagged(cell, "")
    some(at) -> return parse_tagged(cell.slice(0, at), cell.slice(at + 1, cell.length - at - 1))
  end
end

## Reads a list of typed cells.
export def parse_all(cells: List[String]) -> Result[List[Value]]
  values: List[Value] = []
  for cell in cells
    values = values.push(try parse(cell))
  end

  return ok(values)
end

## Writes a value as a cell, cut when it is long.
export def show(value: Value) -> String
  case value
    Value.Null -> return "Null"
    Value.Int(n) -> return "Int #{n}"
    Value.Float(x) -> return "Float #{x}"
    Value.Text(text) -> return cut("Text #{text.inspect}")
    Value.Blob(bytes) -> return cut("Blob #{bytes.to_a.map do |byte| byte.to_s end.join(",")}")
    Value.Bool(flag) -> return "Bool #{flag}"
  end
end

## Writes a row as `column: cell` pairs.
export def show_row(row: Row) -> String
  return row.keys.map do |name| "#{name}: #{show(row[name])}" end.join(", ")
end

## True when two values are the same; a NaN is the same as a NaN.
export def same?(left: Value, right: Value) -> Bool
  if nan?(left) and nan?(right)
    return true
  end

  return Test.eq(left, right).ok?
end

def parse_tagged(tag: String, rest: String) -> Result[Value]
  case tag
    "Null" -> return ok(Value.Null)
    "Int" -> return ok(Value.Int(try rest.to_i))
    "Float" -> return parse_float(rest)
    "Text" -> return ok(Value.Text(expand(rest)))
    "Bool" -> return parse_bool(rest)
    "Blob" -> return parse_blob(rest)
    "Repeat" -> return parse_repeat(rest)
    _ -> return error("unknown cell type in #{tag.inspect}")
  end
end

# Infinity is what a product overflows to; NaN is infinity minus itself.
def parse_float(text: String) -> Result[Value]
  infinity = 1.0
  for _ in 0...60
    infinity = infinity * 1_000_000.0
  end

  case text
    "Infinity" -> return ok(Value.Float(infinity))
    "-Infinity" -> return ok(Value.Float(0.0 - infinity))
    "NaN" -> return ok(Value.Float(infinity - infinity))
    _ -> return ok(Value.Float(try text.to_f))
  end
end

def parse_bool(text: String) -> Result[Value]
  case text
    "true" -> return ok(Value.Bool(true))
    "false" -> return ok(Value.Bool(false))
    _ -> return error("a Bool cell is true or false, not #{text.inspect}")
  end
end

def parse_blob(text: String) -> Result[Value]
  bytes: List[Int] = []
  if not text.empty?
    for item in text.split(",")
      bytes = bytes.push(try item.to_i)
    end
  end

  return ok(Value.Blob(try Bytes.from_list(bytes)))
end

# `Repeat COUNT Text|Blob ...`: the text or the bytes of the inner cell, COUNT times.
def parse_repeat(text: String) -> Result[Value]
  at = try text.index_of(" ").to_result("a Repeat cell needs a count and a cell")
  count = try text.slice(0, at).to_i
  inner = try parse(text.slice(at + 1, text.length - at - 1))
  case inner
    Value.Text(piece) -> return ok(Value.Text(List.repeat(piece, count).join("")))
    Value.Blob(bytes) -> return ok(Value.Blob(Bytes.concat(List.repeat(bytes, count))))
    _ -> return error("only a Text or a Blob cell can repeat")
  end
end

def nan?(value: Value) -> Bool
  case value
    Value.Float(x) -> return x != x
    _ -> return false
  end
end

def cut(text: String) -> String
  if text.length <= SHOW_LIMIT
    return text
  end

  return "#{text.slice(0, SHOW_LIMIT)}... (#{text.length} characters)"
end
