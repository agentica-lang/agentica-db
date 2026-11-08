## Generators of the values that cross the database boundary, as the typed cells of the feature tables (`Int 31`,
## `Float -0.25`, `Text ana`, `Blob 0,1,255`, `Null`): a counterexample is JSON, and a failing row can be pasted into a
## scenario. Every cell is canonical, so that the cell a driver reads back is the same text as the one written.

import Prop from "pkg/prop/prop"

MAX_FLOAT = 1.7976931348623157e308
# The edge values of an Int, which a pick of the generator takes in half of the cases, so that the limits come up in
# every run; the other half is any Int.
INT_EDGES = [
  0,
  1,
  -1,
  127,
  -128,
  32_767,
  -32_768,
  2_147_483_647,
  -2_147_483_648,
  4_294_967_296,
  9_007_199_254_740_992,
  9_007_199_254_740_993,
  -9_007_199_254_740_993,
  9_223_372_036_854_775_807,
  -9_223_372_036_854_775_807,
  -9_223_372_036_854_775_808,
]
FINITE_FLOAT_EDGES = [
  "0.0",
  "-0.0",
  "0.1",
  "-0.25",
  "1.0",
  "5e-324",
  "2.2250738585072014e-308",
  "1.7976931348623157e308",
  "-1.7976931348623157e308",
  "9007199254740992.0",
  "1e22",
  "123456789.123456789",
]
# Pieces of text that break a careless driver: the empty one, quotes, placeholders, separators, a backslash, a newline,
# characters of 2, 3 and 4 UTF-8 bytes (the last is outside the BMP) and a combining mark.
TEXT_PIECES = ["", " ", "a", "'", "\"", "?", "$1", ";", "--", "%", "\\", "\n", "\t", "é", "日本", "✓", "🚀", "é"]
SURROGATE_COUNT = 2_048
FIRST_SURROGATE = 55_296
LAST_CODE_POINT = 1_114_111
MAX_TEXT_PIECES = 4
MAX_BLOB_BYTES = 12
MAX_DECIMAL_DIGITS = 18

## Which special floats a generator may make: false for a database that cannot hold them.
export struct FloatKinds
  nan: Bool
  infinite: Bool
  negative_zero: Bool
end

## A cell of a bigint column, or `Null`.
export def int_cell() -> Prop.Gen[String]
  return nullable(int_gen())
end

## A cell of a double column, or `Null`.
export def float_cell(kinds: FloatKinds) -> Prop.Gen[String]
  return nullable(float_gen(kinds))
end

## A cell of a text column, or `Null`.
export def text_cell() -> Prop.Gen[String]
  return nullable(text_gen())
end

## A cell of a blob column, or `Null`.
export def blob_cell() -> Prop.Gen[String]
  return nullable(blob_gen())
end

## A cell of a numeric(20, 4) or decimal(20, 4) column, as text with four decimals, or `Null`.
export def decimal_cell() -> Prop.Gen[String]
  return nullable(decimal_gen())
end

## A cell of a date column (years 1000 to 9999, the range that MySQL and PostgreSQL share), or `Null`.
export def date_cell() -> Prop.Gen[String]
  return nullable(Prop.map(year_month_day()) do |text| "Text #{text}" end)
end

## A cell of a timestamp or datetime column (whole seconds), or `Null`.
export def timestamp_cell() -> Prop.Gen[String]
  return nullable(
    Prop.map(Prop.pair(year_month_day(), time_of_day())) do |pair| "Text #{pair.first} #{pair.second}" end,
  )
end

## A cell of a time column, or `Null`.
export def time_cell() -> Prop.Gen[String]
  return nullable(Prop.map(time_of_day()) do |text| "Text #{text}" end)
end

## The cell of a Float, with the spellings of the special values that a cell takes.
export def float_text(x: Float) -> String
  if x != x
    return "Float NaN"
  end

  if x > MAX_FLOAT
    return "Float Infinity"
  end

  if x < 0.0 - MAX_FLOAT
    return "Float -Infinity"
  end

  return "Float #{x}"
end

# A cell, or `Null` (the shrunk case).
def nullable(gen: Prop.Gen[String]) -> Prop.Gen[String]
  return Prop.map(Prop.optional(gen)) do |cell| cell.unwrap_or("Null") end
end

def int_gen() -> Prop.Gen[String]
  picks = Prop.pair(Prop.int(0, 2 * INT_EDGES.length), Prop.int(-9_223_372_036_854_775_808, 9_223_372_036_854_775_807))
  return Prop.map(picks) do |pair| "Int #{int_pick(pair.first, pair.second)}" end
