## The statement scanners of the native SQLite driver (`native/db_sqlite.c`): which statements it runs in a short call
## on the scheduler (`quick_text`, `control_kind`), and which PRAGMAs end the short writes of a connection
## (`pragma_effect`). Both read the text of the statement, so they have to see through what SQLite ignores: white
## space, comments, the case of a keyword, quotes round a name, a schema in front of it. The properties build a
## statement from a known shape, dress it with those, and check what the driver did with it against the shape alone.
## What the driver did is read from `CacheStats.shorts`, the number of statements that ran whole in a short call.
##
## The numbers of a generated `Read` and `Pragma` pick from the tables below by their remainder, so a shrunk case is
## the plain statement.

import Db from "pkg/db/db"
import Prop from "pkg/prop/prop"
import Sqlite from "pkg/db/sqlite/sqlite"

# What SQLite skips between two words. Some hold the words the scanners look for, a `;` or a `*`, which must not
# end or start anything.
GAPS = [
  " ",
  "\n",
  "\t",
  "\r\n",
  "/* c */",
  "/**/",
  "-- c\n",
  "/* select values pragma user_version */",
  "-- begin commit ; pragma synchronous = full\n",
  "/* * / -- ; */",
]
END_MARKS = ["", ";", "; ", ";\n-- end", "-- end", "/* unterminated", " ;/* x */"]
# Attached in memory before the statement runs, so that a PRAGMA can name them: the long name is past the 31 bytes the
# scanner keeps, and the other has a character outside ASCII.
SCHEMAS = ["main", "temp", "aux", "a_schema_name_that_is_longer_than_thirty_one_bytes", "ñ"]
ATTACHED = ["aux", "a_schema_name_that_is_longer_than_thirty_one_bytes", "ñ"]
LONG_NAME = "a_pragma_name_that_is_longer_than_thirty_one_bytes"
CASE_MODES = 3
QUOTES = 4
TXN_SQL = "insert into t (n) values (1)"
SHORTS_PER_TXN = 2

## What a read looks like, by the words it starts with.
export enum ReadShape
  Select
  With
  Values
  UserVersion
  DataVersion
  Explain
  ForeignKeys
end

## A read statement of a shape, dressed: `lead` before it, `gap` between its first word and the rest, `mode` for the
## case of its keywords, `end_mark` after it.
export struct Read
  shape: ReadShape
  lead: List[Int]
  gap: List[Int]
  mode: Int
  end_mark: Int
end

## The PRAGMAs that the driver tells apart, and unknown ones that must not be taken for them.
export enum PragmaName
  JournalMode
  Synchronous
  LockingMode
  WalAutocheckpoint
  WalCheckpoint
  UserVersion
  CacheSize
  ForeignKeys
  Unknown
  UnknownLong
  UnknownPrefix
end

## How a PRAGMA is written: a bare read, `= value`, or `(value)`.
export enum PragmaForm
  Read
  Assign
  Call
end

## A PRAGMA, dressed: in a schema or not (`schema` 0 is none), its name bare or quoted, `gap` between its words.
export struct Pragma
  name: PragmaName
  form: PragmaForm
  schema: Int
  quote: Int
  mode: Int
  gap: List[Int]
end

## The generator of a read statement.
export def read_gen() -> Prop.Gen[Read]
  return Prop.of(Read.codec, JSON.schema(Read))
end

## The generator of a PRAGMA.
export def pragma_gen() -> Prop.Gen[Pragma]
  return Prop.of(Pragma.codec, JSON.schema(Pragma))
end

## A read runs in a short call from its second run (the first prepares it) exactly when it is a SELECT, WITH, VALUES,
## or the PRAGMA data_version or user_version, whatever surrounds it.
export def read_runs_short_as_modelled(read: Read) -> Result[Void]
  sql = read_sql(read)
  conn = try Db.open("sqlite::memory:")
  ran = run_twice(conn, sql)
  counted = shorts_of(conn)
  Db.close(conn)
  try ran
  shorts = try counted
  expected = 0
  if quick?(read.shape)
    expected = 1
  end

  if shorts != expected
    return error("#{sql.inspect} ran #{shorts} statements in a short call, expected #{expected}")
  end

  return ok()
end

