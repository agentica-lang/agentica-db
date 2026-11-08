@native
Feature: MySQL native driver
  What the native MySQL driver adds: a cache of prepared statements per connection, keyed by the sql text and bounded
  by `statement_cache` (100 by default, 0 for none), results read in batches of `batch_rows` rows or about
  `batch_bytes` bytes, one call per batch, and waits on the socket instead of compute calls. Only SELECT, INSERT,
  UPDATE, DELETE, REPLACE, WITH, VALUES and TABLE are cached, and a statement that changes the schema (CREATE, ALTER,
  DROP, RENAME, TRUNCATE) lets the whole cache go. The FFI driver has none of this, so these scenarios have the tag
  @native (the FFI run leaves them out). These scenarios need a server: set AGENTICA_DB_MYSQL_URL. [URL] is its url
  (`[URL]&name=value` adds a parameter). MariaDB takes packets of 16 MB at most by default, hence the sizes of the
  big values.

  Scenario: A statement that ran before comes from the cache on mysql
    Given a "mysql" database
    When I open "[URL]&statement_cache=4"
    And I execute "create temporary table t (n integer)"
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

  Scenario: A full cache lets go of the statement used least long ago on mysql
    Given a "mysql" database
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

  Scenario: A statement_cache of 0 caches no statement on mysql
    Given a "mysql" database
    When I open "[URL]&statement_cache=0"
    And I query "select 1 as n"
    And I query "select 1 as n"
    And I read the statement cache
    Then the result is:
      | size  | capacity | hits  | misses | evictions |
      | Int 0 | Int 0    | Int 0 | Int 2  | Int 0     |

  Scenario: A statement_cache over its limit is an error on mysql
    Given a "mysql" database
    When I open "[URL]&statement_cache=10001"
    Then it fails with exactly "mysql error: the url statement_cache is over 10000: 10001"

  # A statement that the cache lets go is closed on the server before the next one runs (COM_STMT_CLOSE has no reply,
  # so it costs no wait): 20 statements through a cache of 2 made 18 evictions, all closed before the SHOW ran.
  Scenario: The server keeps only the statements of the cache on mysql
    Given a "mysql" database
    When I open "[URL]&statement_cache=2"
    And I query "select [N] as n" for each [N] from 1 to 20
    Then the query "show session status like 'Com_stmt_close'" returns:
      | Variable_name       | Value   |
      | Text Com_stmt_close | Text 18 |

  # A result longer than a batch takes several calls, the last of which may give no row.
  Scenario Outline: A result of <count> rows reads whole across batches of <rows> rows and <bytes> bytes on mysql
    Given a "mysql" database
    When I open "[URL]&batch_rows=<rows>&batch_bytes=<bytes>"
    And I query "with recursive d(x) as (select 0 union all select x + 1 from d where x < 9) select v as n, concat('row ', v) as s from (select a.x + 10 * b.x + 100 * c.x + 1000 * e.x + 1 as v from d a, d b, d c, d e) r where v <= <count> order by v"
    Then the result has <count> rows, the last being:
      | n           | s                |
      | Int <count> | Text row <count> |

    Examples:
      | count | rows | bytes  |
      | 2     | 2    | 262144 |
      | 5     | 2    | 262144 |
      | 4     | 100  | 1      |
      | 2500  | 1000 | 262144 |

  # The driver stores the whole result before it gives a row, so a failure after some rows is the answer.
  Scenario: A statement that fails after some rows gives its error alone on mysql
    Given a "mysql" database
    When I open "[URL]&batch_rows=2"
    And I query "with recursive r(v) as (select 1 union all select v + 1 from r where v < 5) select v, (select 1 union all select 2 from dual where v = 4) as y from r"
    Then it fails with "mysql error 1242: "

  Scenario: A cached statement checks its parameters as the first run does on mysql
    Given a "mysql" database
    When I query "select ? as v" with:
      | value  |
      | Text a |
    And I query "select ? as v"
    Then it fails with exactly "mysql error: the sql has 1 parameter, got 0"
    When I query "select ? as v" with:
      | value        |
      | Text a[NUL]b |
    Then it fails with exactly "mysql error: a text parameter contains a NUL character"

  # An ALTER on this connection lets the cache go, so the next run prepares the statement again.
  Scenario: A cached statement reads the columns that a table changed on this connection has now on mysql
    Given a "mysql" database
    When I execute "create temporary table t (a integer)"
    And I execute "insert into t values (1)"
    And I query "select * from t"
    And I execute "alter table t add column b integer default 7"
    And I query "select * from t"
    Then the result is:
      | a     | b     |
      | Int 1 | Int 7 |

  # Another connection changes the table: the server prepares the cached statement again by itself, and the library
  # reads the new columns. The table is a real one, which the other connections see; its name is this feature's own.
  Scenario: A cached statement whose table another connection changed reads its new columns on mysql
    Given a "mysql" database
    When a connection of its own to "[URL]" executes "drop table if exists agentica_db_mysql_native_t"
    And a connection of its own to "[URL]" executes "create table agentica_db_mysql_native_t (a integer)"
    And I execute "insert into agentica_db_mysql_native_t values (1)"
    And I query "select * from agentica_db_mysql_native_t"
    And a connection of its own to "[URL]" executes "alter table agentica_db_mysql_native_t add column b integer default 7"
    And I query "select * from agentica_db_mysql_native_t"
    Then the result is:
      | a     | b     |
      | Int 1 | Int 7 |
    When a connection of its own to "[URL]" executes "drop table agentica_db_mysql_native_t"
    Then the changed row count is 0

  # A cancelled task leaves its statement running on the connection; the next query kills it (KILL QUERY on a
  # connection of its own) and reads its end first, so it does not wait the five seconds.
  Scenario: A query after a cancelled one does not wait for it on mysql
    Given a "mysql" database
    When a task that runs "select sleep(5) as s" is cancelled after 200 ms, and then "select 1 as v" takes under 3000 ms
    Then the result is:
      | v     |
      | Int 1 |

  # A killed statement does not end the transaction on MySQL or MariaDB: in_transaction? reads its end first.
  Scenario: A statement cancelled in a transaction leaves it open on mysql
    Given a "mysql" database
    When I execute "start transaction"
    And a task that runs "select sleep(5) as s" is cancelled after 200 ms
    Then the connection is in a transaction
    When I execute "rollback"
    Then the connection is not in a transaction

  # The queries of a connection run one at a time: each holds the connection from its first call to its last.
  Scenario: Tasks that query one connection at once all get their rows on mysql
    Given the environment variable "AGENTICA_SCHEDULERS" is "4"
    And a "mysql" database
    When I open "[URL]&batch_rows=3"
    And I execute "create temporary table t (x integer)"
    And I execute "insert into t values (1), (2), (3), (4)"
    And 8 tasks each query "select x from t order by x" on the connection at once
    Then the result is:
      | x     |
      | Int 1 |
      | Int 2 |
      | Int 3 |
      | Int 4 |

  # Every call on a connection is made under its mutex: a read of the statement cache waits for the query that runs.
  Scenario: The statement cache can be read while a query runs on mysql
    Given a "mysql" database
    When I query "select length(?) as n" with 10000000 characters of text while the statement cache is read
    Then the result is:
      | n            |
      | Int 10000000 |

  # The second statement waits for the mutex while the first runs; the close comes meanwhile.
  Scenario: A statement that waits for the connection while it is closed fails on mysql
    Given a "mysql" database
    When a task executes "do sleep(0.3)", another executes "select 1", and I close the connection after 100 ms
    Then it fails with exactly "mysql error: the connection is closed"

  Scenario: AGENTICA_DB_MYSQL_DRIVER=ffi runs the FFI driver on mysql
    Given the environment variable "AGENTICA_DB_MYSQL_DRIVER" is "ffi"
    And a "mysql" database
    When I read the statement cache
    Then it fails with exactly "the FFI driver has no statement cache"

  Scenario: Another AGENTICA_DB_MYSQL_DRIVER is an error on mysql
    Given the environment variable "AGENTICA_DB_MYSQL_DRIVER" is "fast"
    And a "sqlite" database
    When I open "mysql://u@127.0.0.1:1/d"
    Then it fails with exactly "mysql error: AGENTICA_DB_MYSQL_DRIVER is fast, expected native or ffi"

  # Copying big parameters, or turning a big row into values, takes long for a short call on the scheduler: past
  # 256 KiB the call is made on the compute pool. The list is 12 MB, and the row of the second query 10 MB (the library
  # still reads that one from the socket in short calls, hence the wider bound).
  Scenario: Big parameters and rows are copied on the compute pool on mysql
    Given the environment variable "AGENTICA_SCHEDULERS" is "1"
    And a "mysql" database
    When I query "select json_length(?) as n" with a JSON list of 6000000 numbers, and no scheduler stops for 50 ms
    Then the result is:
      | n           |
      | Int 6000000 |
    And another task keeps running during "select repeat('y', 10000000) as s", with gaps under 150 milliseconds
