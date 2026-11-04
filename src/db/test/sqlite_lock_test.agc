import SqliteLock from "../sqlite/lock"

def main() -> Void
  Test.run([
    Test.test("a lock that another connection lets go is waited for, a stale snapshot is not") do
      try Test.eq(SqliteLock.waitable?(5), true)
      try Test.eq(SqliteLock.waitable?(261), true)
      try Test.eq(SqliteLock.waitable?(262), true)
      try Test.eq(SqliteLock.waitable?(517), false)
      try Test.eq(SqliteLock.waitable?(6), false)
      return Test.eq(SqliteLock.waitable?(0), false)
    end,
    Test.test("only SQLITE_BUSY itself is the refusal of a write that a read transaction asks for") do
      try Test.eq(SqliteLock.plain_busy?(5), true)
      try Test.eq(SqliteLock.plain_busy?(261), false)
      try Test.eq(SqliteLock.plain_busy?(262), false)
      return Test.eq(SqliteLock.plain_busy?(517), false)
    end,
  ])
end
