## Ordered migrations of a database, over `Db`. A migration has a version (a positive Int), a name and an action: sql
## statements or a function over the connection. `up` applies the migrations that the database has not seen, in
## order, each one in its own transaction, and records it in a table (`schema_migrations`) with the checksum of its
## sql. Running `up` again applies nothing. Keep each migration in its own file that exports `migration()`; see
## `examples/migrations.agc`.
##
## `up` refuses to run, with `migrate error: <message>`, when the history does not fit the list: a version that is not
## ascending in the list, a migration that is applied but missing from the list, an applied migration whose sql or
## name has changed, or a pending migration older than one already applied. A migration that fails rolls back and
## stops the run; the ones before it stay applied. A function migration has the checksum of its name only, since a
## function has no text.
##
## The same code runs on SQLite, PostgreSQL and MySQL. There is no `down`: undo a change with a new migration. A
## function migration runs inside the transaction of `up`, so it must not start one, and on SQLite a
## `PRAGMA foreign_keys = off` does nothing inside it. MySQL commits at once after a statement that changes the schema
## (`create table`, `alter table`...), so a failure between such a statement and its row in the history leaves it
## applied and unrecorded: put each schema change alone in its own migration, and make a repeat harmless (`create
## table if not exists`, `drop table if exists`), so that running `up` again passes. Run `up` from one process at a
## time (at startup, before the server listens): two runs at once make one of them fail on the primary key of the
## history table (on PostgreSQL, the first run of two can also fail in `create table if not exists` with a unique
## error on pg_type), and on MySQL a schema change may already be done.

import Db from "db"

VERSION_COLUMNS = "version, name, checksum"
MAX_NAME_BYTES = 255

## What a migration does: run these statements (one per entry, each with no parameters), or call this function.
export enum Action
  Statements(List[String])
  Code(Fn[Db.Connection, Result[Void]])
end

## One step of the history of a database. Make one with `sql` or `code`.
export struct Migration
  version: Int
  name: String
  action: Action
end

# A row of the history table.
struct Row
  version: Int
  name: String
  checksum: String
end

## A migration that runs sql statements, one `Db.execute` each.
export def sql(version: Int, name: String, statements: List[String]) -> Migration
  return Migration(version: version, name: name, action: Action.Statements(statements))
end

## A migration that calls `body` with the connection of its transaction. A function has no text to check, so a change
## to it is not noticed.
export def code(version: Int, name: String, body: Fn[Db.Connection, Result[Void]]) -> Migration
  return Migration(version: version, name: name, action: Action.Code(body))
end

## Applies the migrations that are not recorded yet, in order, and gives their versions (empty when there was nothing
## to do). `table` is where the history is kept (letters, digits and `_`); two lists with two tables are two
## histories.
export def up(
  conn: Db.Connection,
  migrations: List[Migration],
  table: String = "schema_migrations",
) -> Result[List[Int]]
  try check_table(table)
  try check_list(migrations)
  try prepare_history(conn, table)
  applied = try recorded(conn, table)
  try check_history(migrations, applied)
  highest = applied.reduce(0) do |top, row| max(top, row.version) end
  pending = migrations.select do |migration| not applied.any? do |row| row.version == migration.version end end
  if pending.any? do |migration| migration.version < highest end
    old = pending.find do |migration| migration.version < highest end.unwrap!
    return error(
      "migrate error: migration #{label(old)} is older than the applied migration #{highest}, " +
      "so it would run out of order",
    )
  end

  done: List[Int] = []
  for migration in pending
    try apply(conn, migration, table)
    done = done.push(migration.version)
  end

  return ok(done)
end

def label(migration: Migration) -> String
  return "#{migration.version} (#{migration.name})"
end

def max(a: Int, b: Int) -> Int
  if a > b
    return a
  end

  return b
end

# Letters, digits and `_`, so the name is safe to write into sql.
def check_table(table: String) -> Result[Void]
  bytes = table.bytes.to_a
  bad = bytes.any? do |byte| not identifier_byte?(byte) end
  if bytes.empty? or bad or (bytes[0] >= 48 and bytes[0] <= 57)
    return error("migrate error: the table name must be letters, digits and _, and not start with a digit")
  end

  return ok()
end

