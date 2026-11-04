import DbPool from "../db_pool"

def main() -> Void
  Test.run([
    Test.test("the default size follows the database, and one for a private memory database") do
      try Test.eq(DbPool.default_size("sqlite:app.db"), 4)
      try Test.eq(DbPool.default_size("sqlite::memory:"), 1)
      try Test.eq(DbPool.default_size("sqlite::memory:?timeout_ms=100"), 1)
      try Test.eq(DbPool.default_size("sqlite:file::memory:"), 1)
      try Test.eq(DbPool.default_size("sqlite:file:app?mode=memory"), 1)
      try Test.eq(DbPool.default_size("sqlite:file::memory:?cache=shared"), 4)
      try Test.eq(DbPool.default_size("sqlite:file:app?mode=memory&cache=shared"), 4)
      try Test.eq(DbPool.default_size("postgres://u:p@localhost/app"), 10)
      return Test.eq(DbPool.default_size("mariadb://u:p@127.0.0.1/app"), 10)
    end,
    Test.test("a timeout is a checkout or a lease that ran out of time, or a statement over its timeout_ms") do
      try Test.eq(DbPool.timeout?("pool error: checkout timed out after 200 ms"), true)
      try Test.eq(DbPool.timeout?("pool error: lease timed out after 200 ms"), true)
      try Test.eq(DbPool.timeout?("postgres error 57014: canceling statement due to statement timeout"), true)
      try Test.eq(DbPool.timeout?("pool error: queue full"), false)
      try Test.eq(DbPool.timeout?("pool error: closed"), false)
      return Test.eq(DbPool.timeout?("sqlite error 5: database is locked"), false)
    end,
  ])
end
