## Reads what follows `sqlite:` in a url: the database name and the settings after a `?`.
##
## `app.db?journal_mode=delete&foreign_keys=off&busy_timeout=250&fts5=required`. The parameters are `journal_mode`
## (`wal`, `delete`, `truncate`, `persist`, `memory` or `off`), `foreign_keys` (`on` or `off`), `busy_timeout` (a
## number of milliseconds, at most nine digits), `timeout_ms` (the same: the limit of each statement, none by default),
## `synchronous` (`off`, `normal`, `full` or `extra`), `mmap_size` and `journal_size_limit` (bytes), `cache_size`
## (pages, or KiB when negative), `fts5=required`, and for the native driver `statement_cache` (statements, at most
## 10000, 0 for none), `batch_rows` and `batch_bytes` (at least 1). Names and values are lowercase and case-sensitive
## (SQLite itself takes `WAL`; this reader does not), and a value is not percent-decoded. A name given twice keeps its
## last value. A `?` always starts the parameters, so a path that holds one (or the Windows `\\?\` prefix) cannot be
## named here: write it as a `file:` URI. A text that starts with `file:` is a SQLite URI, and its `?` belongs to
## SQLite: it is returned whole as the path, with the default settings. An error is `sqlite error: <message>`.

import Milliseconds from "../support/milliseconds"

## What a url sets besides the path. The defaults suit a web app: WAL lets readers run beside the one writer, foreign
## keys are checked, and a busy database is waited for, not failed at once. `journal_given` says that the url named
## the journal mode, which makes a WAL that cannot be set an error, not a skip. `uri` says that the name is a `file:`
## URI, whose own parameters (`immutable=1`, `nolock=1`, `vfs=unix-none`) can rule WAL out: then a default `wal` is
## skipped whatever the reason, while for a plain path only a read-only database is skipped.
##
## The other pragmas have the defaults of Rails 8. `synchronous` is empty when the url did not name it: the adapter
## then uses `normal` in a WAL database and leaves SQLite's own `full` in any other mode. `mmap_size` is in bytes (0 is
## SQLite's own: no memory map), `cache_size` is in pages, or in KiB when negative (SQLite's own is -2000), and
## `journal_size_limit` is in bytes (negative is SQLite's own: no limit).
##
## The native driver keeps up to `statement_cache` prepared statements per connection, and a call of it gives at most
## `batch_rows` rows or about `batch_bytes` bytes of values: a longer result takes more calls. The FFI driver has no
## cache and reads row by row.
struct Settings
  journal_mode: String = "wal"
  journal_given: Bool = false
  uri: Bool = false
  foreign_keys: Bool = true
  busy_timeout: Int = 5000
  timeout_ms: Int = 0
  synchronous: String = ""
  mmap_size: Int = 134_217_728
  cache_size: Int = 2000
  journal_size_limit: Int = 67_108_864
  fts5: Bool = false
  statement_cache: Int = 100
  batch_rows: Int = 1000
  batch_bytes: Int = 4_194_304
end

## The name to open and the settings to apply.
struct Target
  path: String
  settings: Settings
end

## Reads the text after `sqlite:`.
def parse(text: String) -> Result[Target]
  return ok(Target(path: text, settings: Settings(uri: true))) if text.start_with?(URI_PREFIX)

  return ok(Target(path: text, settings: Settings())) if not text.include?("?")

  halves = split_once(text, "?")
  settings = try read_settings(halves[1])
  ok(Target(path: halves[0], settings: settings))
end

private

JOURNAL_MODES = ["wal", "delete", "truncate", "persist", "memory", "off"]
SYNCHRONOUS_MODES = ["off", "normal", "full", "extra"]
NAMES = [
  "journal_mode, foreign_keys, busy_timeout, timeout_ms, synchronous, mmap_size, cache_size, ",
  "journal_size_limit, fts5, statement_cache, batch_rows or batch_bytes",
].join("")
# At most 15 digits, so that a number is far from the limit of an Int and of what SQLite takes.
MAX_DIGITS = 15
MINUS = 45
DIGIT_ZERO = 48
DIGIT_NINE = 57
URI_PREFIX = "file:"
MAX_STATEMENT_CACHE = 10_000

