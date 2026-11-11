## The kinds of failure of the Orm. A `Result` carries its error as a text, so the Orm writes the kind into the text
## (`orm error <code>: <table>: <message>`, as an adapter writes its code into `<adapter> error <code>: <message>`),
## and `classify` reads it back, together with the codes of the databases for a unique or foreign-key violation.

## The codes written in the text of a failure of the Orm.
export BAD_REQUEST = "bad_request"
export SCHEMA = "schema"
export DECODE = "decode"
export DATABASE = "database"

# The messages of the databases for a unique or a foreign-key violation (SQLite has one code, 19, for every
# constraint: the text tells them apart). A not null or a check violation is no conflict.
CONFLICTS = [
  "sqlite error 19: UNIQUE",
  "sqlite error 19: FOREIGN KEY",
  "postgres error 23505:",
  "postgres error 23503:",
  "mysql error 1062:",
  "mysql error 1451:",
  "mysql error 1452:",
]

## What went wrong, for a handler to `case` on. The text is the message for a log: `<table>: <message>` for a
## failure of the Orm, the message of the database as it is for the others.
export enum Error
  BadRequest(String)
  Conflict(String)
  NotDecodable(String)
  Schema(String)
  Database(String)
end

## The text of a failure of the Orm: `orm error <code>: <table>: <message>`.
export def text(code: String, table: String, message: String) -> String = "orm error #{code}: #{table}: #{message}"

## The kind of the failure a text describes. A text that is no failure of the Orm and no conflict is `Database`: a
## failure of the database (a lost connection, a missing table, a not null) or of the Orm's own bookkeeping.
export def classify(message: String) -> Error
  return Error.Conflict(message) if CONFLICTS.any? do |prefix| message.start_with?(prefix) end

  return Error.BadRequest(payload(message, BAD_REQUEST)) if message.start_with?("orm error #{BAD_REQUEST}: ")

  return Error.Schema(payload(message, SCHEMA)) if message.start_with?("orm error #{SCHEMA}: ")

  return Error.NotDecodable(payload(message, DECODE)) if message.start_with?("orm error #{DECODE}: ")

  return Error.Database(payload(message, DATABASE)) if message.start_with?("orm error #{DATABASE}: ")

  Error.Database(message)
end

## The name of the kind: `BadRequest`, `Conflict`, `NotDecodable`, `Schema` or `Database`. It is for logs and tests;
## code should `case` on the `Error`.
export def kind(failure: Error) -> String
  case failure
    Error.BadRequest(_) -> "BadRequest"
    Error.Conflict(_) -> "Conflict"
    Error.NotDecodable(_) -> "NotDecodable"
    Error.Schema(_) -> "Schema"
    Error.Database(_) -> "Database"
  end
end

## The message of the failure, for a log.
export def message(failure: Error) -> String
  case failure
    Error.BadRequest(text) -> text
    Error.Conflict(text) -> text
    Error.NotDecodable(text) -> text
    Error.Schema(text) -> text
    Error.Database(text) -> text
  end
end

# What follows `orm error <code>: `.
def payload(message: String, code: String) -> String
  start = "orm error #{code}: ".length
  message.slice(start, message.length - start)
end