end

def int_pick(pick: Int, free: Int) -> Int
  if pick < INT_EDGES.length
    return INT_EDGES[pick]
  end

  return free
end

def float_gen(kinds: FloatKinds) -> Prop.Gen[String]
  edges = float_edges(kinds)
  picks = Prop.pair(Prop.int(0, 2 * edges.length), Prop.pair(Prop.float(-1.0, 1.0), Prop.int(-300, 300)))
  return Prop.map(picks) do |pair| float_pick(edges, pair.first, pair.second.first, pair.second.second) end
end

# The edge cells, as the canonical text of the Float they read as.
def float_edges(kinds: FloatKinds) -> List[String]
  finite = FINITE_FLOAT_EDGES.select do |text| kinds.negative_zero or text != "-0.0" end
  cells = finite.map do |text| float_text(text.to_f!) end
  if kinds.infinite
    cells = cells.push("Float Infinity").push("Float -Infinity")
  end

  if kinds.nan
    cells = cells.push("Float NaN")
  end

  return cells
end

def float_pick(edges: List[String], pick: Int, mantissa: Float, exponent: Int) -> String
  if pick < edges.length
    return edges[pick]
  end

  return float_text(scaled(mantissa, exponent))
end

# The mantissa times ten to the exponent, for any exponent in -300..300 (Agentica has no power for a Float).
def scaled(mantissa: Float, exponent: Int) -> Float
  factor = 1.0
  for _ in 0...exponent.abs
    factor = factor * 10.0
  end

  if exponent < 0
    return mantissa / factor
  end

  return mantissa * factor
end

def text_gen() -> Prop.Gen[String]
  return Prop.map(Prop.list(piece_gen(), MAX_TEXT_PIECES)) do |pieces| "Text #{pieces.join("")}" end
end

# One of the pieces above in half of the cases, else any code point, which skips the NUL and the surrogates (no text
# holds them). A shrunk text is made of the first piece, the empty one.
def piece_gen() -> Prop.Gen[String]
  picks = Prop.pair(Prop.int(0, 2 * TEXT_PIECES.length), Prop.int(1, LAST_CODE_POINT - SURROGATE_COUNT))
  return Prop.map(picks) do |pair| piece_of(pair.first, pair.second) end
end

def piece_of(pick: Int, free: Int) -> String
  if pick < TEXT_PIECES.length
    return TEXT_PIECES[pick]
  end

  code = free
  if code >= FIRST_SURROGATE
    code = code + SURROGATE_COUNT
  end

  return String.from_code(code)
end

# Bytes with a pick below 0 standing for the byte 0, so that zero bytes are common.
def blob_gen() -> Prop.Gen[String]
  return Prop.map(Prop.list(Prop.int(-20, 255), MAX_BLOB_BYTES)) do |picks|
    "Blob #{picks.map do |pick| pick.clamp(0, 255).to_s end.join(",")}"
  end
end

def decimal_gen() -> Prop.Gen[String]
  limit = 10.pow(MAX_DECIMAL_DIGITS) - 1
  return Prop.map(Prop.int(0 - limit, limit)) do |units| "Text #{decimal_text(units)}" end
end

# Four decimals, and no sign on a zero (a database may keep "-0.0000" or drop it).
def decimal_text(units: Int) -> String
  digits = pad(units.abs.to_s, 5)
  whole = digits.slice(0, digits.length - 4)
  fraction = digits.slice(digits.length - 4, 4)
  sign = ""
  if units < 0
    sign = "-"
  end

  return "#{sign}#{whole}.#{fraction}"
end

def year_month_day() -> Prop.Gen[String]
  parts = Prop.pair(Prop.int(1000, 9999), Prop.pair(Prop.int(1, 12), Prop.int(1, 28)))
  return Prop.map(parts) do |pair|
    "#{pair.first}-#{pad(pair.second.first.to_s, 2)}-#{pad(pair.second.second.to_s, 2)}"
  end
end

def time_of_day() -> Prop.Gen[String]
  parts = Prop.pair(Prop.int(0, 23), Prop.pair(Prop.int(0, 59), Prop.int(0, 59)))
  return Prop.map(parts) do |pair|
    "#{pad(pair.first.to_s, 2)}:#{pad(pair.second.first.to_s, 2)}:#{pad(pair.second.second.to_s, 2)}"
  end
end

def pad(digits: String, width: Int) -> String
  if digits.length >= width
    return digits
  end

  return "0" * (width - digits.length) + digits
end
