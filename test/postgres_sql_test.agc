import {Translated} from "../postgres_sql"
import PostgresSql from "../postgres_sql"

MORE_THAN_ONE = "postgres error: the sql has more than one statement"
NO_STATEMENT = "postgres error: the sql has no statement"
HAND_WRITTEN = "postgres error: write ? for a parameter, not a $n placeholder"

def translated(sql: String, count: Int) -> Result[Translated]
  return ok(Translated(sql: sql, count: count))
end

def same(sql: String, count: Int) -> Result[Void]
  return Test.eq(PostgresSql.translate(sql), translated(sql, count))
end

def becomes(sql: String, expected: String, count: Int) -> Result[Void]
  return Test.eq(PostgresSql.translate(sql), translated(expected, count))
end

def refused(sql: String, message: String) -> Result[Void]
  return Test.eq(PostgresSql.translate(sql), error(message))
end

def main() -> Void
  Test.run([
    Test.test("placeholders are numbered in order") do
      try becomes("select ?", "select $1", 1)
      try becomes("select ?::int, ?", "select $1::int, $2", 2)
      eleven = "?,?,?,?,?,?,?,?,?,?,?"
      try becomes("insert into t values (#{eleven})", "insert into t values ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)", 11)
      try becomes("select\t?\r\n,\n?", "select\t$1\r\n,\n$2", 2)
      try becomes("select 'héllo ✓ ?', ? as \"é\"", "select 'héllo ✓ ?', $1 as \"é\"", 1)
      return same("select 1", 0)
    end,
    Test.test("a question mark in a string literal stays") do
      try same("select '?'", 0)
      try becomes("select 'it''s ?', ?", "select 'it''s ?', $1", 1)
      try becomes("select '', ?, ''", "select '', $1, ''", 1)
      # A backslash does not escape in a plain string, so this one ends at the second quote.
      try becomes("select '\\', ?", "select '\\', $1", 1)
      # An unterminated literal runs to the end: the server reports the syntax error.
      return same("select 'abc ?", 0)
    end,
    Test.test("a backslash escapes only in an E string") do
      try same("select E'\\'?'", 0)
      try same("select e'\\\\\\'?'", 0)
      try becomes("select E'\\'?', ?", "select E'\\'?', $1", 1)
      try becomes("select E'it''s ?', ?", "select E'it''s ?', $1", 1)
      # The E ends the word `type`, so it is not a prefix.
      return becomes("select type'\\', ?", "select type'\\', $1", 1)
    end,
    Test.test("a question mark in a quoted identifier stays") do
      try same("select \"col?\" from t", 0)
      try becomes("select \"a\"\"?\", ? from \"t?\"", "select \"a\"\"?\", $1 from \"t?\"", 1)
      return same("select \"unterminated ?", 0)
    end,
    Test.test("a question mark in a comment stays") do
      try becomes("select 1 -- ?\n, ?", "select 1 -- ?\n, $1", 1)
      try becomes("select /* ? */ ?", "select /* ? */ $1", 1)
      try becomes("select /* ? /* nested ? */ still ? */ ?", "select /* ? /* nested ? */ still ? */ $1", 1)
      try same("select 1 -- last ?", 0)
      try same("select 1 /* unterminated ?", 0)
      return becomes("select 1/*?*/+?", "select 1/*?*/+$1", 1)
    end,
    Test.test("a question mark in a dollar quote stays") do
      try becomes("select $$ ? $$, ?", "select $$ ? $$, $1", 1)
      try becomes("select $tag$ ? $$ ? $tag$, ?", "select $tag$ ? $$ ? $tag$, $1", 1)
      try becomes("select $a1$ ? $a1$ || ?", "select $a1$ ? $a1$ || $1", 1)
      try becomes("select $é$ ? $é$, ?", "select $é$ ? $é$, $1", 1)
      # A tag is case sensitive.
      try becomes("select $T$ ? $t$ ? $T$, ?", "select $T$ ? $t$ ? $T$, $1", 1)
      try same("select $$ ? ", 0)
      return becomes("do $$ begin perform 1; end $$ ", "do $$ begin perform 1; end $$ ", 0)
    end,
    Test.test("a dollar inside a word is not a quote or a placeholder") do
      try same("select a$1 from t$$x", 0)
      try becomes("select col$x, ?", "select col$x, $1", 1)
      try refused("select $1", HAND_WRITTEN)
      return refused("select ?, $2", HAND_WRITTEN)
    end,
    Test.test("one statement, with or without a closing semicolon") do
      try same("select 1;", 0)
      try same("select 1 ; ; -- end\n /* x */ ", 0)
      try becomes("select ?;", "select $1;", 1)
      try same("select ';'", 0)
      try same("select \";\"", 0)
      try same("select $$;$$", 0)
      try same("select 1 -- ; select 2", 0)
      return same("create rule r as on insert to a do also (insert into b values (1); insert into c values (2))", 0)
    end,
    Test.test("a second statement is refused") do
      try refused("select 1; select 2", MORE_THAN_ONE)
      try refused("select 1; selec 2", MORE_THAN_ONE)
      try refused("select 1;select 2", MORE_THAN_ONE)
      try refused("select 1; ?", MORE_THAN_ONE)
      try refused("select 1; 'x'", MORE_THAN_ONE)
      try refused("select 1; \"x\"", MORE_THAN_ONE)
      try refused("select 1; $$x$$", MORE_THAN_ONE)
      try refused("select 1; -- c\n select 2", MORE_THAN_ONE)
      return refused("create table t(a); insert into t values (?)", MORE_THAN_ONE)
    end,
    Test.test("sql without a statement is refused") do
      try refused("", NO_STATEMENT)
      try refused("   \n\t", NO_STATEMENT)
      try refused(";", NO_STATEMENT)
      try refused(" ; ;; ", NO_STATEMENT)
      try refused("-- only a comment", NO_STATEMENT)
      try refused("/* a */ -- b\n ;", NO_STATEMENT)
      return refused(String.from_code(11) + String.from_code(12), NO_STATEMENT)
    end,
    Test.test("a NUL is refused") do
      return refused("select 1#{String.from_code(0)}", "postgres error: the sql contains a NUL character")
    end,
  ])
end
