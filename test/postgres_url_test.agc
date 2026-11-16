import PostgresUrl from "../postgres/url"

private

def target_of(text: String) -> PostgresUrl.Target = PostgresUrl.parse(text).unwrap!

def conninfo_of(text: String) -> String = target_of(text).conninfo

def main() -> Void
  Test.run([
    Test.test("a url without timeout_ms goes to libpq as it is, with no limit") do
      try Test.eq(conninfo_of("postgres://u:pw@h:5432/app"), "postgres://u:pw@h:5432/app")
      try Test.eq(
        conninfo_of("postgresql://u@h/app?sslmode=disable&connect_timeout=5"),
        "postgresql://u@h/app?sslmode=disable&connect_timeout=5",
      )

      try Test.eq(conninfo_of("postgres://h/app?"), "postgres://h/app?")
      return Test.eq(target_of("postgres://h/app").timeout_ms, 0)
    end,
    Test.test("timeout_ms is taken out of a url, wherever it is, and the other parameters stay") do
      only = target_of("postgres://u@h/app?timeout_ms=2000")
      try Test.eq(only.conninfo, "postgres://u@h/app")
      try Test.eq(only.timeout_ms, 2000)
      first = target_of("postgres://u@h/app?timeout_ms=15&sslmode=disable&application_name=a%26b")
      try Test.eq(first.conninfo, "postgres://u@h/app?sslmode=disable&application_name=a%26b")
      try Test.eq(first.timeout_ms, 15)
      last = target_of("postgres://u@h/app?sslmode=disable&timeout_ms=0")
      try Test.eq(last.conninfo, "postgres://u@h/app?sslmode=disable")
      return Test.eq(last.timeout_ms, 0)
    end,
    Test.test("timeout_ms is taken out of a conninfo string, quoted or not, and the other words stay as they are") do
      plain = target_of("host=h dbname=app timeout_ms=2000 user=u")
      try Test.eq(plain.conninfo, "host=h dbname=app user=u")
      try Test.eq(plain.timeout_ms, 2000)
      quoted = target_of("timeout_ms = '300'   password='a b\\' timeout_ms=9' host=h")
      try Test.eq(quoted.conninfo, "password='a b\\' timeout_ms=9' host=h")
      try Test.eq(quoted.timeout_ms, 300)
      try Test.eq(conninfo_of("host=localhost"), "host=localhost")
      return Test.eq(conninfo_of(""), "")
    end,
    Test.test("only the key timeout_ms is taken out: a longer key, a value or a quoted password that holds it stay") do
      longer = target_of("my_timeout_ms=5 timeout_ms_x=6 host=h")
      try Test.eq(longer.conninfo, "my_timeout_ms=5 timeout_ms_x=6 host=h")
      try Test.eq(longer.timeout_ms, 0)
      quoted = target_of("password='x timeout_ms=1' host=h")
      try Test.eq(quoted.conninfo, "password='x timeout_ms=1' host=h")
      try Test.eq(quoted.timeout_ms, 0)
      escaped = target_of("password=x\\ timeout_ms=1 timeout_ms=40")
      try Test.eq(escaped.conninfo, "password=x\\ timeout_ms=1")
      try Test.eq(escaped.timeout_ms, 40)
      url = target_of("postgres://u:timeout_ms%3D1@h/app?options=-c%20timeout_ms%3D1&mytimeout_ms=3")
      try Test.eq(url.conninfo, "postgres://u:timeout_ms%3D1@h/app?options=-c%20timeout_ms%3D1&mytimeout_ms=3")
      return Test.eq(url.timeout_ms, 0)
    end,
    Test.test("a repeated timeout_ms keeps the last value, as libpq does") do
      try Test.eq(target_of("postgres://h/app?timeout_ms=1&timeout_ms=2").timeout_ms, 2)
      return Test.eq(target_of("host=h timeout_ms=1 timeout_ms=2").timeout_ms, 2)
    end,
    Test.test("a text that is not a conninfo string goes to libpq whole, which reports it") do
      try Test.eq(conninfo_of("host=h oops"), "host=h oops")
      return Test.eq(target_of("host=h oops").timeout_ms, 0)
    end,
    Test.test("statement_cache, batch_rows and batch_bytes are taken out of a url and a conninfo string") do
      url = target_of("postgres://u@h/app?statement_cache=0&sslmode=disable&batch_rows=7&batch_bytes=4096")
      try Test.eq(url.conninfo, "postgres://u@h/app?sslmode=disable")
      try Test.eq([url.statement_cache, url.batch_rows, url.batch_bytes], [0, 7, 4096])
      words = target_of("host=h statement_cache='5' batch_rows=1 user=u")
      try Test.eq(words.conninfo, "host=h user=u")
      try Test.eq([words.statement_cache, words.batch_rows, words.batch_bytes], [5, 1, 262_144])
      plain = target_of("postgres://h/app")
      return Test.eq([plain.statement_cache, plain.batch_rows, plain.batch_bytes], [100, 100, 262_144])
    end,
    Test.test("a statement_cache, batch_rows or batch_bytes out of its range is an error") do
      try Test.eq(
        PostgresUrl.parse("postgres://h/app?statement_cache=10001").message,
        "postgres error: the url statement_cache is over 10000: 10001",
      )

      try Test.eq(PostgresUrl.parse("host=h batch_rows=0").message, "postgres error: the url batch_rows is below 1: 0")
      try Test.eq(
        PostgresUrl.parse("host=h batch_rows=1001").message,
        "postgres error: the url batch_rows is over 1000: 1001",
      )

      try Test.eq(
        PostgresUrl.parse("host=h batch_bytes=262145").message,
        "postgres error: the url batch_bytes is over 262144: 262145",
      )

      try Test.eq(
        PostgresUrl.parse("postgres://h/app?batch_bytes=-1").message,
        "postgres error: the url batch_bytes is not a whole number",
      )

      return Test.eq(
        PostgresUrl.parse("postgres://h/app?statement_cache=1e3").message,
        "postgres error: the url statement_cache is not a whole number",
      )
    end,
    Test.test("a timeout_ms that is not a number of milliseconds is an error that repeats no part of the url") do
      message = "postgres error: the url timeout_ms is not a number of milliseconds"
      try Test.eq(PostgresUrl.parse("postgres://u:hunter2@h/app?timeout_ms=soon").message, message)
      try Test.eq(PostgresUrl.parse("postgres://u:hunter2@h/app?timeout_ms=").message, message)
      try Test.eq(PostgresUrl.parse("host=h password=hunter2 timeout_ms=-1").message, message)
      # A `?` that belongs to the password ends the user info: the hint says how to write it.
      hint = PostgresUrl.parse("postgres://u:p?timeout_ms=5@h/db").message
      try Test.eq(hint.include?("%3F"), true)
      return Test.eq(PostgresUrl.parse("host=h timeout_ms=1000000000").message, message)
    end,
  ])
end
