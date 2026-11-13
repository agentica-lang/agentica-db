## The kinds of failure of the Orm. A `Result` carries its error as a text, so the Orm writes the kind into the text
## (`orm error <code>: <table>: <message>`, as an adapter writes its code into `<adapter> error <code>: <message>`),
## and `classify` reads it back, together with the codes of the databases for a unique or foreign-key violation.

## The codes written in the text of a failure of the Orm.
BAD_REQUEST = "bad_request"
SCHEMA = "schema"
DECODE = "decode"
DATABASE = "database"

## What went wrong, for a handler to `case` on. The text is the message for a log: `<table>: <message>` for a
## failure of the Orm, the message of the database as it is for the others.
enum Failure
  BadRequest(String)
  Conflict(String)
  NotDecodable(String)
  Schema(String)
  Database(String)
end

## The text of a failure of the Orm: `orm error <code>: <table>: <message>`.
def text(code: String, table: String, message: String) -> String = "orm error #{code}: #{table}: #{message}"

## The kind of the failure a text describes. A text that is no failure of the Orm and no conflict is `Database`: a
## failure of the database (a lost connection, a missing table, a not null) or of the Orm's own bookkeeping.
def classify(message: String) -> Failure
  return Failure.Conflict(message) if CONFLICTS.any? do |prefix| message.start_with?(prefix) end

  return Failure.BadRequest(payload(message, BAD_REQUEST)) if message.start_with?("orm error #{BAD_REQUEST}: ")

  return Failure.Schema(payload(message, SCHEMA)) if message.start_with?("orm error #{SCHEMA}: ")

  return Failure.NotDecodable(payload(message, DECODE)) if message.start_with?("orm error #{DECODE}: ")

  return Failure.Database(payload(message, DATABASE)) if message.start_with?("orm error #{DATABASE}: ")

  Failure.Database(message)
end

## The name of the kind: `BadRequest`, `Conflict`, `NotDecodable`, `Schema` or `Database`. It is for logs and tests;
## code should `case` on the `Failure`.
def kind(failure: Failure) -> String
  case failure
    Failure.BadRequest(_) -> "BadRequest"
    Failure.Conflict(_) -> "Conflict"
    Failure.NotDecodable(_) -> "NotDecodable"
    Failure.Schema(_) -> "Schema"
    Failure.Database(_) -> "Database"
  end
end

## The message of the failure, for a log.
def message(failure: Failure) -> String
  case failure
    Failure.BadRequest(text) -> text
    Failure.Conflict(text) -> text
    Failure.NotDecodable(text) -> text
    Failure.Schema(text) -> text
    Failure.Database(text) -> text
  end
end

private

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

# What follows `orm error <code>: `.
def payload(message: String, code: String) -> String
  start = "orm error #{code}: ".length
  message.slice(start, message.length - start)
end
