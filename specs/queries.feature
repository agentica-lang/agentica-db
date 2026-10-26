Feature: Queries and statements
  Db.query gives the rows of a statement, in order and with their columns in order. Db.execute gives the number of
  rows a statement inserted, updated or deleted. Placeholders are always `?`, and the values are bound, never spliced
  into the sql.

  Scenario Outline: A null reads back as null and matches is null on <adapter>
    Given a "<adapter>" database
    And I execute "create temporary table users (name varchar(50) not null unique, age integer)"
    And I execute "insert into users (name, age) values (?, ?)" with:
      | value    |
      | Text ana |
      | Null     |
    And I execute "insert into users (name, age) values (?, ?)" with:
      | value    |
      | Text bob |
      | Int 30   |
    Then the query "select name from users where age is null" returns:
      | name     |
      | Text ana |
    And the query "select age from users where name = 'ana'" returns:
      | age  |
      | Null |

    Examples:
      | adapter  |
      | sqlite   |
      | postgres |
      | mysql    |

  Scenario Outline: Rows come in order with their columns in order on <adapter>
    Given a "<adapter>" database
    And I execute "create temporary table users (name varchar(50) not null unique, age integer)"
    And I execute "insert into users (name, age) values ('zed', 1), ('amy', 2)"
    Then the query "select age, name as who, 7 as seven from users order by name desc" returns:
      | age   | who      | seven |
      | Int 1 | Text zed | Int 7 |
      | Int 2 | Text amy | Int 7 |

    Examples:
      | adapter  |
      | sqlite   |
      | postgres |
      | mysql    |

  Scenario Outline: A statement without a result gives no rows on <adapter>
    Given a "<adapter>" database
    Then the query "create temporary table t (x integer)" returns:
      | x |

    Examples:
      | adapter  |
      | sqlite   |
      | postgres |
      | mysql    |

  Scenario Outline: A big result set comes back whole on <adapter>
    Given a "<adapter>" database
    And I execute "create temporary table n (x integer)"
    And I execute "insert into n values (0), (1), (2), (3), (4), (5), (6), (7), (8), (9)"
    When I query "select a.x + 10 * b.x + 100 * c.x + 1000 * d.x + 1 as x from n a, n b, n c, n d where a.x + 10 * b.x + 100 * c.x + 1000 * d.x + 1 <= ? order by x" with:
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
    When I execute "create temporary table other (x integer)"
    Then the changed row count is 0
    When I execute "delete from users"
    Then the changed row count is 3

    Examples:
      | adapter  |
      | sqlite   |
      | postgres |
      | mysql    |

  Scenario Outline: Parameters are values, never sql on <adapter>
    Given a "<adapter>" database
    And I execute "create temporary table users (name varchar(50) not null unique, age integer)"
    When I execute "insert into users (name) values (?)" with:
      | value                         |
      | Text x'); drop table users;-- |
    Then the query "select name from users" returns:
      | name                          |
      | Text x'); drop table users;-- |

    Examples:
      | adapter  |
      | sqlite   |
      | postgres |
      | mysql    |

  Scenario Outline: Only the first and only statement runs on <adapter>: <sql>
    Given a "<adapter>" database
    When I execute "<sql>"
    Then it fails with exactly "<adapter> error: the sql has more than one statement"

    Examples:
      | adapter  | sql                                              |
      | sqlite   | select 1; select 2                               |
      | sqlite   | select 1; selec 2                                |
      | sqlite   | create temporary table t(a); insert into t values (1) |
      | postgres | select 1; select 2                               |
      | mysql    | select 1; select 2                               |
      | postgres | select 1; selec 2                                |
      | mysql    | select 1; selec 2                                |
      | postgres | create temporary table t(a); insert into t values (1) |
      | mysql    | create temporary table t(a); insert into t values (1) |

  Scenario Outline: A trailing comment or semicolon is not a second statement on <adapter>: <sql>
    Given a "<adapter>" database
    Then the query "<sql>" returns:
      | one   |
      | Int 1 |

    Examples:
      | adapter  | sql                      |
      | sqlite   | select 1 as one -- done  |
      | sqlite   | select 1 as one; -- done |
      | postgres | select 1 as one -- done  |
      | mysql    | select 1 as one -- done  |
      | postgres | select 1 as one; -- done |
      | mysql    | select 1 as one; -- done |

  Scenario Outline: A result with a repeated column name is an error on <adapter>
    Given a "<adapter>" database
    When I query "select 1 as a, 2 as a"
    Then it fails with exactly "<adapter> error: the result has the column a twice, alias one of them"

    Examples:
      | adapter  |
      | sqlite   |
      | postgres |
      | mysql    |
