@native
Feature: PostgreSQL native driver
  What the native PostgreSQL driver adds: a cache of prepared statements per connection, keyed by the sql text and
  bounded by `statement_cache` (100 by default, 0 for none), results read in batches of `batch_rows` rows or about
  `batch_bytes` bytes, one call per batch, and waits on the socket instead of compute calls. Only the statements that
  the server plans (SELECT, INSERT, UPDATE, DELETE, WITH, VALUES, MERGE, TABLE) are cached, and a statement that
  changes the schema (CREATE, ALTER, DROP, IMPORT) lets the whole cache go. The FFI driver has none of this, so these
  scenarios have the tag @native (the FFI run leaves them out). These scenarios need a server: set
  AGENTICA_DB_POSTGRES_URL. [URL] is its url (`[URL]&name=value` adds a parameter).

  Scenario: A statement that ran before comes from the cache on postgres
    Given a "postgres" database
    When I open "[URL]&statement_cache=4"
    And I execute "create temp table t (n integer)"
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
      | Int 2 | Int 4    | Int 2 | Int 2  | Int 0     |

  Scenario: A full cache lets go of the statement used least long ago on postgres
    Given a "postgres" database
    When I open "[URL]&statement_cache=2"
    And I query "select 1 as n"
    And I query "select 2 as n"
    And I query "select 1 as n"
    And I query "select 3 as n"
    And I query "select 2 as n"
    And I read the statement cache
    Then the result is:
      | size  | capacity | hits  | misses | evictions |
      | Int 2 | Int 2    | Int 1 | Int 4  | Int 2     |

  Scenario: A statement_cache of 0 prepares no statement on postgres
    Given a "postgres" database
    When I open "[URL]&statement_cache=0"
    And I query "select 1 as n"
    And I query "select 1 as n"
    And I read the statement cache
    Then the result is:
      | size  | capacity | hits  | misses | evictions |
      | Int 0 | Int 0    | Int 0 | Int 2  | Int 0     |
    And the query "select count(*) as n from pg_prepared_statements" returns:
      | n     |
      | Int 0 |

  Scenario: A statement_cache over its limit is an error on postgres
    Given a "postgres" database
    When I open "[URL]&statement_cache=10001"
    Then it fails with exactly "postgres error: the url statement_cache is over 10000: 10001"

  # The statements that the cache lets go are deallocated on the server 16 at a time, in one round trip, so that it
  # holds at most the cache and the 15 that wait: here 20 statements went through a cache of 2, the first 16 that went
  # were deallocated, and the server holds 2 waiting, the 2 cached and the count itself.
  Scenario: The server keeps only a few statements more than the cache on postgres
    Given a "postgres" database
    When I open "[URL]&statement_cache=2"
    And I query "select [N] as n" for each [N] from 1 to 20
    Then the query "select count(*) as n from pg_prepared_statements" returns:
      | n     |
      | Int 5 |

  # A result longer than a batch takes several calls, the last of which may give no row.
  Scenario Outline: A result of <count> rows reads whole across batches of <rows> rows and <bytes> bytes on postgres
    Given a "postgres" database
    When I open "[URL]&batch_rows=<rows>&batch_bytes=<bytes>"
    And I execute "create temp table t (n integer, s text)"
    And I execute "insert into t select v, 'row ' || v from generate_series(1, <count>) v"
    And I query "select n, s from t order by n"
    Then the result has <count> rows, the last being:
      | n           | s                |
      | Int <count> | Text row <count> |

    Examples:
      | count | rows | bytes   |
      | 2     | 2    | 262144  |
      | 5     | 2    | 262144  |
      | 4     | 100  | 1       |
      | 2500  | 1000 | 262144  |

  # The server sends the rows before the failure, and the driver reads the whole result before it gives a row.
  Scenario: A statement that fails after some rows gives its error alone on postgres
    Given a "postgres" database
    When I open "[URL]&batch_rows=2"
    And I query "select 10 / (v - 4) as y from generate_series(1, 5) v"
    Then it fails with "postgres error 22012: "

  Scenario: A cached statement checks its parameters as the first run does on postgres
    Given a "postgres" database
    When I query "select ?::text as v" with:
      | value  |
      | Text a |
    And I query "select ?::text as v"
    Then it fails with exactly "postgres error: the sql has 1 parameter, got 0"
    When I query "select ?::text as v" with:
      | value       |
      | Text a[NUL]b |
    Then it fails with exactly "postgres error: a text parameter contains a NUL character"

  # An ALTER on this connection lets the cache go, so the next run prepares the statement again. In a transaction this
  # matters: there a cached statement that the server refuses fails the transaction, and is not run again.
  Scenario: A cached statement reads the columns that a table changed in the transaction has now on postgres
    Given a "postgres" database
    When I execute "create temp table t (a integer)"
    And I execute "insert into t values (1)"
    And I query "select * from t"
    And I execute "begin"
    And I execute "alter table t add column b integer default 7"
    And I query "select * from t"
    Then the result is:
      | a     | b     |
      | Int 1 | Int 7 |
    When I execute "commit"
    Then the changed row count is 0

  # Another connection changes the table: the server refuses the cached statement (0A000, "cached plan must not change
  # result type") before it runs, and the driver prepares it again and runs it once more, since no transaction is open.
  # The table is a real one, which the other connections see; its name is this feature's own.
  Scenario: A cached statement whose table another connection changed runs again on postgres
    Given a "postgres" database
    When a connection of its own to "[URL]" executes "drop table if exists agentica_db_native_t"
    And a connection of its own to "[URL]" executes "create table agentica_db_native_t (a integer)"
    And I execute "insert into agentica_db_native_t values (1)"
    And I query "select * from agentica_db_native_t"
    And a connection of its own to "[URL]" executes "alter table agentica_db_native_t add column b integer default 7"
    And I query "select * from agentica_db_native_t"
    Then the result is:
      | a     | b     |
      | Int 1 | Int 7 |
    When a connection of its own to "[URL]" executes "drop table agentica_db_native_t"
    Then the changed row count is 0

  # A DEALLOCATE ALL of the user drops the statements of the cache too (26000): the driver prepares them again.
  Scenario: A cached statement that the server forgot is prepared again on postgres
    Given a "postgres" database
    When I query "select 1 as v"
    And I execute "deallocate all"
    And I query "select 1 as v"
    Then the result is:
      | v     |
      | Int 1 |

  # A prepared statement is not undone by a rollback.
  Scenario: A statement cached inside a transaction that rolled back still runs on postgres
    Given a "postgres" database
    When I execute "begin"
    And I query "select 1 as v"
    And I execute "rollback"
    And I query "select 1 as v"
    Then the result is:
      | v     |
      | Int 1 |
    When I read the statement cache
    Then the result is:
      | size  | capacity | hits  | misses | evictions |
      | Int 1 | Int 100  | Int 1 | Int 1  | Int 0     |

  # A cancelled task leaves its statement running on the connection; the next query asks the server to cancel it and
  # reads its end first, so it does not wait the five seconds.
  Scenario: A query after a cancelled one does not wait for it on postgres
    Given a "postgres" database
    When a task that runs "select pg_sleep(5)" is cancelled after 200 ms, and then "select 1 as v" takes under 3000 ms
    Then the result is:
      | v     |
      | Int 1 |

  # in_transaction? reads the end of the cancelled statement first: the cancel failed it, so the transaction failed.
  Scenario: A statement cancelled in a transaction leaves it failed on postgres
    Given a "postgres" database
    When I execute "begin"
    And a task that runs "select pg_sleep(5)" is cancelled after 200 ms
    Then the connection is in a transaction
    When I query "select 1 as v"
    Then it fails with "postgres error 25P02: "
    When I execute "rollback"
    Then the connection is not in a transaction

  # The queries of a connection run one at a time: each holds the connection from its first call to its last.
  Scenario: Tasks that query one connection at once all get their rows on postgres
    Given the environment variable "AGENTICA_SCHEDULERS" is "4"
    And a "postgres" database
    When I open "[URL]&batch_rows=3"
    And I execute "create temp table t (x integer)"
    And I execute "insert into t values (1), (2), (3), (4)"
    And 8 tasks each query "select x from t order by x" on the connection at once
    Then the result is:
      | x     |
      | Int 1 |
      | Int 2 |
      | Int 3 |
      | Int 4 |

  # Every call on a connection is made under its mutex: a read of the statement cache waits for the query that runs.
  Scenario: The statement cache can be read while a query runs on postgres
    Given a "postgres" database
    When I query "select length(?) as n" with 30000000 characters of text while the statement cache is read
    Then the result is:
      | n            |
      | Int 30000000 |

  # The second statement waits for the mutex while the first runs; the close comes meanwhile.
  Scenario: A statement that waits for the connection while it is closed fails on postgres
    Given a "postgres" database
    When a task executes "select pg_sleep(0.3)", another executes "select 1", and I close the connection after 100 ms
    Then it fails with exactly "postgres error: the connection is closed"

  # A DEALLOCATE ALL drops the statements that wait to be deallocated too: the next batch of DEALLOCATEs does not
  # name them, so it does not fail at the first and leave the rest on the server. Of the 36 statements after it (the
  # count too), 34 went out of the cache of 2: 32 were deallocated, and the server holds the 2 that wait and the 2
  # cached.
  Scenario: The statements let go after a DEALLOCATE ALL are deallocated on postgres
    Given a "postgres" database
    When I open "[URL]&statement_cache=2"
    And I query "select [N] as n" for each [N] from 1 to 10
    And I execute "deallocate all"
    And I query "select [N] as n" for each [N] from 11 to 45
    Then the query "select count(*) as n from pg_prepared_statements" returns:
      | n     |
      | Int 4 |

  # Only `DEALLOCATE [PREPARE] ALL` and `DISCARD ALL` drop the cached statements: an `all` in a comment is no keyword.
  Scenario: A DEALLOCATE of one statement keeps the cache on postgres
    Given a "postgres" database
    When I query "select [N] as n" for each [N] from 1 to 5
    And I execute "prepare mine as select 1"
    And I execute "deallocate mine /* all of it */"
    And I read the statement cache
    Then the result is:
      | size  | capacity | hits  | misses | evictions |
      | Int 5 | Int 100  | Int 0 | Int 5  | Int 0     |

  Scenario: AGENTICA_DB_POSTGRES_DRIVER=ffi runs the FFI driver on postgres
    Given the environment variable "AGENTICA_DB_POSTGRES_DRIVER" is "ffi"
    And a "postgres" database
    When I read the statement cache
    Then it fails with exactly "the FFI driver has no statement cache"

  Scenario: Another AGENTICA_DB_POSTGRES_DRIVER is an error on postgres
    Given the environment variable "AGENTICA_DB_POSTGRES_DRIVER" is "fast"
    And a "sqlite" database
    When I open "postgres://u@127.0.0.1:1/d"
    Then it fails with exactly "postgres error: AGENTICA_DB_POSTGRES_DRIVER is fast, expected native or ffi"

  # Copying big parameters, or turning a big row into values, takes long for a short call on the scheduler: past
  # 256 KiB the call is made on the compute pool. The list is 40 MB, and the row of the second query 30 MB (libpq still
  # reads that one from the socket in short calls, about a millisecond per MB, hence the wider bound).
  Scenario: Big parameters and rows are copied on the compute pool on postgres
    Given the environment variable "AGENTICA_SCHEDULERS" is "1"
    And a "postgres" database
    When I query "select json_array_length(?::json) as n" with a JSON list of 20000000 numbers, and no scheduler stops for 50 ms
    Then the result is:
      | n            |
      | Int 20000000 |
    And another task keeps running during "select repeat('y', 30000000) as s", with gaps under 150 milliseconds