## A PRAGMA run between two transactions of cheap writes ends their short calls exactly when it sets journal_mode,
## synchronous, locking_mode or wal_autocheckpoint, or is a wal_checkpoint, whatever surrounds it.
export def pragma_ends_short_writes_as_modelled(pragma: Pragma) -> Result[Void]
  dir = try scratch_dir()
  outcome = pragma_outcome(dir, pragma)
  _ = Path.remove(dir)
  shorts = try outcome
  expected = SHORTS_PER_TXN
  if ends_short_writes?(pragma)
    expected = 0
  end

  if shorts != expected
    return error(
      "#{pragma_sql(pragma).inspect}: a transaction after it ran #{shorts} statements in a short call, " +
      "expected #{expected}",
    )
  end

  return ok()
end

def quick?(shape: ReadShape) -> Bool
  case shape
    ReadShape.Select -> return true
    ReadShape.With -> return true
    ReadShape.Values -> return true
    ReadShape.UserVersion -> return true
    ReadShape.DataVersion -> return true
    ReadShape.Explain -> return false
    ReadShape.ForeignKeys -> return false
  end
end

# The PRAGMAs that change how the connection commits end the short writes when they set a value; wal_checkpoint does in
# any form. An unknown name, a longer name that starts like a known one and a name past what the scanner keeps are not
# them.
def ends_short_writes?(pragma: Pragma) -> Bool
  sets = pragma.form != PragmaForm.Read
  case pragma.name
    PragmaName.JournalMode -> return sets
    PragmaName.Synchronous -> return sets
    PragmaName.LockingMode -> return sets
    PragmaName.WalAutocheckpoint -> return sets
    PragmaName.WalCheckpoint -> return true
    PragmaName.UserVersion -> return false
    PragmaName.CacheSize -> return false
    PragmaName.ForeignKeys -> return false
    PragmaName.Unknown -> return false
    PragmaName.UnknownLong -> return false
    PragmaName.UnknownPrefix -> return false
  end
end

def read_sql(read: Read) -> String
  gap = gap_of(read.gap)
  mode = read.mode.abs % CASE_MODES
  head = ""
  rest = ""
  case read.shape
    ReadShape.Select ->
      head = "select"
      rest = "1 as n"
    ReadShape.With ->
      head = "with"
      rest = "c as (select 1 as n) select n from c"
    ReadShape.Values ->
      head = "values"
      rest = "(1)"
    ReadShape.UserVersion ->
      head = "pragma"
      rest = cased("user_version", mode)
    ReadShape.DataVersion ->
      head = "pragma"
      rest = cased("data_version", mode)
    ReadShape.Explain ->
      head = "explain"
      rest = "select 1 as n"
    ReadShape.ForeignKeys ->
      head = "pragma"
      rest = cased("foreign_keys", mode)
  end

  return "#{gaps_of(read.lead)}#{cased(head, mode)}#{gap}#{rest}#{END_MARKS[read.end_mark.abs % END_MARKS.length]}"
end

def pragma_sql(pragma: Pragma) -> String
  gap = gap_of(pragma.gap)
  mode = pragma.mode.abs % CASE_MODES
  target = quoted(cased(name_of(pragma.name), mode), pragma.quote.abs % QUOTES)
  index = pragma.schema.abs % (SCHEMAS.length + 1)
  if index > 0
    target = "#{quoted(SCHEMAS[index - 1], pragma.quote.abs % QUOTES)}#{gap}.#{gap}#{target}"
  end

  tail = ""
  case pragma.form
    PragmaForm.Read -> tail = ""
    PragmaForm.Assign -> tail = "#{gap}=#{gap}#{value_of(pragma.name)}"
    PragmaForm.Call -> tail = "#{gap}(#{value_of(pragma.name)})"
  end

  return "#{cased("pragma", mode)}#{gap}#{target}#{tail}"
end

def name_of(name: PragmaName) -> String
  case name
    PragmaName.JournalMode -> return "journal_mode"
    PragmaName.Synchronous -> return "synchronous"
    PragmaName.LockingMode -> return "locking_mode"
    PragmaName.WalAutocheckpoint -> return "wal_autocheckpoint"
    PragmaName.WalCheckpoint -> return "wal_checkpoint"
    PragmaName.UserVersion -> return "user_version"
    PragmaName.CacheSize -> return "cache_size"
    PragmaName.ForeignKeys -> return "foreign_keys"
    PragmaName.Unknown -> return "no_such_pragma"
    PragmaName.UnknownLong -> return LONG_NAME
    PragmaName.UnknownPrefix -> return "synchronous_of_nothing"
  end
