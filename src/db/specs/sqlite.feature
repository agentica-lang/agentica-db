Feature: SQLite
  What only the SQLite adapter promises. SQLite has no boolean (a Bool is stored as 0 or 1, see values.feature), and
  a NaN is stored as NULL.
  In a step text, [NUL], [FF] and [VT] stand for characters a text cannot hold, and [SCRATCH] is a folder of the
  scenario under tmp/ (it is emptied when the next scenario starts).

  Scenario: A NaN is stored as null on sqlite
    Given a "sqlite" database
    When I execute "create temp table t (v)"
    And I execute "insert into t values (?)" with:
      | value     |
      | Float NaN |
    Then the query "select v from t" returns:
      | v    |
      | Null |

  Scenario: A text with an embedded NUL is written and read back whole on sqlite
    Given a "sqlite" database
    And I execute "create temp table t (s text)"
    And I execute "insert into t values (?)" with:
      | value        |
      | Text a[NUL]b |
    Then the query "select s, length(cast(s as blob)) as n from t" returns:
      | s            | n     |
      | Text a[NUL]b | Int 3 |

  Scenario: A form feed is a space and a vertical tab is refused on sqlite
    Given a "sqlite" database
    When I execute "[FF]"
    Then it fails with exactly "sqlite error: the sql has no statement"
    When I execute "[VT]"
    Then it fails with exactly 'sqlite error 1: unrecognized token: "[VT]"'

  Scenario: Using a closed connection ends only the task that used it on sqlite
    Given a "sqlite" database
    When I close the database
    And another task executes "select 1"
    Then it fails mentioning "RUNTIME-NATIVE-CLOSED"

  Scenario: A file database keeps its rows after it is closed and opened again on sqlite
    Given a "sqlite" database
    When I open "sqlite:[SCRATCH]/file.db"
    And I execute "create table t (x integer)"
    And I execute "insert into t values (?)" with:
      | value  |
      | Int 42 |
    And I close the database
    And I open "sqlite:[SCRATCH]/file.db"
    Then the query "select x from t" returns:
      | x      |
      | Int 42 |

  Scenario: A statement is finalized when a row fails, so the table can be dropped on sqlite
    Given a "sqlite" database
    And I execute "create table t (x integer)"
    And I execute "insert into t values (1), (2), (3), (4)"
    # abs of the smallest int is an integer overflow, raised on the third row.
    When I query "select case when x = 3 then abs(-9223372036854775807 - 1) else x end as y from t order by x"
    Then it fails with "sqlite error 1: "
    When I execute "drop table t"
    Then the changed row count is 0

  Scenario: Statements that are refused before they run are finalized, so the table can be dropped on sqlite
    Given a "sqlite" database
    And I execute "create table t (a)"
    When I query "select * from t; select 2"
    Then it fails with "sqlite error: "
    When I query "-- nothing"
    Then it fails with "sqlite error: "
    When I execute "select * from t; selec 2"
    Then it fails with "sqlite error: "
    When I query "select * from t"
    Then it succeeds
    When I execute "drop table t"
    Then the changed row count is 0

  Scenario: A file database opens in WAL mode with foreign keys on on sqlite
    Given a "sqlite" database
    When I open "sqlite:[SCRATCH]/web.db"
    Then the query "select 1 as ok" returns:
      | ok    |
      | Int 1 |
    And the query "pragma journal_mode" returns:
      | journal_mode |
      | Text wal     |
    And the query "pragma foreign_keys" returns:
      | foreign_keys |
      | Int 1        |

  Scenario: The url parameters give SQLite's own behavior back on sqlite
    Given a "sqlite" database
    When I open "sqlite:[SCRATCH]/plain.db?journal_mode=delete&foreign_keys=off"
    Then the query "pragma journal_mode" returns:
      | journal_mode |
      | Text delete  |
    And the query "pragma foreign_keys" returns:
      | foreign_keys |
      | Int 0        |

  Scenario: A foreign key is checked by default on sqlite
    Given a "sqlite" database
    And I execute "create table parents (id integer primary key)"
    And I execute "create table children (parent integer references parents (id))"
    When I execute "insert into children values (7)"
    Then it fails with "sqlite error 19: FOREIGN KEY constraint failed"

  Scenario: A url parameter that is not understood is an error on sqlite
    Given a "sqlite" database
    When I open "sqlite::memory:?color=red"
    Then it fails with "sqlite error: unknown url parameter color, expected"

  Scenario: A read-only file opens by default, and an explicit journal_mode=wal on it is an error on sqlite
    Given a "sqlite" database
    When I open "sqlite:[SCRATCH]/readonly.db?journal_mode=delete"
    And I execute "create table t (x integer)"
    And I execute "insert into t values (1)"
    And I close the database
    And I make the file "[SCRATCH]/readonly.db" read-only
    And I open "sqlite:[SCRATCH]/readonly.db"
    Then the query "select x from t" returns:
      | x     |
      | Int 1 |
    When I open "sqlite:[SCRATCH]/readonly.db?journal_mode=wal"
    Then it fails with "sqlite error 8: "
    When I make the file "[SCRATCH]/readonly.db" writable
    Then it succeeds

  Scenario: A file: name is a SQLite URI that goes to SQLite as it is, and the defaults still apply on sqlite
    Given a "sqlite" database
    When I open "sqlite:[SCRATCH]/uri.db?journal_mode=delete"
    And I execute "create table t (x integer)"
    And I close the database
    And I open "sqlite:file:[SCRATCH]/uri.db?mode=ro"
    Then the query "pragma foreign_keys" returns:
      | foreign_keys |
      | Int 1        |
    When I execute "insert into t values (1)"
    Then it fails with "sqlite error 8: "

  Scenario: A file: name that rules WAL out keeps the mode it has, and the defaults still apply on sqlite
    Given a "sqlite" database
    When I open "sqlite:[SCRATCH]/immutable.db?journal_mode=delete"
    And I execute "create table t (x integer)"
    And I close the database
    And I open "sqlite:file:[SCRATCH]/immutable.db?immutable=1"
    Then the query "pragma journal_mode" returns:
      | journal_mode |
      | Text delete  |
    And the query "pragma foreign_keys" returns:
      | foreign_keys |
      | Int 1        |

  Scenario: A database opened with fts5=required can search text on sqlite
    Given a "sqlite" database
    When I open "sqlite::memory:?fts5=required"
    And I execute "create virtual table notes using fts5(body, tokenize = porter)"
    And I execute "insert into notes values ('Running quickly'), ('sleeping all day')"
    Then the query "select body from notes where notes match 'runs'" returns:
      | body                 |
      | Text Running quickly |

  # The wait for a lock is made by the adapter, which sleeps between tries, and not by SQLite, whose busy handler
  # would sleep on a thread of the compute pool: the pool has one thread per scheduler, so with few schedulers the
  # waiting writers filled it and the one that held the lock could not finish. AGENTICA_SCHEDULERS is read by the
  # program that the scenario starts, so its step comes first. In a shared cache the lock is a table lock
  # (SQLITE_LOCKED), which the adapter waits for in the same way; the memory database lives while the connection of
  # the scenario is open.
  Scenario Outline: Tasks that write in transactions at once all succeed, <name>, <schedulers> scheduler(s) on sqlite
    Given the environment variable "AGENTICA_SCHEDULERS" is "<schedulers>"
    And a "sqlite" database
    When I open "sqlite:<database>"
    And I execute "create table notes (id integer primary key, writer integer not null)"
    And 6 tasks each run these statements in a transaction on "sqlite:<database>":
      | sql                                   |
      | insert into notes (writer) values (1) |
      | insert into notes (writer) values (2) |
      | insert into notes (writer) values (3) |
    Then it succeeds
    And the query "select count(*) as n from notes" returns:
      | n      |
      | Int 18 |

    Examples:
      | name         | schedulers | database                             |
      | file         | 1          | [SCRATCH]/writers.db                 |
      | file         | 2          | [SCRATCH]/writers.db                 |
      | shared cache | 1          | file:shared?mode=memory&cache=shared |

  # A lock held by a connection that does not let go: the writer tries again until its busy_timeout is over, then
  # fails with `database is locked`. A timeout of 0 does not wait.
  Scenario Outline: A writer that cannot get a held lock fails after its busy_timeout of <ms> ms on sqlite
    Given a "sqlite" database
    When I open "sqlite:[SCRATCH]/a.db"
    And I execute "create table t (x integer)"
    And I execute "begin immediate"
    And another task on "sqlite:[SCRATCH]/a.db?busy_timeout=<ms>" executes "insert into t values (1)" and waits <ms> ms
    Then it fails with "sqlite error 5: database is locked"

    Examples:
      | ms  |
      | 0   |
      | 300 |

  # In a rollback journal the writer gets its lock at once but its commit waits for the reader, which makes SQLite run
  # the statement again: the rows of the first run must not be kept. The step checks that the task was still waiting
  # when the reader committed.
  Scenario: A statement that writes and returns rows gives them once after it waited for a lock on sqlite
    Given a "sqlite" database
    When I open "sqlite:[SCRATCH]/returning.db?journal_mode=delete"
    And I execute "create table t (x integer)"
    And I execute "begin"
    And I query "select count(*) as n from t"
    And another task on "sqlite:[SCRATCH]/returning.db?journal_mode=delete" queries "insert into t values (7), (8) returning x" while I commit after 200 ms
    Then the result is:
      | x     |
      | Int 7 |
      | Int 8 |
    And the query "select count(*) as n from t" returns:
      | n     |
      | Int 2 |

  # A read does not need to be run again: it waits for the lock and gives all its rows.
  Scenario: A read that waits for a lock gives its rows on sqlite
    Given a "sqlite" database
    When I open "sqlite:[SCRATCH]/reading.db?journal_mode=delete"
    And I execute "create table t (x integer)"
    And I execute "insert into t values (1), (2), (3)"
    And another task on "sqlite:[SCRATCH]/reading.db?journal_mode=delete" holds the write lock for 300 ms while I query "select x from t order by x"
    Then the result is:
      | x     |
      | Int 1 |
      | Int 2 |
      | Int 3 |

  # A deferred transaction that has read holds a read lock. A write that another connection blocks cannot be waited
  # for: that connection commits only after this one lets go of its read lock, so both would wait for the busy_timeout.
  # SQLite does not wait here either, and the write fails at once. The other connection commits when this one ends
  # its transaction. `Db.transaction` begins with BEGIN IMMEDIATE and never gets here.
  # This needs SQLite 3.34 or later (`sqlite3_txn_state`): the adapter waits as before with an older library, and this
  # scenario then fails. The stall exists only in a rollback journal (`journal_mode=delete`), which is why it uses one.
  Scenario: A write in a transaction that has read fails at once and lets the other commit on sqlite
    Given a "sqlite" database
    When I open "sqlite:[SCRATCH]/deferred.db?journal_mode=delete"
    And I execute "create table t (x integer)"
    And I execute "begin"
    And I query "select count(*) as n from t"
    And another task on "sqlite:[SCRATCH]/deferred.db?journal_mode=delete" commits "insert into t values (1)" while I execute "insert into t values (2)" once it waits
    Then it fails with "sqlite error 5: database is locked"
    And the query "select count(*) as n from t" returns:
      | n     |
      | Int 1 |

  # SQLite rolls back the whole transaction when it interrupts a write inside one, so the earlier write is gone too.
  Scenario: A write that times out inside a transaction rolls the transaction back on sqlite
    Given a "sqlite" database
    When I open "sqlite::memory:?timeout_ms=200"
    And I execute "create table t (x integer)"
    And I execute "begin"
    And I execute "insert into t values (1)"
    And I execute "with recursive c(x) as (select 1 union all select x + 1 from c limit 400000000) insert into t select x from c"
    Then it fails with a timeout
    And the connection is not in a transaction
    And the query "select count(*) as n from t" returns:
      | n     |
      | Int 0 |

  # The wait for a lock ends with the deadline too, not only a running statement: the lock is held for 1500 ms and
  # the busy_timeout is 5000 ms.
  Scenario: The wait for a lock ends at the timeout on sqlite
    Given a "sqlite" database
    When I open "sqlite:[SCRATCH]/deadline.db?journal_mode=delete&timeout_ms=300"
    And I execute "create table t (x integer)"
    And another task on "sqlite:[SCRATCH]/deadline.db?journal_mode=delete" holds the write lock for 1500 ms while I query "select x from t"
    Then it fails with a timeout

  # SQLite does all the work of a write with RETURNING in the first step, and rolls it back when it is interrupted
  # while the rows are read; the adapter must not return early on a later step and leave the write behind.
  Scenario: A write with RETURNING that times out is rolled back, in autocommit and in a transaction on sqlite
    Given a "sqlite" database
    When I open "sqlite::memory:?timeout_ms=400"
    And I execute "create table t (x integer)"
    And I query "insert into t(x) with recursive c(x) as (select 1 union all select x + 1 from c limit 300000) select x from c returning x"
    Then it fails with a timeout
    And the connection is not in a transaction
    And the query "select count(*) as n from t" returns:
      | n     |
      | Int 0 |
    When I execute "begin"
    And I query "insert into t(x) with recursive c(x) as (select 1 union all select x + 1 from c limit 300000) select x from c returning x"
    Then it fails with a timeout
    And the connection is not in a transaction
    And the query "select count(*) as n from t" returns:
      | n     |
      | Int 0 |

  # SQLite has rolled the transaction back by itself, so Db.transaction sends no ROLLBACK that would fail and bury the
  # timeout in a "no transaction is active" message.
  Scenario: A write that times out inside Db.transaction gives the timeout alone on sqlite
    Given a "sqlite" database
    When I open "sqlite::memory:?timeout_ms=200"
    And I execute "create table t (x integer)"
    And I run these statements in a transaction:
      | sql                                                                                                    |
      | insert into t values (1)                                                                               |
      | with recursive c(x) as (select 1 union all select x + 1 from c limit 400000000) insert into t select x from c |
    Then it fails with a timeout
    And the failure never shows "rollback failed"
    And the query "select count(*) as n from t" returns:
      | n     |
      | Int 0 |

  # The connection keeps its prepared statements by their sql (statement_cache, 64 by default).
  Scenario: A statement that runs again binds its own parameters on sqlite
    Given a "sqlite" database
    And I execute "create table t (id integer primary key, name text)"
    And I execute "insert into t values (?, ?)" with:
      | value    |
      | Int 1    |
      | Text ann |
    And I execute "insert into t values (?, ?)" with:
      | value    |
      | Int 2    |
      | Text bob |
    Then the changed row count is 1
    When I query "select name from t where id = ?" with:
      | value |
      | Int 2 |
    Then the result is:
      | name     |
      | Text bob |
    When I query "select name from t where id = ?" with:
      | value |
      | Int 1 |
    Then the result is:
      | name     |
      | Text ann |
    When I query "select name from t where id = ?" with:
      | value |
      | Int 3 |
    Then the result is:
      | name |

  Scenario: A statement that failed in a step is ready again on sqlite
    Given a "sqlite" database
    When I query "select abs(?) as v" with:
      | value                    |
      | Int -9223372036854775808 |
    Then it fails with "sqlite error 1: "
    When I query "select abs(?) as v" with:
      | value  |
      | Int -5 |
    Then the result is:
      | v     |
      | Int 5 |
    When I query "select abs(?) as v" with:
      | value                    |
      | Int -9223372036854775808 |
    Then it fails with "sqlite error 1: "
    And the connection is healthy

  Scenario: A statement that runs again sees a changed schema on sqlite
    Given a "sqlite" database
    And I execute "create table t (a integer)"
    And I execute "insert into t values (1)"
    Then the query "select * from t" returns:
      | a     |
      | Int 1 |
    When I execute "alter table t add column b integer default 7"
    Then the query "select * from t" returns:
      | a     | b     |
      | Int 1 | Int 7 |
    When I execute "alter table t rename column b to c"
    Then the query "select * from t" returns:
      | a     | c     |
      | Int 1 | Int 7 |
    When I execute "drop table t"
    And I execute "create table t (z text)"
    And I execute "insert into t values ('x')"
    Then the query "select * from t" returns:
      | z      |
      | Text x |
    When I execute "drop table t"
    And I query "select * from t"
    Then it fails with "sqlite error 1: no such table: t"

  Scenario Outline: A cache of <limit> statements gives the same rows when more statements than that run on sqlite
    Given a "sqlite" database
    When I open "sqlite::memory:?statement_cache=<limit>"
    Then the query "select 1 as v" returns:
      | v     |
      | Int 1 |
    And the query "select 2 as v" returns:
      | v     |
      | Int 2 |
    And the query "select 3 as v" returns:
      | v     |
      | Int 3 |
    And the query "select 1 as v" returns:
      | v     |
      | Int 1 |
    And the query "select 3 as v" returns:
      | v     |
      | Int 3 |
    And the query "select 2 as v" returns:
      | v     |
      | Int 2 |

    Examples:
      | limit |
      | 0     |
      | 1     |
      | 2     |

  Scenario: Statements of a connection that runs transactions again behave as before on sqlite
    Given a "sqlite" database
    And I execute "create table t (x integer)"
    When I run these statements in a transaction:
      | sql                      |
      | insert into t values (1) |
    Then it succeeds
    When I run these statements in a transaction:
      | sql                            |
      | insert into t values (2)       |
      | insert into missing values (1) |
    Then it fails with "sqlite error 1: no such table: missing"
    When I run these statements in a transaction:
      | sql                      |
      | insert into t values (3) |
    Then it succeeds
    And the query "select x from t order by x" returns:
      | x     |
      | Int 1 |
      | Int 3 |

  # A connection that is still open in WAL mode keeps the database from leaving it, so the second open shows whether
  # close finalized the statements: SQLite keeps a closed connection open for as long as one is left.
  Scenario: Closing a connection finalizes its cached statements on sqlite
    Given a "sqlite" database
    When I open "sqlite:[SCRATCH]/cached.db"
    And I execute "create table t (x integer)"
    And I execute "insert into t values (1)"
    Then the query "select x from t" returns:
      | x     |
      | Int 1 |
    When I close the database
    And I open "sqlite:[SCRATCH]/cached.db?journal_mode=delete&busy_timeout=300"
    Then the query "pragma journal_mode" returns:
      | journal_mode |
      | Text delete  |

  Scenario: Two tasks that run the same sql on one connection at once both get its rows on sqlite
    Given a "sqlite" database
    When two tasks query "[WORK]" on the connection at once
    Then the result is:
      | n     |
      | Int 1 |
    When two tasks query "[WORK]" on the connection at once
    Then the result is:
      | n     |
      | Int 1 |
    And the connection is healthy
