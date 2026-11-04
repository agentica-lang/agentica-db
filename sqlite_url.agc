## Reads what follows `sqlite:` in a url: the database name and the settings after a `?`.
##
## `app.db?journal_mode=delete&foreign_keys=off&busy_timeout=250&fts5=required`. The parameters are `journal_mode`
## (`wal`, `delete`, `truncate`, `persist`, `memory` or `off`), `foreign_keys` (`on` or `off`), `busy_timeout` (a
## number of milliseconds, at most nine digits) and `fts5=required`. Names and values are lowercase and case-sensitive
## (SQLite itself takes `WAL`; this reader does not), and a value is not percent-decoded. A name given twice keeps its
## last value. A `?` always starts the parameters, so a path that holds one (or the Windows `\\?\` prefix) cannot be
## named here: write it as a `file:` URI. A text that starts with `file:` is a SQLite URI, and its `?` belongs to
## SQLite: it is returned whole as the path, with the default settings. An error is `sqlite error: <message>`.

MAX_BUSY_TIMEOUT_DIGITS = 9
DIGIT_ZERO = 48
DIGIT_NINE = 57
JOURNAL_MODES = ["wal", "delete", "truncate", "persist", "memory", "off"]
URI_PREFIX = "file:"

## What a url sets besides the path. The defaults suit a web app: WAL lets readers run beside the one writer, foreign
## keys are checked, and a busy database is waited for, not failed at once. `journal_given` says that the url named
## the journal mode, which makes a WAL that cannot be set an error, not a skip. `uri` says that the name is a `file:`
## URI, whose own parameters (`immutable=1`, `nolock=1`, `vfs=unix-none`) can rule WAL out: then a default `wal` is
## skipped whatever the reason, while for a plain path only a read-only database is skipped.
export struct Settings
  journal_mode: String = "wal"
  journal_given: Bool = false
  uri: Bool = false
  foreign_keys: Bool = true
  busy_timeout: Int = 5000
  fts5: Bool = false
end

## The name to open and the settings to apply.
export struct Target
  path: String
  settings: Settings
end

## Reads the text after `sqlite:`.
export def parse(text: String) -> Result[Target]
  if text.start_with?(URI_PREFIX)
    return ok(Target(path: text, settings: Settings(uri: true)))
  end

  if not text.include?("?")
    return ok(Target(path: text, settings: Settings()))
  end

  halves = split_once(text, "?")
  settings = try read_settings(halves[1])
  return ok(Target(path: halves[0], settings: settings))
end

# The text before the first `separator` and the text after it (empty when there is none).
def split_once(text: String, separator: String) -> List[String]
  found = text.index_of(separator)
  case found
    some(at) -> return [text.slice(0, at), text.slice(at + 1, text.length - at - 1)]
    none -> return [text, ""]
  end
end

def one_of?(choices: List[String], value: String) -> Bool
  return choices.any? do |choice| choice == value end
end

def read_settings(query: String) -> Result[Settings]
  settings = Settings()
  if query.empty?
    return ok(settings)
  end

  for pair in query.split("&")
    if pair.empty?
      return error("sqlite error: the url has an empty parameter")
    end

    if not pair.include?("=")
      return error("sqlite error: the url parameter #{pair} has no value, write name=value")
    end

    halves = split_once(pair, "=")
    name = halves[0]
    value = halves[1]
    if name == "journal_mode" and one_of?(JOURNAL_MODES, value)
      settings = settings.with(journal_mode: value, journal_given: true)
    elsif name == "foreign_keys" and one_of?(["on", "off"], value)
      settings = settings.with(foreign_keys: value == "on")
    elsif name == "busy_timeout"
      settings = settings.with(busy_timeout: try read_milliseconds(value))
    elsif name == "fts5" and value == "required"
      settings = settings.with(fts5: true)
    elsif one_of?(["journal_mode", "foreign_keys", "fts5"], name)
      return error("sqlite error: the url parameter #{name} has a value that is not allowed: #{value}")
    else
      return error(
        "sqlite error: unknown url parameter #{name}, expected journal_mode, foreign_keys, busy_timeout " + "or fts5",
      )
    end
  end

  return ok(settings)
end

# A non-empty run of ASCII digits, at most nine (about 11 days): a wait of that many milliseconds is far from any
# overflow in the clock arithmetic of the retry loop.
def read_milliseconds(text: String) -> Result[Int]
  bytes = text.bytes.to_a
  not_digits = bytes.any? do |byte| byte < DIGIT_ZERO or byte > DIGIT_NINE end
  if bytes.empty? or bytes.size > MAX_BUSY_TIMEOUT_DIGITS or not_digits
    return error("sqlite error: the url busy_timeout is not a number of milliseconds")
  end

  return text.to_i
end
