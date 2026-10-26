Feature: SQLite
  What only the SQLite adapter promises. SQLite has no boolean: a Bool is stored as 0 or 1 and reads back as an Int,
  and a NaN is stored as NULL.

  Scenario: A bool false reads back as the int 0
    Given a "sqlite" database
    When I execute "create temp table t (v)"
    And I execute "insert into t values (?)" with:
      | value      |
      | Bool false |
    Then the query "select v from t" returns:
      | v     |
      | Int 0 |

  Scenario: A NaN is stored as null
    Given a "sqlite" database
    When I execute "create temp table t (v)"
    And I execute "insert into t values (?)" with:
      | value     |
      | Float NaN |
    Then the query "select v from t" returns:
      | v    |
      | Null |

  Scenario: An infinity from the engine is a float
    Given a "sqlite" database
    Then the query "select 9e999 as v" returns:
      | v              |
      | Float Infinity |

  Scenario: A text with an embedded NUL reads back whole
    Given a "sqlite" database
    Then the query "select 'a' || char(0) || 'b' as s" returns:
      | s             |
      | Text a[NUL]b  |

  Scenario: A form feed is a space and a vertical tab is refused
    Given a "sqlite" database
    When I execute "[FF]"
    Then it fails with exactly "sqlite error: the sql has no statement"
    When I execute "[VT]"
    Then it fails with exactly 'sqlite error 1: unrecognized token: "[VT]"'

  Scenario: Using a closed connection ends only the task that used it
    Given a "sqlite" database
    When I close the database
    And another task executes "select 1"
    Then it fails mentioning "RUNTIME-NATIVE-CLOSED"

  Scenario: A file database keeps its rows after it is closed and opened again
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
    When I close the database
    And I remove the files I created

  Scenario: A missing directory fails to open with the SQLite code
    When I open "sqlite:/no/such/dir/x.db"
    Then it fails with exactly "sqlite error 14: unable to open database file"

  Scenario: A statement is finalized when a row fails, so the table can be dropped
    Given a "sqlite" database
    And I execute "create table t (x integer)"
    And I execute "insert into t values (1), (2), (3), (4)"
    # abs of the smallest int is an integer overflow, raised on the third row.
    When I query "select case when x = 3 then abs(-9223372036854775807 - 1) else x end as y from t order by x"
    Then it fails with "sqlite error 1: "
    When I execute "drop table t"
    Then the changed row count is 0

  Scenario: Statements that are refused before they run are finalized, so the table can be dropped
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
