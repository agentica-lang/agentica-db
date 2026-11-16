## Takes the parameters of the adapter out of a PostgreSQL url or conninfo string before libpq sees it, since libpq
## refuses a parameter it does not know: `timeout_ms`, and for the native driver `statement_cache` (statements, at most
## 10000, 0 for none), `batch_rows` (1 to 1000) and `batch_bytes` (1 to 262144).
##
## `postgres://user@host/app?sslmode=disable&timeout_ms=2000` and `host=localhost dbname=app timeout_ms=2000` (the
## value may be quoted, as in libpq) give the milliseconds and the text without the parameter. Every other parameter is
## left as it is, for libpq to read. A text that is not a conninfo string (a key without `=`) is given back whole with
## no timeout: libpq reports it. An error is `postgres error: <message>` and never repeats a part of the url.

import Milliseconds from "../support/milliseconds"

## What libpq is given, the limit of each statement (0: none), the prepared statements that the native driver keeps
## per connection, and what one call of it gives at most: `batch_rows` rows or about `batch_bytes` bytes of values (a
## longer result takes more calls). The FFI driver has no cache and reads the whole result at once.
struct Target
  conninfo: String
  timeout_ms: Int = 0
  statement_cache: Int = 100
  batch_rows: Int = 100
  batch_bytes: Int = 262_144
end

## Reads a url or a conninfo string.
def parse(text: String) -> Result[Target]
  return strip_url(text) if URL_PREFIXES.any? do |prefix| text.start_with?(prefix) end

  strip_conninfo(text)
end

private

URL_PREFIXES = ["postgres://", "postgresql://"]
PARAMETER = "timeout_ms"
PARAMETERS = Set.new([PARAMETER, "statement_cache", "batch_rows", "batch_bytes"])
BLANKS = Set.new([" ", "\t", "\n", "\r"])
MAX_STATEMENT_CACHE = 10_000
# The most that one short call of the native driver turns into values (QUICK_ROWS and QUICK_BYTES of the module): a
# bigger batch would hold the scheduler longer.
MAX_BATCH_ROWS = 1_000
MAX_BATCH_BYTES = 262_144
# At most nine digits, far from the limit of an Int.
MAX_DIGITS = 9
DIGIT_ZERO = 48
DIGIT_NINE = 57

def strip_url(url: String) -> Result[Target]
  found = url.index_of("?")
  case found
    none -> ok(Target(conninfo: url))
    some(at) ->
      base = url.slice(0, at)
      pairs = url.slice(at + 1, url.length - at - 1).split("&")
      target = Target(conninfo: base)
      kept: List[String] = []
      for pair in pairs
        key = pair.split("=")[0]
        if PARAMETERS.include?(key)
          target = try apply(target, key, pair.split("=").drop(1).join("="))
        else
          kept = kept.push(pair)
        end
      end

      return ok(target) if kept.empty?

      ok(target.with(conninfo: "#{base}?#{kept.join("&")}"))
  end
end

# The `key = value` words are told apart as libpq does: a value is quoted with single quotes or ends at a blank, and a
# backslash escapes the next character.
def strip_conninfo(text: String) -> Result[Target]
  chars = text.split("")
  kept: List[String] = []
  target = Target(conninfo: "")
  at = skip_blanks(chars, 0)
  while at < chars.size
    key_to = key_end(chars, at)
    equals = skip_blanks(chars, key_to)
    return ok(Target(conninfo: text)) if equals >= chars.size or chars[equals] != "="

    value_from = skip_blanks(chars, equals + 1)
    value_to = value_end(chars, value_from)
    key = join(chars, at, key_to)
    if PARAMETERS.include?(key)
      target = try apply(target, key, unquote(join(chars, value_from, value_to)))
    else
      kept = kept.push(join(chars, at, value_to))
    end

    at = skip_blanks(chars, value_to)
  end

  ok(target.with(conninfo: kept.join(" ")))
end

def apply(target: Target, key: String, value: String) -> Result[Target]
  if key == PARAMETER
    return ok(target.with(timeout_ms: try read_milliseconds(value)))
  elsif key == "statement_cache"
    return ok(target.with(statement_cache: try read_bounded(value, key, 0, MAX_STATEMENT_CACHE)))
  elsif key == "batch_rows"
    return ok(target.with(batch_rows: try read_bounded(value, key, 1, MAX_BATCH_ROWS)))
  end

  ok(target.with(batch_bytes: try read_bounded(value, key, 1, MAX_BATCH_BYTES)))
end

# A whole number of up to MAX_DIGITS digits from `low` to `high`.
def read_bounded(text: String, name: String, low: Int, high: Int) -> Result[Int]
  bytes = text.bytes.to_a
  not_digits = bytes.any? do |byte| byte < DIGIT_ZERO or byte > DIGIT_NINE end
  if bytes.empty? or bytes.size > MAX_DIGITS or not_digits
    return error("postgres error: the url #{name} is not a whole number")
  end

  n = text.to_i.unwrap_or(0)
  return error("postgres error: the url #{name} is below #{low}: #{n}") if n < low

  return error("postgres error: the url #{name} is over #{high}: #{n}") if n > high

  ok(n)
end

def join(chars: List[String], from: Int, to: Int) -> String = chars.drop(from).take(to - from).join("")

def skip_blanks(chars: List[String], from: Int) -> Int
  at = from
  while at < chars.size and BLANKS.include?(chars[at])
    at += 1
  end

  at
end

def key_end(chars: List[String], from: Int) -> Int
  at = from
  while at < chars.size and chars[at] != "=" and not BLANKS.include?(chars[at])
    at += 1
  end

  at
end

# The index after the value that starts at `from`.
def value_end(chars: List[String], from: Int) -> Int
  at = from
  quoted = at < chars.size and chars[at] == "'"
  if quoted
    at += 1
  end

  while at < chars.size
    if chars[at] == "\\"
      at += 2
    elsif quoted and chars[at] == "'"
      return at + 1
    elsif not quoted and BLANKS.include?(chars[at])
      return at
    else
      at += 1
    end
  end

  chars.size
end

def unquote(value: String) -> String
  return value.slice(1, value.length - 2) if value.length >= 2 and value.start_with?("'") and value.end_with?("'")

  value
end

# An `@` or a `/` in the value means that the `?` was meant as a character of the user or the password.
def read_milliseconds(text: String) -> Result[Int]
  case Milliseconds.parse(text)
    some(n) -> ok(n)
    none ->
      if text.include?("@") or text.include?("/")
        return error(
          "postgres error: the url timeout_ms is not a number of milliseconds, write a ? of the password as %3F",
        )
      end

      error("postgres error: the url #{PARAMETER} is not a number of milliseconds")
  end
end
