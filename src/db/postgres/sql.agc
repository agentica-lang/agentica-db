## Turns the `?` placeholders of the API into the `$1..$n` of PostgreSQL, and checks that the sql is one statement.
##
## A scanner walks the sql once and copies the bytes between placeholders as they are. A `?` inside a string literal
## (`'?'`, `E'\?'`), a quoted identifier (`"col?"`), a dollar-quoted string (`$$ ? $$`, `$tag$ ? $tag$`) or a comment
## (`-- ?`, `/* ? */`, which nest) stays as it is. The PostgreSQL operators that contain `?` (jsonb `?`, `?|`, `?&`)
## are not available: call `jsonb_exists`, `jsonb_exists_any` or `jsonb_exists_all`.

TAB = 9
NEWLINE = 10
CARRIAGE_RETURN = 13
SPACE = 32
DOUBLE_QUOTE = 34
DOLLAR = 36
SINGLE_QUOTE = 39
LEFT_PAREN = 40
RIGHT_PAREN = 41
STAR = 42
MINUS = 45
SLASH = 47
DIGIT_ZERO = 48
DIGIT_NINE = 57
SEMICOLON = 59
QUESTION = 63
UPPER_A = 65
UPPER_E = 69
UPPER_Z = 90
BACKSLASH = 92
UNDERSCORE = 95
LOWER_A = 97
LOWER_E = 101
LOWER_Z = 122
FIRST_NON_ASCII = 128

## The sql with `$n` placeholders, how many there are, and its first word in lower case (`begin`, `commit`,
## `select`; empty when the statement starts with something else), read after any whitespace and comments.
export struct Translated
  sql: String
  count: Int
  verb: String
end

# The state of the walk: the parts of the translated sql so far, the start of the bytes not copied yet (they are
# copied as they are, in one slice, when a placeholder or the end comes), the next byte to read, and what has been
# seen.
struct Scan
  parts: List[Bytes]
  from: Int
  at: Int
  count: Int
  depth: Int
  ended: Bool
  content: Bool
  verb: String
end

## Translates `?` to `$1..$n`. An error is `postgres error: <message>` for a NUL, a second statement, no statement
## at all, or a `$n` written by hand.
export def translate(sql: String) -> Result[Translated]
  if sql.include?(String.from_code(0))
    return error("postgres error: the sql contains a NUL character")
  end

  bytes = sql.bytes
  scan = Scan(parts: [], from: 0, at: 0, count: 0, depth: 0, ended: false, content: false, verb: "")
  while scan.at < bytes.size
    scan = try step(bytes, scan)
  end

  if not scan.content
    return error("postgres error: the sql has no statement")
  end

  translated = try String.from_bytes(Bytes.concat(scan.parts.push(bytes.drop(scan.from))))
  return ok(Translated(sql: translated, count: scan.count, verb: scan.verb))
end

# Reads one literal, comment, placeholder or byte.
def step(bytes: Bytes, scan: Scan) -> Result[Scan]
  at = scan.at
  byte = bytes[at]
  stop = span_end(bytes, at)
  if stop > at
    return span(bytes, scan, stop)
  elsif byte == QUESTION
    return placeholder(bytes, scan)
  elsif byte == SEMICOLON and scan.depth == 0
    return ok(scan.with(at: at + 1, ended: true))
  elsif space?(byte)
    return ok(scan.with(at: at + 1))
  end

  return other(bytes, scan)
end

# A literal is content, a comment is not.
def span(bytes: Bytes, scan: Scan, stop: Int) -> Result[Scan]
  seen = scan
  if not comment_at?(bytes, scan.at)
    seen = try with_content(bytes, scan)
  end

  return ok(seen.with(at: stop))
end

def placeholder(bytes: Bytes, scan: Scan) -> Result[Scan]
  seen = try with_content(bytes, scan)
  count = seen.count + 1
  parts = seen.parts.push(bytes.slice(seen.from, seen.at - seen.from)).push("$#{count}".bytes)
  return ok(seen.with(parts: parts, from: seen.at + 1, count: count, at: seen.at + 1))
end

def other(bytes: Bytes, scan: Scan) -> Result[Scan]
  at = scan.at
  byte = bytes[at]
  seen = try with_content(bytes, scan)
  if byte == DOLLAR and digit_after?(bytes, at) and not word_before?(bytes, at)
    return error("postgres error: write ? for a parameter, not a $n placeholder")
  end

  return ok(seen.with(at: at + 1, depth: next_depth(seen.depth, byte)))
end

# Content after the end of the statement is a second statement. The first content gives the verb.
def with_content(bytes: Bytes, scan: Scan) -> Result[Scan]
  if scan.ended
    return error(more_than_one())
  end

  if scan.content
    return ok(scan)
  end

  return ok(scan.with(content: true, verb: word_at(bytes, scan.at)))
end

def word_at(bytes: Bytes, at: Int) -> String
  stop = at
  while stop < bytes.size and letter?(bytes[stop])
    stop += 1
  end

  # A run of ASCII letters is always valid UTF-8, so the empty fallback never shows.
  return String.from_bytes(bytes.slice(at, stop - at)).unwrap_or("").downcase
end

def more_than_one() -> String
  return "postgres error: the sql has more than one statement"
