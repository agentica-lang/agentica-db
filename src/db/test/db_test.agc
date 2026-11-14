import Db from "../db"
import Mysql from "../mysql"
import Postgres from "../postgres"
import Sqlite from "../sqlite"

private

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
    Test.test("each scheme of a driver of the package names that driver when the driver was not passed") do
      drivers = {
        "Sqlite.driver()": Sqlite.driver(),
        "Postgres.driver()": Postgres.driver(),
        "Mysql.driver()": Mysql.driver(),
      }

      return Test.eq(drivers.keys.flat_map do |name| unnamed(name, drivers[name]) end, [])
    end,
  ])
end

# The schemes of `driver` whose url, opened with no driver, fails without naming it.
def unnamed(name: String, driver: Db.Driver) -> List[String]
  driver.schemes.select do |prefix|
    case Db.open("#{prefix}x", [])
      ok(_) -> true
      error(e) -> not e.message.include?("pass #{name} to")
    end
  end
end
