import SqliteUrl from "../sqlite/url"

def target_of(text: String) -> SqliteUrl.Target
  return SqliteUrl.parse(text).unwrap!
end

def refused(text: String, message: String) -> Result[Void]
  return Test.eq(SqliteUrl.parse(text).message, "sqlite error: #{message}")
end

def main() -> Void
  Test.run([
    Test.test("a name without parameters, or with a lone ?, gets the web app defaults") do
      bare = target_of("app.db")
      try Test.eq(bare.path, "app.db")
      try Test.eq(bare.settings.journal_mode, "wal")
      try Test.eq(bare.settings.journal_given, false)
      try Test.eq(bare.settings.foreign_keys, true)
      try Test.eq(bare.settings.busy_timeout, 5000)
      try Test.eq(bare.settings.timeout_ms, 0)
      try Test.eq(bare.settings.synchronous, "")
      try Test.eq(bare.settings.mmap_size, 134_217_728)
      try Test.eq(bare.settings.cache_size, 2000)
      try Test.eq(bare.settings.journal_size_limit, 67_108_864)
      try Test.eq(bare.settings.fts5, false)
      try Test.eq(target_of(":memory:").path, ":memory:")
      lone = target_of("app.db?")
      try Test.eq(lone.path, "app.db")
      return Test.eq(lone.settings.journal_mode, "wal")
    end,
    Test.test("every parameter is read, a repeated name keeps its last value, and the path stops at the first ?") do
      found = target_of(
        "a.db?journal_mode=wal&journal_mode=delete&foreign_keys=off&busy_timeout=250&timeout_ms=300&fts5=required" +
        "&synchronous=extra&mmap_size=0&cache_size=-64000&journal_size_limit=-1",
      )

      try Test.eq(found.path, "a.db")
      try Test.eq(found.settings.journal_mode, "delete")
      try Test.eq(found.settings.journal_given, true)
      try Test.eq(found.settings.foreign_keys, false)
      try Test.eq(found.settings.busy_timeout, 250)
      try Test.eq(found.settings.timeout_ms, 300)
      try Test.eq(found.settings.fts5, true)
      try Test.eq(found.settings.synchronous, "extra")
      try Test.eq(found.settings.mmap_size, 0)
      try Test.eq(found.settings.cache_size, -64000)
      try Test.eq(found.settings.journal_size_limit, -1)
      return Test.eq(target_of("a.db?foreign_keys=off&foreign_keys=on").settings.foreign_keys, true)
    end,
    Test.test("a text that starts with file: is a SQLite URI and goes whole, with the defaults") do
      uri = target_of("file:app.db?mode=ro&cache=shared")
      try Test.eq(uri.path, "file:app.db?mode=ro&cache=shared")
      try Test.eq(uri.settings.journal_given, false)
      try Test.eq(uri.settings.uri, true)
      try Test.eq(target_of("a.db").settings.uri, false)
      return Test.eq(target_of("file::memory:?cache=shared").path, "file::memory:?cache=shared")
    end,
    Test.test("a parameter that is empty, has no =, or is not known is an error") do
      try refused("a.db?&foreign_keys=off", "the url has an empty parameter")
      try refused("a.db?foreign_keys=off&", "the url has an empty parameter")
      try refused("a.db?journal_mode", "the url parameter journal_mode has no value, write name=value")
      return refused(
        "a.db?color=red",
        "unknown url parameter color, expected journal_mode, foreign_keys, busy_timeout, timeout_ms, synchronous, " +
        "mmap_size, cache_size, journal_size_limit, fts5, statement_cache, batch_rows or batch_bytes",
      )
    end,
    Test.test("names and values are lowercase and case-sensitive, and nothing is percent-decoded") do
      try refused("a.db?journal_mode=WAL", "the url parameter journal_mode has a value that is not allowed: WAL")
      try refused(
        "a.db?Foreign_Keys=on",
        "unknown url parameter Foreign_Keys, expected journal_mode, foreign_keys, busy_timeout, timeout_ms, " +
        "synchronous, mmap_size, cache_size, journal_size_limit, fts5, statement_cache, batch_rows or batch_bytes",
      )

      try refused("a.db?foreign_keys=ON", "the url parameter foreign_keys has a value that is not allowed: ON")
      try refused("a.db?journal_mode=%77al", "the url parameter journal_mode has a value that is not allowed: %77al")
      try refused("a.db?synchronous=NORMAL", "the url parameter synchronous has a value that is not allowed: NORMAL")
      try refused("a.db?fts5=yes", "the url parameter fts5 has a value that is not allowed: yes")
      return refused("a.db?busy_timeout=%31%30", "the url busy_timeout is not a number of milliseconds")
    end,
    Test.test("a busy_timeout is up to nine digits") do
      try Test.eq(target_of("a.db?busy_timeout=0").settings.busy_timeout, 0)
      try Test.eq(target_of("a.db?busy_timeout=999999999").settings.busy_timeout, 999999999)
      try refused("a.db?busy_timeout=1000000000", "the url busy_timeout is not a number of milliseconds")
      try refused("a.db?busy_timeout=", "the url busy_timeout is not a number of milliseconds")
      try refused("a.db?busy_timeout=-5", "the url busy_timeout is not a number of milliseconds")
      return refused("a.db?timeout_ms=soon", "the url timeout_ms is not a number of milliseconds")
    end,
    Test.test(
      "mmap_size, cache_size and journal_size_limit are whole numbers, and only the last two can be negative",
    ) do
      try Test.eq(target_of("a.db?mmap_size=1073741824").settings.mmap_size, 1_073_741_824)
      try Test.eq(target_of("a.db?cache_size=-2000").settings.cache_size, -2000)
      try refused("a.db?mmap_size=-1", "the url mmap_size is not a whole number")
      try refused("a.db?cache_size=", "the url cache_size is not a whole number")
      try refused("a.db?cache_size=-", "the url cache_size is not a whole number")
      try refused("a.db?journal_size_limit=1k", "the url journal_size_limit is not a whole number")
      return refused("a.db?mmap_size=1234567890123456", "the url mmap_size is not a whole number")
    end,
    Test.test("the statement cache is 0 to 10000 statements, and a batch at least one row and one byte") do
      settings = target_of("a.db").settings
      try Test.eq([settings.statement_cache, settings.batch_rows, settings.batch_bytes], [100, 1000, 4_194_304])
      chosen = target_of("a.db?statement_cache=0&batch_rows=1&batch_bytes=1").settings
      try Test.eq([chosen.statement_cache, chosen.batch_rows, chosen.batch_bytes], [0, 1, 1])
      try Test.eq(target_of("a.db?statement_cache=10000").settings.statement_cache, 10_000)
      try refused("a.db?statement_cache=10001", "the url statement_cache is over 10000: 10001")
      try refused("a.db?batch_rows=0", "the url batch_rows is below 1: 0")
      try refused("a.db?batch_bytes=0", "the url batch_bytes is below 1: 0")
      return refused("a.db?statement_cache=-1", "the url statement_cache is not a whole number")
    end,
  ])
end
