import MysqlAdapter from "../mysql/mysql"

private

def node(server: String, started: Int) -> MysqlAdapter.Identity
  MysqlAdapter.Identity(id: 7, server: server, started: started)
end

def main() -> Void
  Test.run([
    Test.test("a kill goes only to the run of the server that gave the connection") do
      target = node("1@db:3306", 1000)
      try Test.eq(MysqlAdapter.same_server?(node("1@db:3306", 1002), target), true)
      try Test.eq(MysqlAdapter.same_server?(node("2@db2:3306", 1000), target), false)
      try Test.eq(MysqlAdapter.same_server?(node("1@db:3306", 1003), target), false)
      try Test.eq(MysqlAdapter.same_server?(node("", 0), node("", 0)), false)
      ok()
    end,
  ])
end
