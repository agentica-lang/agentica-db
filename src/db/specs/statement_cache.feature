@native
Feature: SQLite statement cache and batches
  What the native SQLite driver adds: a cache of prepared statements per connection, keyed by the sql text and
  bounded by `statement_cache` (100 by default, 0 for none), and results read in batches of `batch_rows` rows or
  about `batch_bytes` bytes, one call per batch. The pragmas that `open` runs are not cached. The FFI driver has
  neither, so these scenarios have the tag @native (the FFI run leaves them out). [SCRATCH] is a folder of the
  scenario under tmp/.

  Scenario: A statement that ran before comes from the cache on sqlite
    Given a "sqlite" database
    When I open "sqlite::memory:?statement_cache=4"
    And I execute "create table t (n integer)"
    And I execute "insert into t values (?)" with:
      | value |
      | Int 1 |
    And I execute "insert into t values (?)" with:
      | value |
      | Int 2 |
    And I query "select n from t order by n"
    And I query "select n from t order by n"
    And I read the statement cache
    Then the result is:
      | size  | capacity | hits  | misses | evictions |
      | Int 3 | Int 4    | Int 2 | Int 3  | Int 0     |

  Scenario: A full cache finalizes the statement used least long ago on sqlite
    Given a "sqlite" database
    When I open "sqlite::memory:?statement_cache=2"
    And I query "select 1 as n"
    And I query "select 2 as n"
    And I query "select 1 as n"
    And I query "select 3 as n"
    And I query "select 2 as n"
    And I read the statement cache
    Then the result is:
      | size  | capacity | hits  | misses | evictions |
      | Int 2 | Int 2    | Int 1 | Int 4  | Int 2     |

  Scenario: A statement_cache of 0 prepares every statement on sqlite
    Given a "sqlite" database
    When I open "sqlite::memory:?statement_cache=0"
    And I query "select 1 as n"
    And I query "select 1 as n"
    And I read the statement cache
    Then the result is:
      | size  | capacity | hits  | misses | evictions |
      | Int 0 | Int 0    | Int 0 | Int 2  | Int 0     |

  Scenario: A statement_cache over its limit is an error on sqlite
    Given a "sqlite" database
    When I open "sqlite::memory:?statement_cache=10001"
    Then it fails with "sqlite error: the url statement_cache is over 10000"

  # A result longer than a batch takes several calls, the last of which may give no row; a statement that fails in a
  # later batch gives no rows, only its error.
  Scenario Outline: A result of <count> rows reads whole across batches of <rows> rows and <bytes> bytes on sqlite
    Given a "sqlite" database
    When I open "sqlite::memory:?batch_rows=<rows>&batch_bytes=<bytes>"
    And I execute "create table t (n integer, s text)"
    And I execute "insert into t with recursive c(v) as (select 1 union all select v + 1 from c where v < <count>) select v, 'row ' || v from c"
    And I query "select n, s from t order by n"
    Then the result has <count> rows, the last being:
      | n           | s                |
      | Int <count> | Text row <count> |

    Examples:
      | count | rows | bytes   |
      | 2     | 2    | 4194304 |
      | 5     | 2    | 4194304 |
      | 4     | 1000 | 1       |
      | 2500  | 1000 | 4194304 |

  Scenario: A statement that fails in a later batch gives its error alone on sqlite
    Given a "sqlite" database
    When I open "sqlite::memory:?batch_rows=2"
    And I execute "create table t (x integer)"
    And I execute "insert into t values (1), (2), (3), (4), (5)"
    When I query "select case when x = 4 then abs(-9223372036854775807 - 1) else x end as y from t order by x"
    Then it fails with "sqlite error 1: "

  # A cached read runs in a short call on the scheduler only while it is small: past a budget of SQLite VM
  # instructions or 100 rows it stops and runs again on the compute pool, which takes the cached statement once more
  # (one hit: the short call that gave up counts none). The first run of each statement prepares it there.
  Scenario: A cached read too big for a short call runs again on the compute pool, long work on sqlite
    Given a "sqlite" database
    When I open "sqlite::memory:"
    And I query "with recursive c(x) as (select 1 union all select x + 1 from c limit 100000) select max(x) as n from c"
    And I query "with recursive c(x) as (select 1 union all select x + 1 from c limit 100000) select max(x) as n from c"
    Then the result has 1 rows, the last being:
      | n          |
      | Int 100000 |
    When I read the statement cache
    Then the result is:
      | size  | capacity | hits  | misses | evictions |
      | Int 1 | Int 100  | Int 1 | Int 1  | Int 0     |

  Scenario: A cached read too big for a short call runs again on the compute pool, many rows on sqlite
    Given a "sqlite" database
    When I open "sqlite::memory:"
    And I query "with recursive c(x) as (select 1 union all select x + 1 from c limit 101) select x as n from c"
    And I query "with recursive c(x) as (select 1 union all select x + 1 from c limit 101) select x as n from c"
    Then the result has 101 rows, the last being:
      | n       |
      | Int 101 |
    When I read the statement cache
    Then the result is:
      | size  | capacity | hits  | misses | evictions |
      | Int 1 | Int 100  | Int 1 | Int 1  | Int 0     |

  # A short call never waits for SQLite's mutex of the connection: while another task's statement holds it, a cached
  # read goes to the compute pool and the scheduler goes on.
  Scenario: A cached read beside a long statement never stops the scheduler on sqlite
    Given the environment variable "AGENTICA_SCHEDULERS" is "1"
    And a "sqlite" database
    When I open "sqlite::memory:"
    And I query "select 1 as x"
    And another task runs "with recursive c(x) as (select 1 union all select x + 1 from c limit 8000000) select max(x) as n from c" while I query "select 1 as x", and no scheduler stops for 500 ms
    Then the result is:
      | x     |
      | Int 1 |

  # Cancelling a task frees its cursor at once, under a lock of the VM. A free never waits for SQLite's mutex, which
  # the long statement holds: the write's statement goes back unreset (cached) or is left for the next fetch to
  # finalize (no cache), and the write runs again after it.
  Scenario Outline: A cancelled write that waits for a lock never stops the schedulers, statement_cache=<cache> on sqlite
    Given the environment variable "AGENTICA_SCHEDULERS" is "4"
    And a "sqlite" database
    When I open "sqlite:[SCRATCH]/cancel.db?statement_cache=<cache>"
    And I execute "create table t (a integer)"
    And the write "insert into t values (1)" that waits for "sqlite:[SCRATCH]/cancel.db" is cancelled beside "with recursive c(x) as (select 1 union all select x + 1 from c limit 8000000) select max(x) as n from c" within 500 ms
    Then the changed row count is 1

    Examples:
      | cache |
      | 100   |
      | 0     |

  # Big bound data can make one SQLite instruction long (a JSON function reads it whole), so a short call takes at
  # most 256 KiB of it; this list is 40 MB.
  Scenario: A cached read with big bound data runs on the compute pool on sqlite
    Given the environment variable "AGENTICA_SCHEDULERS" is "1"
    And a "sqlite" database
    When I open "sqlite::memory:"
    And I query "select json_array_length(?) as n" with:
      | value   |
      | Text [] |
    And I query "select json_array_length(?) as n" with a JSON list of 20000000 numbers, and no scheduler stops for 150 ms
    Then the result is:
      | n            |
      | Int 20000000 |

  # A write with RETURNING has run by its first row; when its result repeats a name after the table changed, it runs
  # to its end and the error says that it ran.
  Scenario: A cached write whose result repeats a name after the table changed runs and says so on sqlite
    Given a "sqlite" database
    When I open "sqlite::memory:"
    And I execute "create table t (a integer)"
    And I execute "insert into t values (1)"
    And I query "update t set a = a + 1 returning *, 0 as b"
    And I query "update t set a = a + 1 returning *, 0 as b"
    And I execute "alter table t add column b integer default 7"
    And I query "update t set a = a + 1 returning *, 0 as b"
    Then it fails with "sqlite error: the statement ran, but the result has the column b twice"
    And the query "select a from t" returns:
      | a     |
      | Int 4 |

  # SQLite prepares a cached statement again when the schema changed, and its columns change with it. A read of 150
  # rows is past what a short call reads, so the short call stops and the compute pool reads it, and a write with
  # RETURNING never runs in a short call.
  Scenario Outline: A cached statement reads the columns that the table has now: <sql>, <count> row(s) on sqlite
    Given a "sqlite" database
    When I open "sqlite::memory:"
    And I execute "create table t (a integer)"
    And I execute "insert into t with recursive c(v) as (select 1 union all select v + 1 from c where v < <count>) select v from c"
    And I query "<sql>"
    And I query "<sql>"
    And I execute "alter table t add column b integer default 7"
    And I query "<sql>"
    Then the result has <count> rows, the last being:
      | a           | b     |
      | Int <count> | Int 7 |
    When I execute "alter table t drop column b"
    And I query "<sql>"
    Then the result has <count> rows, the last being:
      | a           |
      | Int <count> |

    Examples:
      | sql                            | count |
      | select * from t order by a     | 1     |
      | select * from t order by a     | 150   |
      | update t set a = a returning * | 1     |

  # Changing a WAL database to another journal mode needs every other connection to it closed: a cached statement
  # that was not finalized would keep the first connection open.
  Scenario: Closing a connection finalizes its cached statements on sqlite
    Given a "sqlite" database
    When I open "sqlite:[SCRATCH]/cache.db"
    And I execute "create table t (x integer)"
    And I execute "insert into t values (1)"
    And I query "select x from t"
    And I query "select x from t"
    And I close the database
    And I open "sqlite:[SCRATCH]/cache.db?journal_mode=delete"
    Then the query "select x from t" returns:
      | x     |
      | Int 1 |

  # The tasks share one connection, so its cache is used from several threads at once; a statement that one task runs
  # is prepared again for another that wants it meanwhile.
  Scenario Outline: Tasks that query one connection at once all get their rows, <schedulers> scheduler(s) on sqlite
    Given the environment variable "AGENTICA_SCHEDULERS" is "<schedulers>"
    And a "sqlite" database
    When I open "sqlite::memory:?batch_rows=3"
    And I execute "create table t (x integer)"
    And I execute "insert into t values (1), (2), (3), (4)"
    And 8 tasks each query "select x from t order by x" on the connection at once
    Then the result is:
      | x     |
      | Int 1 |
      | Int 2 |
      | Int 3 |
      | Int 4 |

    Examples:
      | schedulers |
      | 1          |
      | 4          |
