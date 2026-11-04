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
