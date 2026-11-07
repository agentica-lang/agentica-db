## Takes the parameters of the adapter out of a PostgreSQL url or conninfo string before libpq sees it, since libpq
## refuses a parameter it does not know: `timeout_ms`, and for the native driver `statement_cache` (statements, at most
## 10000, 0 for none), `batch_rows` and `batch_bytes` (at least 1).
##
## `postgres://user@host/app?sslmode=disable&timeout_ms=2000` and `host=localhost dbname=app timeout_ms=2000` (the
## value may be quoted, as in libpq) give the milliseconds and the text without the parameter. Every other parameter is
## left as it is, for libpq to read. A text that is not a conninfo string (a key without `=`) is given back whole with
## no timeout: libpq reports it. An error is `postgres error: <message>` and never repeats a part of the url.

import Milliseconds from "../support/milliseconds"

URL_PREFIXES = ["postgres://", "postgresql://"]
PARAMETER = "timeout_ms"
PARAMETERS = Set.new([PARAMETER, "statement_cache", "batch_rows", "batch_bytes"])
BLANKS = Set.new([" ", "\t", "\n", "\r"])
MAX_STATEMENT_CACHE = 10_000
# At most nine digits, far from the limit of an Int.
MAX_DIGITS = 9
DIGIT_ZERO = 48
DIGIT_NINE = 57

## What libpq is given, the limit of each statement (0: none), the prepared statements that the native driver keeps
## per connection, and what one call of it gives at most: `batch_rows` rows or about `batch_bytes` bytes of values (a
## longer result takes more calls). The FFI driver has no cache and reads the whole result at once.
export struct Target
  conninfo: String
  timeout_ms: Int = 0
  statement_cache: Int = 100
  batch_rows: Int = 100
  batch_bytes: Int = 262_144
end

## Reads a url or a conninfo string.
export def parse(text: String) -> Result[Target]
  if URL_PREFIXES.any? do |prefix| text.start_with?(prefix) end
    return strip_url(text)
  end

  return strip_conninfo(text)
end

def strip_url(url: String) -> Result[Target]
  found = url.index_of("?")
  case found
    none -> return ok(Target(conninfo: url))
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

      if kept.empty?
        return ok(target)
      end

      return ok(target.with(conninfo: "#{base}?#{kept.join("&")}"))
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
    if equals >= chars.size or chars[equals] != "="
      return ok(Target(conninfo: text))
    end

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

  return ok(target.with(conninfo: kept.join(" ")))
end

def apply(target: Target, key: String, value: String) -> Result[Target]
  if key == PARAMETER
    return ok(target.with(timeout_ms: try read_milliseconds(value)))
  elsif key == "statement_cache"
    return ok(target.with(statement_cache: try read_bounded(value, key, 0, MAX_STATEMENT_CACHE)))
  elsif key == "batch_rows"
    return ok(target.with(batch_rows: try read_bounded(value, key, 1, 0)))
  end

  return ok(target.with(batch_bytes: try read_bounded(value, key, 1, 0)))
end

# A whole number of up to MAX_DIGITS digits from `low` to `high` (no bound when `high` is 0).
def read_bounded(text: String, name: String, low: Int, high: Int) -> Result[Int]
  bytes = text.bytes.to_a
  not_digits = bytes.any? do |byte| byte < DIGIT_ZERO or byte > DIGIT_NINE end
  if bytes.empty? or bytes.size > MAX_DIGITS or not_digits
    return error("postgres error: the url #{name} is not a whole number")
  end

  n = text.to_i.unwrap_or(0)
  if n < low
    return error("postgres error: the url #{name} is below #{low}: #{n}")
  end

  if high > 0 and n > high
    return error("postgres error: the url #{name} is over #{high}: #{n}")
  end

  return ok(n)
end

def join(chars: List[String], from: Int, to: Int) -> String
  return chars.drop(from).take(to - from).join("")
end

def skip_blanks(chars: List[String], from: Int) -> Int
  at = from
  while at < chars.size and BLANKS.include?(chars[at])
    at += 1
  end

  return at
end

def key_end(chars: List[String], from: Int) -> Int
  at = from
  while at < chars.size and chars[at] != "=" and not BLANKS.include?(chars[at])
    at += 1
  end

  return at
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

  return chars.size
end

def unquote(value: String) -> String
  if value.length >= 2 and value.start_with?("'") and value.end_with?("'")
    return value.slice(1, value.length - 2)
  end

  return value
end

# An `@` or a `/` in the value means that the `?` was meant as a character of the user or the password.
def read_milliseconds(text: String) -> Result[Int]
  case Milliseconds.parse(text)
    some(n) -> return ok(n)
    none ->
      if text.include?("@") or text.include?("/")
        return error(
          "postgres error: the url timeout_ms is not a number of milliseconds, write a ? of the password as %3F",
        )
      end

      return error("postgres error: the url #{PARAMETER} is not a number of milliseconds")
  end
end
