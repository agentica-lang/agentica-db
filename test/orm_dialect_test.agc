import Dialect from "../orm/dialect"

def main() -> Void
  Test.run([
    Test.test("a name is a letter or an underscore, then letters, digits or underscores") do
      try Test.eq(Dialect.valid_name?("users"), true)
      try Test.eq(Dialect.valid_name?("_Created_at2"), true)
      try Test.eq(Dialect.valid_name?(""), false)
      try Test.eq(Dialect.valid_name?("2fast"), false)
      try Test.eq(Dialect.valid_name?("a-b"), false)
      try Test.eq(Dialect.valid_name?("a b"), false)
      try Test.eq(Dialect.valid_name?("users; drop table users"), false)
      try Test.eq(Dialect.valid_name?("a\"b"), false)
      return Test.eq(Dialect.valid_name?("a`b"), false)
    end,
  ])
end