# The text before the first `separator` and the text after it (empty when there is none).
def split_once(text: String, separator: String) -> List[String]
  found = text.index_of(separator)
  case found
    some(at) -> [text.slice(0, at), text.slice(at + 1, text.length - at - 1)]
    none -> [text, ""]
  end
end

def one_of?(choices: List[String], value: String) -> Bool = choices.any? do |choice| choice == value end

def read_settings(query: String) -> Result[Settings]
  settings = Settings()
  return ok(settings) if query.empty?

  for pair in query.split("&")
    return error("sqlite error: the url has an empty parameter") if pair.empty?

    return error("sqlite error: the url parameter #{pair} has no value, write name=value") if not pair.include?("=")

    halves = split_once(pair, "=")
    name = halves[0]
    value = halves[1]
    if name == "journal_mode" and one_of?(JOURNAL_MODES, value)
      settings = settings.with(journal_mode: value, journal_given: true)
    elsif name == "foreign_keys" and one_of?(["on", "off"], value)
      settings = settings.with(foreign_keys: value == "on")
    elsif name == "busy_timeout"
      settings = settings.with(busy_timeout: try read_milliseconds(value, name))
    elsif name == "timeout_ms"
      settings = settings.with(timeout_ms: try read_milliseconds(value, name))
    elsif name == "synchronous" and one_of?(SYNCHRONOUS_MODES, value)
      settings = settings.with(synchronous: value)
    elsif name == "mmap_size"
      settings = settings.with(mmap_size: try read_number(value, name, false))
    elsif name == "cache_size"
      settings = settings.with(cache_size: try read_number(value, name, true))
    elsif name == "journal_size_limit"
      settings = settings.with(journal_size_limit: try read_number(value, name, true))
    elsif name == "fts5" and value == "required"
      settings = settings.with(fts5: true)
    elsif name == "statement_cache"
      settings = settings.with(statement_cache: try read_bounded(value, name, 0, MAX_STATEMENT_CACHE))
    elsif name == "batch_rows"
      settings = settings.with(batch_rows: try read_bounded(value, name, 1, 0))
    elsif name == "batch_bytes"
      settings = settings.with(batch_bytes: try read_bounded(value, name, 1, 0))
    elsif one_of?(["journal_mode", "foreign_keys", "synchronous", "fts5"], name)
      return error("sqlite error: the url parameter #{name} has a value that is not allowed: #{value}")
    else
      return error("sqlite error: unknown url parameter #{name}, expected #{NAMES}")
    end
  end

  ok(settings)
end

def read_milliseconds(text: String, name: String) -> Result[Int]
  case Milliseconds.parse(text)
    some(n) -> ok(n)
    none -> error("sqlite error: the url #{name} is not a number of milliseconds")
  end
end

# A whole number from `low` to `high` (no bound when `high` is 0).
def read_bounded(text: String, name: String, low: Int, high: Int) -> Result[Int]
  n = try read_number(text, name, false)
  return error("sqlite error: the url #{name} is below #{low}: #{n}") if n < low

  return error("sqlite error: the url #{name} is over #{high}: #{n}") if high > 0 and n > high

  ok(n)
end

# A whole number of up to MAX_DIGITS digits, with a leading `-` when `signed`. SQLite reads a negative `cache_size` as
# KiB and a negative `journal_size_limit` as no limit, so those two take it; a negative `mmap_size` has no use.
def read_number(text: String, name: String, signed: Bool) -> Result[Int]
  bytes = text.bytes.to_a
  negative = signed and not bytes.empty? and bytes[0] == MINUS
  digits = bytes
  if negative
    digits = bytes.drop(1)
  end

  not_digits = digits.any? do |byte| byte < DIGIT_ZERO or byte > DIGIT_NINE end
  if digits.empty? or digits.size > MAX_DIGITS or not_digits
    return error("sqlite error: the url #{name} is not a whole number")
  end

  ok(text.to_i.unwrap_or(0))
end
