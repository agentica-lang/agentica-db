Feature: Queries and statements
  Db.query gives the rows of a statement, in order and with their columns in order. Db.execute gives the number of
  rows a statement inserted, updated or deleted. Placeholders are always `?`, and the values are bound, never spliced
  into the sql.

  Scenario Outline: Rows come in order, a null is a null and no result is no rows on <adapter>
    Given a "<adapter>" database
    And I execute "create temporary table users (name varchar(50) not null unique, age integer)"
    And I execute "insert into users (name, age) values ('zed', 1), ('amy', 2), ('ana', null)"
    Then the query "select age, name as who, 7 as seven from users order by name desc" returns:
      | age   | who      | seven |
      | Int 1 | Text zed | Int 7 |
      | Null  | Text ana | Int 7 |
      | Int 2 | Text amy | Int 7 |
    And the query "select name from users where age is null" returns:
      | name     |
      | Text ana |
    And the query "create temporary table other (x integer)" returns:
      | x |

    Examples:
      | adapter  |
      | sqlite   |
      | postgres |
      | mysql    |

  Scenario Outline: A big result set comes back whole on <adapter>
    Given a "<adapter>" database
    # One CTE, read four times: MySQL refuses to open a temporary table twice in one statement.
    When I query "with n(x) as (select 0 union all select 1 union all select 2 union all select 3 union all select 4 union all select 5 union all select 6 union all select 7 union all select 8 union all select 9) select a.x + 10 * b.x + 100 * c.x + 1000 * d.x + 1 as x from n a, n b, n c, n d where a.x + 10 * b.x + 100 * c.x + 1000 * d.x + 1 <= ? order by x" with:
      | value    |
      | Int 5000 |
    Then the result has 5000 rows, the last being:
      | x        |
      | Int 5000 |

    Examples:
      | adapter  |
      | sqlite   |
      | postgres |
      | mysql    |

  Scenario Outline: Execute counts the rows a statement changed on <adapter>
    Given a "<adapter>" database
    And I execute "create temporary table users (name varchar(50) not null unique, age integer)"
    When I execute "insert into users (name, age) values ('a', 1)"
    Then the changed row count is 1
    When I execute "insert into users (name, age) values ('b', 1), ('c', 2)"
    Then the changed row count is 2
    When I execute "update users set age = 9 where age = ?" with:
      | value |
      | Int 1 |
    Then the changed row count is 2
    When I execute "delete from users where age = ?" with:
      | value   |
      | Int 100 |
    Then the changed row count is 0
    When I execute "select name from users"
    Then the changed row count is 0
    When I execute "delete from users"
    Then the changed row count is 3

    Examples:
      | adapter  |
      | sqlite   |
      | postgres |
      | mysql    |

  Scenario Outline: Parameters are values, and a question mark in a literal or comment is text on <adapter>
    Given a "<adapter>" database
    And I execute "create temporary table users (name varchar(50) not null unique, age integer)"
    When I execute "insert into users (name) values (?)" with:
      | value                         |
      | Text x'); drop table users;-- |
    And I query "select ? as a, 'it''s ?' as q, /* ? */ ? as b -- ?" with:
      | value  |
      | Text x |
      | Text y |
    Then the result is:
      | a      | q           | b      |
      | Text x | Text it's ? | Text y |
    And the query "select name from users" returns:
      | name                          |
      | Text x'); drop table users;-- |

    Examples:
      | adapter  |
      | sqlite   |
      | postgres |
      | mysql    |

  Scenario Outline: A trailing comment or semicolon is not a second statement on <adapter>
    Given a "<adapter>" database
    Then the query "select 1 as one; -- done" returns:
      | one   |
      | Int 1 |
    And the query "select 1 as one -- done" returns:
      | one   |
      | Int 1 |

    Examples:
      | adapter  |
      | sqlite   |
      | postgres |
      | mysql    |

  Scenario Outline: A result with a repeated column name is an error on <adapter>
    Given a "<adapter>" database
    When I query "select 1 as a, 2 as a"
    Then it fails with exactly "<adapter> error: the result has the column a twice, alias one of them"

    Examples:
      | adapter  |
      | sqlite   |
      | postgres |
      | mysql    |

  Scenario Outline: Other tasks run while a query waits for the server on <adapter>
    Given a "<adapter>" database
    Then another task keeps running during "<sql>", with gaps under 300 milliseconds

    Examples:
      | adapter  | sql                          |
      | postgres | select pg_sleep(0.5)::text as v |
      | mysql    | select sleep(0.5) as v       |
