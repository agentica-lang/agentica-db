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

  Scenario: A file database opens in WAL mode with foreign keys on and a 5 second busy timeout on sqlite
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
    And the query "pragma busy_timeout" returns:
      | timeout  |
      | Int 5000 |

  Scenario: The url parameters give SQLite's own behavior back on sqlite
    Given a "sqlite" database
    When I open "sqlite:[SCRATCH]/plain.db?journal_mode=delete&foreign_keys=off&busy_timeout=250"
    Then the query "pragma journal_mode" returns:
      | journal_mode |
      | Text delete  |
    And the query "pragma foreign_keys" returns:
      | foreign_keys |
      | Int 0        |
    And the query "pragma busy_timeout" returns:
      | timeout |
      | Int 250 |

  Scenario: A foreign key is checked by default on sqlite
    Given a "sqlite" database
    And I execute "create table parents (id integer primary key)"
    And I execute "create table children (parent integer references parents (id))"
    When I execute "insert into children values (7)"
    Then it fails with "sqlite error 19: FOREIGN KEY constraint failed"

  Scenario Outline: A url parameter that is not understood is an error on sqlite: <parameter>
    Given a "sqlite" database
    When I open "sqlite::memory:?<parameter>"
    Then it fails with "<failure>"

    Examples:
      | parameter                | failure                                                      |
      | journal_mode=fast        | sqlite error: the url parameter journal_mode has a value     |
      | foreign_keys=1           | sqlite error: the url parameter foreign_keys has a value     |
      | fts5=yes                 | sqlite error: the url parameter fts5 has a value             |
      | busy_timeout=soon        | sqlite error: the url busy_timeout is not a number           |
      | busy_timeout=            | sqlite error: the url busy_timeout is not a number           |
      | busy_timeout=99999999999 | sqlite error: the url busy_timeout is not a number           |
      | color=red                | sqlite error: unknown url parameter color, expected          |

  Scenario: A database opened with fts5=required can search text on sqlite
    Given a "sqlite" database
    When I open "sqlite::memory:?fts5=required"
    And I execute "create virtual table notes using fts5(body, tokenize = porter)"
    And I execute "insert into notes values ('Running quickly'), ('sleeping all day')"
    Then the query "select body from notes where notes match 'runs'" returns:
      | body                 |
      | Text Running quickly |