end

# A value that keeps the database as it is (WAL, the same level), so that only the scanner decides what follows.
def value_of(name: PragmaName) -> String
  case name
    PragmaName.JournalMode -> return "wal"
    PragmaName.Synchronous -> return "normal"
    PragmaName.LockingMode -> return "normal"
    PragmaName.WalAutocheckpoint -> return "1000"
    PragmaName.WalCheckpoint -> return "passive"
    PragmaName.UserVersion -> return "0"
    PragmaName.CacheSize -> return "2000"
    PragmaName.ForeignKeys -> return "on"
    PragmaName.Unknown -> return "1"
    PragmaName.UnknownLong -> return "1"
    PragmaName.UnknownPrefix -> return "1"
  end
end

# A word with the case of its letters changed (ASCII only: SQLite folds no other): all lower, all upper,
# or alternating.
def cased(word: String, mode: Int) -> String
  if mode == 0
    return word
  end

  letters = word.split("")
  upper = mode == 1
  return letters.map do |letter| letter_cased(letter, upper) end.join("")
end

def letter_cased(letter: String, upper: Bool) -> String
  code = letter.code
  if code < 97 or code > 122
    return letter
  end

  if upper or code % 2 == 0
    return letter.upcase
  end

  return letter
end

def quoted(name: String, style: Int) -> String
  case style
    1 -> return "\"#{name}\""
    2 -> return "[#{name}]"
    3 -> return "`#{name}`"
    _ -> return name
  end
end

def gap_of(picks: List[Int]) -> String
  if picks.empty?
    return " "
  end

  return gaps_of(picks)
end

def gaps_of(picks: List[Int]) -> String
  return picks.map do |pick| GAPS[pick.abs % GAPS.length] end.join("")
end

def run_twice(conn: Db.Connection, sql: String) -> Result[Void]
  try Db.query(conn, sql, [])
  try Db.query(conn, sql, [])
  return ok()
end

# The statements that ran whole in a short call. Only the native driver counts them: a run on the FFI driver, which
# CI makes with AGENTICA_DB_SQLITE_DRIVER=ffi, has nothing to check.
def shorts_of(conn: Db.Connection) -> Result[Int]
  case conn
    Db.Connection.Sqlite(sqlite) ->
      case Sqlite.statement_cache(sqlite)
        some(stats) -> return ok(stats.shorts)
        none -> return error("the connection runs the FFI driver, which has no short calls")
      end

    _ -> return error("not a SQLite connection")
  end
end

def scratch_dir() -> Result[String]
  dir = try Path.join(["..", "..", "tmp", "properties", "#{System.pid}-#{Time.monotonic_ns()}"])
  try Dir.mkdir(dir)
  return ok(dir)
end

# Opens a WAL database in the folder, runs two cheap transactions (the second runs whole in short calls), then the
# PRAGMA, then a third, and gives the statements the third ran in a short call.
def pragma_outcome(dir: String, pragma: Pragma) -> Result[Int]
  conn = try Db.open("sqlite:#{try Path.join([dir, "p.db"])}")
  counted = counted_after(conn, pragma)
  Db.close(conn)
  return counted
end

def counted_after(conn: Db.Connection, pragma: Pragma) -> Result[Int]
  try Db.execute(conn, "create table t (n integer)", [])
  for schema in ATTACHED
    try Db.execute(conn, "attach database ':memory:' as \"#{schema}\"", [])
  end

  try transaction(conn)
  try transaction(conn)
  warm = try shorts_of(conn)
  if warm != SHORTS_PER_TXN
    return error("the second transaction ran #{warm} statements in a short call, not #{SHORTS_PER_TXN}")
  end

  try Db.query(conn, pragma_sql(pragma), [])
  try transaction(conn)
  return ok(try shorts_of(conn) - warm)
end

def transaction(conn: Db.Connection) -> Result[Void]
  try Db.transaction(conn) do |inner| Db.execute(inner, TXN_SQL, []) end
  return ok()
end
