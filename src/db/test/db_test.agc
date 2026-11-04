import Db from "../db"

def main() -> Void
  Test.run([
    Test.test("the failures of a statement that ran over its time are timeouts, and no other") do
      try Test.eq(Db.timeout?("sqlite error 9: interrupted"), true)
      try Test.eq(Db.timeout?("sqlite error 9: interrupted; rollback failed: sqlite error 1: no transaction"), true)
      try Test.eq(Db.timeout?("postgres error 57014: canceling statement due to statement timeout"), true)
      try Test.eq(
        Db.timeout?("mysql error 3024: Query execution was interrupted, maximum statement execution time"),
        true,
      )

      try Test.eq(Db.timeout?("mysql error 1969: Query execution was interrupted (max_statement_time exceeded)"), true)
      try Test.eq(Db.timeout?("sqlite error 5: database is locked"), false)
      try Test.eq(Db.timeout?("postgres error 40001: could not serialize access"), false)
      try Test.eq(Db.timeout?("mysql error 2013: Lost connection to server during query"), false)
      return Test.eq(Db.timeout?("db error: unsupported database url scheme ftp"), false)
    end,
  ])
end
