Feature: Migrations
  Migrate.up applies the migrations that a database has not seen, in order, each in its own transaction, and records
  each in a history table with the checksum of its sql. In a step table, a migration is its version, its name and its
  sql: statements separated by `;`, or `code:` and one statement that a function migration runs. The result of a run
  is the versions it applied, one row each.
  A scenario on a server names its own history table and drops it at the end, and the tables of the migrations are
  temporary, so nothing is left behind. The checks of the history do not depend on the database: they run on sqlite.

  Scenario Outline: Migrations are applied in order, recorded, and not applied again on <adapter>
    Given a "<adapter>" database
    And I execute "drop table if exists mig_apply_<adapter>"
    When I migrate the table "mig_apply_<adapter>" with:
      | version | name  | sql                                                                                  |
      | 1       | users | create temporary table users (id integer not null, name varchar(50) not null)         |
      | 2       | seed  | insert into users values (1, 'ana'); insert into users values (2, 'bob') |
    Then the result is:
      | version |
      | Int 1   |
      | Int 2   |
    When I migrate the table "mig_apply_<adapter>" with:
      | version | name  | sql                                                                                  |
      | 1       | users | create temporary table users (id integer not null, name varchar(50) not null)         |
      | 2       | seed  | insert into users values (1, 'ana'); insert into users values (2, 'bob') |
    Then the result is:
      | version |
    And the query "select name from users order by id" returns:
      | name     |
      | Text ana |
      | Text bob |
    And the query "select version, name from mig_apply_<adapter> order by version" returns:
      | version | name       |
      | Int 1   | Text users |
      | Int 2   | Text seed  |
    And the query "drop table mig_apply_<adapter>" returns:
      | x |

    Examples:
      | adapter  |
      | sqlite   |
      | postgres |
      | mysql    |

  Scenario Outline: A migration that fails is rolled back and stops the run, and the ones before it stay on <adapter>
    Given a "<adapter>" database
    And I execute "drop table if exists mig_fail_<adapter>"
    And I execute "create temporary table users (id integer not null)"
    When I migrate the table "mig_fail_<adapter>" with:
      | version | name   | sql                                                                    |
      | 1       | first  | insert into users (id) values (1)                                      |
      | 2       | broken | insert into users (id) values (2); insert into no_such_table values (1) |
      | 3       | after  | insert into users (id) values (3)                                      |
    Then it fails with "migrate error: migration 2 (broken) failed: "
    And the query "select id from users order by id" returns:
      | id    |
      | Int 1 |
    And the query "select version from mig_fail_<adapter>" returns:
      | version |
      | Int 1   |
    And the query "drop table mig_fail_<adapter>" returns:
      | x |

    Examples:
      | adapter  |
      | sqlite   |
      | postgres |
      | mysql    |

  Scenario: A new migration is applied after the ones already recorded on sqlite
    Given a "sqlite" database
    And I migrate with:
      | version | name | sql                              |
      | 1       | a    | create table a (id integer)      |
    And the result is:
      | version |
      | Int 1   |
    When I migrate with:
      | version | name | sql                              |
      | 1       | a    | create table a (id integer)      |
      | 5       | b    | create table b (id integer)      |
    Then the result is:
      | version |
      | Int 5   |

  Scenario: A function migration runs in its transaction and is recorded on sqlite
    Given a "sqlite" database
    When I migrate with:
      | version | name   | sql                                         |
      | 1       | table  | create table notes (body text not null)     |
      | 2       | seeded | code:insert into notes (body) values ('hi') |
    Then the result is:
      | version |
      | Int 1   |
      | Int 2   |
    And the query "select body from notes" returns:
      | body    |
      | Text hi |

  Scenario: A migration whose sql changed after it was applied is refused on sqlite
    Given a "sqlite" database
    And I migrate with:
      | version | name  | sql                         |
      | 1       | users | create table users (id int) |
    And the result is:
      | version |
      | Int 1   |
    When I migrate with:
      | version | name  | sql                                      |
      | 1       | users | create table users (id int, name text)   |
    Then it fails with exactly "migrate error: migration 1 (users) was changed after it was applied"

  Scenario: A migration renamed after it was applied is refused on sqlite
    Given a "sqlite" database
    And I migrate with:
      | version | name  | sql                         |
      | 1       | users | create table users (id int) |
    And the result is:
      | version |
      | Int 1   |
    When I migrate with:
      | version | name   | sql                         |
      | 1       | people | create table users (id int) |
    Then it fails with "migrate error: migration 1 (people) was renamed after it was applied, it was (users)"

  Scenario: A migration that is applied but no longer in the list is refused on sqlite
    Given a "sqlite" database
    And I migrate with:
      | version | name | sql                        |
      | 1       | a    | create table a (id int)    |
      | 2       | b    | create table b (id int)    |
    And the result is:
      | version |
      | Int 1   |
      | Int 2   |
    When I migrate with:
      | version | name | sql                        |
      | 1       | a    | create table a (id int)    |
    Then it fails with exactly "migrate error: migration 2 (b) is applied but not in the list"

  Scenario: A pending migration older than an applied one is refused, and nothing runs on sqlite
    Given a "sqlite" database
    And I migrate with:
      | version | name | sql                        |
      | 1       | a    | create table a (id int)    |
      | 3       | c    | create table c (id int)    |
    And the result is:
      | version |
      | Int 1   |
      | Int 3   |
    When I migrate with:
      | version | name | sql                        |
      | 1       | a    | create table a (id int)    |
      | 2       | b    | create table b (id int)    |
      | 3       | c    | create table c (id int)    |
    Then it fails with "migrate error: migration 2 (b) is older than the applied migration 3, so it would"

  Scenario Outline: A list that does not ascend, or an unsafe table name, is refused before it runs on sqlite
    Given a "sqlite" database
    When I migrate the table "<table>" with:
      | version | name | sql                     |
      | <first> | a    | create table a (id int) |
      | <next>  | b    | create table b (id int) |
    Then it fails with "<failure>"

    Examples:
      | table      | first | next | failure                                                     |
      | history    | 2     | 1    | migrate error: migration 1 (b) must have a version above 2  |
      | history    | 1     | 1    | migrate error: migration 1 (b) must have a version above 1  |
      | history    | 0     | 1    | migrate error: migration 0 (a) must have a version above 0  |
      | bad-name   | 1     | 2    | migrate error: the table name must be letters, digits and _ |
      | 1history   | 1     | 2    | migrate error: the table name must be letters, digits and _ |

  Scenario: A migration without a name is refused on sqlite
    Given a "sqlite" database
    When I migrate with:
      | version | name | sql                     |
      | 1       |      | create table a (id int) |
    Then it fails with "migrate error: migration 1 needs a name of 1 to 255 bytes"
