import Sqlite from "../sqlite"

def main() -> Void
  Test.run([
    Test.test("a lock that another connection lets go is waited for, a stale snapshot and a lock of our own are not") do
      try Test.eq(Sqlite.waitable?(5), true)
      try Test.eq(Sqlite.waitable?(261), true)
      try Test.eq(Sqlite.waitable?(262), true)
      try Test.eq(Sqlite.waitable?(517), false)
      try Test.eq(Sqlite.waitable?(6), false)
      return Test.eq(Sqlite.waitable?(0), false)
    end,
  ])
end
