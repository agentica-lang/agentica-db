import Errors from "../orm/errors"

def kind_of(message: String) -> String
  return Errors.kind(Errors.classify(message))
end

def main() -> Void
  Test.run([
    Test.test("unique and foreign-key violations are conflicts in every database, other constraints are not") do
      try Test.eq(kind_of("sqlite error 19: UNIQUE constraint failed: users.name"), "Conflict")
      try Test.eq(kind_of("sqlite error 19: FOREIGN KEY constraint failed"), "Conflict")
      try Test.eq(kind_of("sqlite error 19: NOT NULL constraint failed: users.name"), "Database")
      try Test.eq(kind_of("postgres error 23505: duplicate key value violates unique constraint"), "Conflict")
      try Test.eq(kind_of("postgres error 23503: insert or update violates foreign key constraint"), "Conflict")
      try Test.eq(kind_of("postgres error 23502: null value in column"), "Database")
      try Test.eq(kind_of("mysql error 1062: Duplicate entry 'a' for key 'name'"), "Conflict")
      try Test.eq(kind_of("mysql error 1451: Cannot delete or update a parent row"), "Conflict")
      try Test.eq(kind_of("mysql error 1452: Cannot add or update a child row"), "Conflict")
      return Test.eq(kind_of("mysql error 1048: Column 'name' cannot be null"), "Database")
    end,
    Test.test("a failure of the Orm has the kind in its text, and its message is what follows the kind") do
      bad = Errors.classify(Errors.text(Errors.BAD_REQUEST, "users", "nickname is not a column of the table"))
      try Test.eq(Errors.kind(bad), "BadRequest")
      try Test.eq(Errors.message(bad), "users: nickname is not a column of the table")
      try Test.eq(kind_of(Errors.text(Errors.SCHEMA, "users", "x")), "Schema")
      try Test.eq(kind_of(Errors.text(Errors.DECODE, "users", "x")), "NotDecodable")
      return Test.eq(kind_of(Errors.text(Errors.DATABASE, "users", "x")), "Database")
    end,
    Test.test("any other text is a failure of the database, with its message as it is") do
      try Test.eq(kind_of("db error: unsupported database url scheme ftp"), "Database")
      try Test.eq(kind_of("orm error: users: the old shape"), "Database")
      return Test.eq(Errors.message(Errors.classify("postgres error: the connection is closed")),
                     "postgres error: the connection is closed")
    end,
  ])
end
