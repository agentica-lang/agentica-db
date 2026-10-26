import MysqlSql from "../mysql_sql"

MORE_THAN_ONE = "mysql error: the sql has more than one statement"
NO_STATEMENT = "mysql error: the sql has no statement"

def verb_of(sql: String, verb: String) -> Result[Void]
  done = MysqlSql.inspect(sql)
  try Test.ok?(done)
  return Test.eq(done.unwrap!.verb, verb)
end

def refused(sql: String, message: String) -> Result[Void]
  return Test.eq(MysqlSql.inspect(sql).message, message)
end

def main() -> Void
  Test.run([
    Test.test("the verb is the first word after whitespace and comments") do
      try verb_of("select 1", "select")
      try verb_of("  BEGIN", "begin")
      try verb_of("/* c */ # c\n-- c\n\tStart Transaction", "start")
      try verb_of("(select 1)", "")
      return verb_of("/*! select 1 */", "")
    end,
    Test.test("a semicolon inside a literal, an identifier or a comment does not end the statement") do
      try verb_of("select 'a;b', \"c;d\", `e;f`", "select")
      try verb_of("select 'it\\';x', 'it'';x'", "select")
      try verb_of("select 1 /* ; */ # ;\n-- ;\n", "select")
      return verb_of("select 1 /*! ; */", "select")
    end,
    Test.test("a trailing semicolon and comments are not a second statement") do
      try verb_of("select 1;", "select")
      try verb_of("select 1 ; -- done", "select")
      return verb_of("select 1; # done\n/* done */", "select")
    end,
    Test.test("a second statement is refused") do
      try refused("select 1; select 2", MORE_THAN_ONE)
      try refused("; select 1", MORE_THAN_ONE)
      try refused("select 'a'; 'b'", MORE_THAN_ONE)
      # `--` without a space after it is two minus signs, not a comment.
      return refused("select 1; --1", MORE_THAN_ONE)
    end,
    Test.test("sql without a statement is refused") do
      try refused("", NO_STATEMENT)
      try refused(" \n\t", NO_STATEMENT)
      try refused("-- a\n# b\n/* c */ ;", NO_STATEMENT)
      return refused("select 1" + String.from_code(0), "mysql error: the sql contains a NUL character")
    end,
  ])
end
