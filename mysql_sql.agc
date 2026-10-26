## Checks that the sql of the MySQL adapter is one statement, and finds its first word.
##
## MySQL takes `?` natively, so the sql is sent as it is. The scanner only walks it once to see where the
## statement starts and ends, with the lexical rules of MySQL: a string literal (`'..'`, `".."`) escapes with a
## backslash or a doubled quote, a quoted identifier (`` `..` ``) only with a doubled backtick, `-- ` (a space or a
## control character after the two dashes) and `#` comments run to the end of the line, and `/* .. */` comments do
## not nest. A `/*! .. */` or `/*M! .. */` comment is code for the server, so it counts as content.

TAB = 9
NEWLINE = 10
CARRIAGE_RETURN = 13
SPACE = 32
EXCLAMATION = 33
DOUBLE_QUOTE = 34
HASH = 35
SINGLE_QUOTE = 39
STAR = 42
MINUS = 45
SLASH = 47
SEMICOLON = 59
UPPER_A = 65
UPPER_M = 77
UPPER_Z = 90
BACKSLASH = 92
BACKTICK = 96
LOWER_A = 97
LOWER_Z = 122

## The first word of the statement in lower case (`begin`, `start`, `insert`, `select`; empty when the statement
## starts with something else), read after any whitespace and comments.
export struct Statement
  verb: String
end

## Checks the sql. An error is `mysql error: <message>` for a NUL, a second statement, or no statement at all.
export def inspect(sql: String) -> Result[Statement]
  if sql.include?(String.from_code(0))
    return error("mysql error: the sql contains a NUL character")
  end

  bytes = sql.to_bytes
  at = 0
  ended = false
  content = false
  verb = ""
  while at < bytes.size
    byte = bytes[at]
    skipped = comment_end(bytes, at)
    if skipped > at
      at = skipped
    elsif space?(byte)
      at += 1
    elsif byte == SEMICOLON
      ended = true
      at += 1
    else
      # Content after the end of the statement is a second statement.
      if ended
        return error("mysql error: the sql has more than one statement")
      end

      if not content
        content = true
        verb = word_at(bytes, at)
      end

      at = literal_end(bytes, at)
    end
  end

  if not content
    return error("mysql error: the sql has no statement")
  end

  return ok(Statement(verb: verb))
end

def space?(byte: Int) -> Bool
  return byte == SPACE or (byte >= TAB and byte <= CARRIAGE_RETURN)
end

def letter?(byte: Int) -> Bool
  return (byte >= UPPER_A and byte <= UPPER_Z) or (byte >= LOWER_A and byte <= LOWER_Z)
end

def word_at(bytes: List[Int], at: Int) -> String
  stop = at
  while stop < bytes.size and letter?(bytes[stop])
    stop += 1
  end

  # A run of ASCII letters is always valid UTF-8, so the empty fallback never shows.
  return String.from_bytes(bytes.drop(at).take(stop - at)).unwrap_or("").downcase
end

def byte_is?(bytes: List[Int], at: Int, expected: Int) -> Bool
  return at < bytes.size and bytes[at] == expected
end

# The index after the comment that starts at `at`, or `at` when none starts there.
def comment_end(bytes: List[Int], at: Int) -> Int
  byte = bytes[at]
  if byte == HASH
    return line_end(bytes, at)
  elsif byte == MINUS and byte_is?(bytes, at + 1, MINUS) and dash_comment?(bytes, at)
    return line_end(bytes, at)
  elsif byte == SLASH and byte_is?(bytes, at + 1, STAR) and not executable?(bytes, at)
    return block_end(bytes, at)
  end

  return at
end

# `--` starts a comment only when whitespace or a control character follows it, or the sql ends.
def dash_comment?(bytes: List[Int], at: Int) -> Bool
  return at + 2 >= bytes.size or bytes[at + 2] <= SPACE
end

# `/*!` and `/*M!` hold code that the server runs.
def executable?(bytes: List[Int], at: Int) -> Bool
  if byte_is?(bytes, at + 2, EXCLAMATION)
    return true
  end

  return byte_is?(bytes, at + 2, UPPER_M) and byte_is?(bytes, at + 3, EXCLAMATION)
end

def line_end(bytes: List[Int], at: Int) -> Int
  stop = at
  while stop < bytes.size and bytes[stop] != NEWLINE
    stop += 1
  end

  return stop
end

# A comment that is not closed runs to the end of the sql.
def block_end(bytes: List[Int], at: Int) -> Int
  stop = at + 2
  while stop < bytes.size
    if bytes[stop] == STAR and byte_is?(bytes, stop + 1, SLASH)
      return stop + 2
    end

    stop += 1
  end

  return bytes.size
end

# The index after the literal or identifier that starts at `at`, or after the one byte when none starts there. A
# `/*!` comment is skipped whole, since a `;` inside it is part of the code it holds.
def literal_end(bytes: List[Int], at: Int) -> Int
  byte = bytes[at]
  if byte == SINGLE_QUOTE or byte == DOUBLE_QUOTE
    return quoted_end(bytes, at, true)
  elsif byte == BACKTICK
    return quoted_end(bytes, at, false)
  elsif byte == SLASH and byte_is?(bytes, at + 1, STAR)
    return block_end(bytes, at)
  end

  return at + 1
end

# A quote doubled inside the literal is a quote of the text, not its end. One that is not closed runs to the end of
# the sql: the server then reports the syntax error.
def quoted_end(bytes: List[Int], at: Int, backslash: Bool) -> Int
  quote = bytes[at]
  stop = at + 1
  while stop < bytes.size
    byte = bytes[stop]
    if backslash and byte == BACKSLASH
      stop += 2
    elsif byte == quote and byte_is?(bytes, stop + 1, quote)
      stop += 2
    elsif byte == quote
      return stop + 1
    else
      stop += 1
    end
  end

  return bytes.size
end
