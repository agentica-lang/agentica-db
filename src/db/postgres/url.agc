## Takes `timeout_ms` out of a PostgreSQL url or conninfo string before libpq sees it, since libpq refuses a
## parameter it does not know.
##
## `postgres://user@host/app?sslmode=disable&timeout_ms=2000` and `host=localhost dbname=app timeout_ms=2000` (the
## value may be quoted, as in libpq) give the milliseconds and the text without the parameter. Every other parameter is
## left as it is, for libpq to read. A text that is not a conninfo string (a key without `=`) is given back whole with
## no timeout: libpq reports it. An error is `postgres error: <message>` and never repeats a part of the url.

import Milliseconds from "../support/milliseconds"

URL_PREFIXES = ["postgres://", "postgresql://"]
PARAMETER = "timeout_ms"
BLANKS = Set.new([" ", "\t", "\n", "\r"])

## What libpq is given, and the limit of each statement (0: none).
export struct Target
  conninfo: String
  timeout_ms: Int = 0
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
      timeout = 0
      kept: List[String] = []
      for pair in pairs
        if pair.split("=")[0] == PARAMETER
          timeout = try read_milliseconds(pair.split("=").drop(1).join("="))
        else
          kept = kept.push(pair)
        end
      end

      if kept.empty?
        return ok(Target(conninfo: base, timeout_ms: timeout))
      end

      return ok(Target(conninfo: "#{base}?#{kept.join("&")}", timeout_ms: timeout))
  end
end

# The `key = value` words are told apart as libpq does: a value is quoted with single quotes or ends at a blank, and a
# backslash escapes the next character.
def strip_conninfo(text: String) -> Result[Target]
  chars = text.split("")
  kept: List[String] = []
  timeout = 0
  at = skip_blanks(chars, 0)
  while at < chars.size
    key_to = key_end(chars, at)
    equals = skip_blanks(chars, key_to)
    if equals >= chars.size or chars[equals] != "="
      return ok(Target(conninfo: text))
    end

    value_from = skip_blanks(chars, equals + 1)
    value_to = value_end(chars, value_from)
    if join(chars, at, key_to) == PARAMETER
      timeout = try read_milliseconds(unquote(join(chars, value_from, value_to)))
    else
      kept = kept.push(join(chars, at, value_to))
    end

    at = skip_blanks(chars, value_to)
  end

  return ok(Target(conninfo: kept.join(" "), timeout_ms: timeout))
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
