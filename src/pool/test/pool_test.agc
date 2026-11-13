import Pool from "../pool"

private

def main() -> Void
  Test.run([
    Test.test("only the checkout and the lease timeouts are timeouts") do
      try Test.eq(Pool.timeout?("pool error: checkout timed out after 100 ms"), true)
      try Test.eq(Pool.timeout?("pool error: lease timed out after 5 ms"), true)
      try Test.eq(Pool.timeout?("pool error: queue full"), false)
      try Test.eq(Pool.timeout?("pool error: closed"), false)
      return Test.eq(Pool.timeout?("sqlite error 5: database is locked"), false)
    end,
  ])
end
