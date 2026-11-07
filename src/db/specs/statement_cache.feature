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
  # (a second hit). The first run of each statement prepares it there.
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
      | Int 1 | Int 100  | Int 2 | Int 1  | Int 0     |

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
      | Int 1 | Int 100  | Int 2 | Int 1  | Int 0     |

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