def identifier_byte?(byte: Int) -> Bool
  letter = (byte >= 97 and byte <= 122) or (byte >= 65 and byte <= 90)
  return letter or (byte >= 48 and byte <= 57) or byte == 95
end

# Versions are positive and ascend in the list, so the list reads as the history.
def check_list(migrations: List[Migration]) -> Result[Void]
  previous = 0
  for migration in migrations
    if migration.name.empty? or migration.name.bytesize > MAX_NAME_BYTES
      return error("migrate error: migration #{migration.version} needs a name of 1 to #{MAX_NAME_BYTES} bytes")
    end

    if migration.version <= previous
      return error(
        "migrate error: migration #{label(migration)} must have a version above #{previous}: " +
        "versions are positive and ascend in the list",
      )
    end

    previous = migration.version
  end

  return ok()
end

# The engine errors of the two steps before the first migration carry the prefix too.
def prepare_history(conn: Db.Connection, table: String) -> Result[Void]
  created = Db.execute(
    conn,
    "create table if not exists #{table} (version bigint not null primary key, " +
    "name varchar(255) not null, checksum varchar(64) not null)",
    [],
  )

  case created
    error(message) -> return error("migrate error: #{message}")
    ok(_) -> return ok()
  end
end

def recorded(conn: Db.Connection, table: String) -> Result[List[Row]]
  asked = Db.query(conn, "select #{VERSION_COLUMNS} from #{table} order by version", [])
  rows = try prefixed(asked)
  found: List[Row] = []
  for row in rows
    found = found.push(try read_row(row))
  end

  return ok(found)
end

def prefixed[T](done: Result[T]) -> Result[T]
  case done
    error(message) -> return error("migrate error: #{message}")
    ok(value) -> return ok(value)
  end
end

def read_row(row: Db.Row) -> Result[Row]
  version = try int_column(row, "version")
  name = try text_column(row, "name")
  checksum = try text_column(row, "checksum")
  return ok(Row(version: version, name: name, checksum: checksum))
end

def int_column(row: Db.Row, key: String) -> Result[Int]
  case row.get(key, Db.Value.Null)
    Db.Value.Int(n) -> return ok(n)
    _ -> return error("migrate error: the history table has a #{key} that is not an integer")
  end
end

def text_column(row: Db.Row, key: String) -> Result[String]
  case row.get(key, Db.Value.Null)
    Db.Value.Text(text) -> return ok(text)
    _ -> return error("migrate error: the history table has a #{key} that is not text")
  end
end

# Every applied migration is in the list and has the checksum it had.
def check_history(migrations: List[Migration], applied: List[Row]) -> Result[Void]
  for row in applied
    found = migrations.find do |migration| migration.version == row.version end
    case found
      error(_) -> return error("migrate error: migration #{row.version} (#{row.name}) is applied but not in the list")
      ok(migration) ->
        if migration.name != row.name
          return error(
            "migrate error: migration #{row.version} (#{migration.name}) was renamed after it was " +
            "applied, it was (#{row.name})",
          )
        end

        if checksum(migration) != row.checksum
          return error("migrate error: migration #{label(migration)} was changed after it was applied")
        end
    end
  end

  return ok()
end

def checksum(migration: Migration) -> String
  case migration.action
    Action.Statements(statements) -> return Digest.sha256_hexdigest(statements.join(";\n").bytes)
    Action.Code(_) -> return Digest.sha256_hexdigest("code #{migration.name}".bytes)
  end
end

# The action and the record of it are one transaction, so a migration is either applied and recorded or neither.
def apply(conn: Db.Connection, migration: Migration, table: String) -> Result[Void]
  done = Db.transaction(conn) do |tx|
    try run(tx, migration)
    try Db.execute(
      tx,
      "insert into #{table} (#{VERSION_COLUMNS}) values (?, ?, ?)",
      [Db.Value.Int(migration.version), Db.Value.Text(migration.name), Db.Value.Text(checksum(migration))],
    )

    ok()
  end

  case done
    ok(_) -> return ok()
    error(message) -> return error("migrate error: migration #{label(migration)} failed: #{message}")
  end
end

def run(tx: Db.Connection, migration: Migration) -> Result[Void]
  case migration.action
    Action.Statements(statements) ->
      for statement in statements
        try Db.execute(tx, statement, [])
      end

      return ok()
    Action.Code(body) -> return body.call(tx)
  end
end