end

# Parentheses are counted because a `;` inside them belongs to the statement (a rule with several actions).
def next_depth(depth: Int, byte: Int) -> Int
  if byte == LEFT_PAREN
    return depth + 1
  elsif byte == RIGHT_PAREN and depth > 0
    return depth - 1
  end

  return depth
end

def space?(byte: Int) -> Bool
  return byte == SPACE or (byte >= TAB and byte <= CARRIAGE_RETURN)
end

def digit?(byte: Int) -> Bool
  return byte >= DIGIT_ZERO and byte <= DIGIT_NINE
end

def letter?(byte: Int) -> Bool
  return (byte >= UPPER_A and byte <= UPPER_Z) or (byte >= LOWER_A and byte <= LOWER_Z)
end

# Characters of an identifier; a byte outside ASCII belongs to a letter of another script.
def word_byte?(byte: Int) -> Bool
  return letter?(byte) or digit?(byte) or byte == UNDERSCORE or byte == DOLLAR or byte >= FIRST_NON_ASCII
end

def word_before?(bytes: Bytes, i: Int) -> Bool
  return i > 0 and word_byte?(bytes[i - 1])
end

def digit_after?(bytes: Bytes, i: Int) -> Bool
  return i + 1 < bytes.size and digit?(bytes[i + 1])
end

def comment_at?(bytes: Bytes, i: Int) -> Bool
  return bytes[i] == MINUS or bytes[i] == SLASH
end

# The index after the literal or comment that starts at `i`, or `i` when none starts there. One that is not
# closed runs to the end of the sql; the server then reports the syntax error.
def span_end(bytes: Bytes, i: Int) -> Int
  byte = bytes[i]
  if byte == SINGLE_QUOTE
    return quoted_end(bytes, i, escape_string?(bytes, i))
  elsif byte == DOUBLE_QUOTE
    return quoted_end(bytes, i, false)
  elsif byte == MINUS and i + 1 < bytes.size and bytes[i + 1] == MINUS
    return line_end(bytes, i)
  elsif byte == SLASH and i + 1 < bytes.size and bytes[i + 1] == STAR
    return block_end(bytes, i)
  elsif byte == DOLLAR and not word_before?(bytes, i)
    return dollar_end(bytes, i)
  end

  return i
end

# E'...' is the only string where a backslash escapes: the E must not end a longer word.
def escape_string?(bytes: Bytes, i: Int) -> Bool
  if i == 0
    return false
  end

  prefix = bytes[i - 1]
  if prefix != UPPER_E and prefix != LOWER_E
    return false
  end

  return not word_before?(bytes, i - 1)
end

# A quote doubled inside the literal is a quote of the text, not its end.
def quoted_end(bytes: Bytes, i: Int, backslash: Bool) -> Int
  quote = bytes[i]
  at = i + 1
  while at < bytes.size
    byte = bytes[at]
    if backslash and byte == BACKSLASH
      at += 2
    elsif byte == quote and at + 1 < bytes.size and bytes[at + 1] == quote
      at += 2
    elsif byte == quote
      return at + 1
    else
      at += 1
    end
  end

  return bytes.size
end

# PostgreSQL ends a `--` comment at \n or \r.
def line_end(bytes: Bytes, i: Int) -> Int
  at = i
  while at < bytes.size and bytes[at] != NEWLINE and bytes[at] != CARRIAGE_RETURN
    at += 1
  end

  return at
end

# Block comments nest in PostgreSQL.
def block_end(bytes: Bytes, i: Int) -> Int
  at = i + 2
  level = 1
  while at < bytes.size and level > 0
    if bytes[at] == SLASH and at + 1 < bytes.size and bytes[at + 1] == STAR
      level += 1
      at += 2
    elsif bytes[at] == STAR and at + 1 < bytes.size and bytes[at + 1] == SLASH
      level -= 1
      at += 2
    else
      at += 1
    end
  end

  if at > bytes.size
    return bytes.size
  end

  return at
end

# `$tag$ ... $tag$`, with an empty tag as `$$`. A tag does not start with a digit, so `$1` is not a quote.
def dollar_end(bytes: Bytes, i: Int) -> Int
  tag_end = i + 1
  while tag_end < bytes.size and tag_byte?(bytes[tag_end], tag_end == i + 1)
    tag_end += 1
  end

  if tag_end >= bytes.size or bytes[tag_end] != DOLLAR
    return i
  end

  tag = bytes.slice(i, tag_end + 1 - i)
  at = tag_end + 1
  while at < bytes.size
    if bytes[at] == DOLLAR and matches_at?(bytes, at, tag)
      return at + tag.size
    end

    at += 1
  end

  return bytes.size
end

def tag_byte?(byte: Int, first: Bool) -> Bool
  if first
    return letter?(byte) or byte == UNDERSCORE or byte >= FIRST_NON_ASCII
  end

  return letter?(byte) or digit?(byte) or byte == UNDERSCORE or byte >= FIRST_NON_ASCII
end

def matches_at?(bytes: Bytes, at: Int, tag: Bytes) -> Bool
  if at + tag.size > bytes.size
    return false
  end

  for offset in 0...tag.size
    if bytes[at + offset] != tag[offset]
      return false
    end
  end

  return true
end
