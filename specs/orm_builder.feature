Feature: Orm builder
  A query starts from a schema, takes conditions, an order, a limit and an offset, and ends in a read (`all`, `one`,
  `count`) or a write (`update_all`, `delete_all`). A column of the query must be a column of the schema, and a value
  the kind of its column, or the query fails when it ends, before any sql runs. The scenarios use the `people` table
  and the struct Person of the driver, as in orm.feature. Each row of the table of a query is a step of the builder:
  `where_eq`, `order_by`, `order_by_desc`, `limit`, `offset` (column or number, then a typed cell), `where_in` and
  `where` (a column or an sql, then typed cells apart by `; `), and `changes` (the Json of `update_all`). A result
  shows the persons read; a count shows in the changed row count.

  Scenario Outline: A query filters, orders and reads the rows on <adapter>
    Given a "<adapter>" database
    And I execute "create temporary table people (id integer primary key, name varchar(50) not null, age integer, admin boolean not null, score double precision not null)"
    And I execute "insert into people (id, name, age, admin, score) values (1, 'ana', 31, true, 1.5), (2, 'bob', null, false, 2.0), (3, 'cy', 9, true, 0.25), (4, 'dee', 40, true, 3.0)"
    When I run the people query ending in "all":
      | step          | argument | value     |
      | where_eq      | admin    | Bool true |
      | where         | age > ?  | Int 10    |
      | order_by_desc | score    |           |
    Then the result is:
      | id    | name     | age    | admin     | score     |
      | Int 4 | Text dee | Int 40 | Bool true | Float 3.0 |
      | Int 1 | Text ana | Int 31 | Bool true | Float 1.5 |
    When I run the people query ending in "all":
      | step     | argument | value               |
      | where_in | id       | Int 1; Int 3; Int 9 |
      | order_by | name     |                     |
    Then the result has 2 rows, the last being:
      | id    | name    | age   | admin     | score      |
      | Int 3 | Text cy | Int 9 | Bool true | Float 0.25 |
    When I run the people query ending in "all":
      | step     | argument | value |
      | where_in | id       |       |
    Then the result is:
      | id |
    When I run the people query ending in "all":
      | step     | argument | value |
      | where_eq | age      | Null  |
    Then the result is:
      | id    | name     | age  | admin      | score     |
      | Int 2 | Text bob | Null | Bool false | Float 2.0 |

    Examples:
      | adapter  |
      | sqlite   |
      | postgres |
      | mysql    |

  Scenario Outline: A query pages with limit and offset, and one gives the first row or none on <adapter>
    Given a "<adapter>" database
    And I execute "create temporary table people (id integer primary key, name varchar(50) not null, age integer, admin boolean not null, score double precision not null)"
    And I execute "insert into people (id, name, age, admin, score) values (1, 'ana', 31, true, 1.5), (2, 'bob', null, false, 2.0), (3, 'cy', 9, true, 0.25), (4, 'dee', 40, true, 3.0)"
    When I run the people query ending in "all":
      | step     | argument | value |
      | order_by | id       |       |
      | offset   | 1        |       |
      | limit    | 2        |       |
    Then the result has 2 rows, the last being:
      | id    | name    | age   | admin     | score      |
      | Int 3 | Text cy | Int 9 | Bool true | Float 0.25 |
    When I run the people query ending in "all":
      | step     | argument | value |
      | order_by | id       |       |
      | offset   | 3        |       |
    Then the result is:
      | id    | name     | age    | admin     | score     |
      | Int 4 | Text dee | Int 40 | Bool true | Float 3.0 |
    When I run the people query ending in "one":
      | step          | argument | value |
      | order_by_desc | score    |       |
    Then the result is:
      | id    | name     | age    | admin     | score     |
      | Int 4 | Text dee | Int 40 | Bool true | Float 3.0 |
    When I run the people query ending in "one":
      | step     | argument | value    |
      | where_eq | name     | Text zed |
    Then the result is:
      | id |
    When I run the people query ending in "one":
      | step  | argument | value |
      | limit | 0        |       |
    Then the result is:
      | id |
    When I run the people query ending in "all":
      | step     | argument | value  |
      | where    | age > ?  | Int 10 |
      | order_by | id       |        |
      | offset   | 1        |        |
      | limit    | 1        |        |
    Then the result is:
      | id    | name     | age    | admin     | score     |
      | Int 4 | Text dee | Int 40 | Bool true | Float 3.0 |
    When I run the people query ending in "all":
      | step   | argument | value |
      | offset | 1        |       |
      | limit  | 0        |       |
    Then the result is:
      | id |

    Examples:
      | adapter  |
      | sqlite   |
      | postgres |
      | mysql    |

  Scenario Outline: A find gives Some row or None, and refuses a key of another kind on <adapter>
    Given a "<adapter>" database
    And I execute "create temporary table people (id integer primary key, name varchar(50) not null, age integer, admin boolean not null, score double precision not null)"
    And I execute "insert into people (id, name, age, admin, score) values (1, 'ana', 31, true, 1.5)"
    When I find the person with the key "Int 1"
    Then the result is:
      | id    | name     | age    | admin     | score     |
      | Int 1 | Text ana | Int 31 | Bool true | Float 1.5 |
    When I find the person with the key "Int 9"
    Then the result is:
      | id |
    When I find the person with the key "Text 1"
    Then it fails with exactly "orm error bad_request: people: the key id has type Int, not Text"

    Examples:
      | adapter  |
      | sqlite   |
      | postgres |
      | mysql    |

  Scenario Outline: A count, an update_all and a delete_all work on the rows a query selects on <adapter>
    Given a "<adapter>" database
    And I execute "create temporary table people (id integer primary key, name varchar(50) not null, age integer, admin boolean not null, score double precision not null)"
    And I execute "insert into people (id, name, age, admin, score) values (1, 'ana', 31, true, 1.5), (2, 'bob', null, false, 2.0), (3, 'cy', 9, true, 0.25), (4, 'dee', 40, true, 3.0)"
    When I run the people query ending in "count":
      | step     | argument | value     |
      | where_eq | admin    | Bool true |
      | limit    | 1        |           |
    Then the changed row count is 3
    When I run the people query ending in "update_all":
      | step     | argument      | value     |
      | where_eq | admin         | Bool true |
      | where    | score < ?     | Float 2.0 |
      | changes  | {"age": null} |           |
    Then the changed row count is 2
    When I run the people query ending in "delete_all":
      | step  | argument | value    |
      | where | name = ? | Text bob |
    Then the changed row count is 1
    And the query "select id, age from people order by id" returns:
      | id    | age    |
      | Int 1 | Null   |
      | Int 3 | Null   |
      | Int 4 | Int 40 |
    When I run the people query ending in "delete_all":
      | step  | argument | value |
      | where | 1 = 1    |       |
    Then the changed row count is 3
    And the query "select id from people" returns:
      | id |

    Examples:
      | adapter  |
      | sqlite   |
      | postgres |
      | mysql    |

  Scenario Outline: A query with a bad column or a value of another kind fails when it ends on <adapter>
    Given a "<adapter>" database
    And I execute "create temporary table people (id integer primary key, name varchar(50) not null, age integer, admin boolean not null, score double precision not null)"
    And I execute "insert into people (id, name, age, admin, score) values (1, 'ana', 31, true, 1.5)"
    When I run the people query ending in "all":
      | step     | argument | value  |
      | where_eq | nickname | Text x |
    Then it fails with exactly "orm error bad_request: people: nickname is not a column of the table"
    When I run the people query ending in "all":
      | step     | argument                | value |
      | order_by | name; drop table people |       |
    Then it fails with exactly "orm error bad_request: people: name; drop table people is not a column of the table"
    When I run the people query ending in "all":
      | step     | argument | value  |
      | where_eq | age      | Text x |
    Then it fails with exactly "orm error bad_request: people: the column age has type JsonField[Int], not Text"
    When I run the people query ending in "all":
      | step     | argument | value         |
      | where_in | age      | Int 1; Text x |
    Then it fails with exactly "orm error bad_request: people: the column age has type JsonField[Int], not Text"
    When I run the people query ending in "all":
      | step  | argument | value |
      | limit | -1       |       |
    Then it fails with exactly "orm error bad_request: people: limit must not be negative"
    When I run the people query ending in "delete_all":
      | step  | argument | value |
      | limit | 1        |       |
    Then it fails with exactly "orm error bad_request: people: delete_all cannot use order_by, limit or offset"
    When I run the people query ending in "update_all":
      | step     | argument        | value     |
      | where_eq | admin           | Bool true |
      | changes  | {"nickname": 1} |           |
    Then it fails with exactly "orm error bad_request: people: the changes have a key that is not a column"
    When I run the people query ending in "all":
      | step     | argument | value       |
      | where_in | age      | Int 1; Null |
    Then it fails with exactly "orm error bad_request: people: where_in takes no Null item, use where_eq(column, Null)"
    When I run the people query ending in "all":
      | step     | argument | value |
      | where_eq | name     | Null  |
    Then it fails with exactly "orm error bad_request: people: the column name has type String, not Null"
    When I run the people query ending in "all":
      | step     | argument | value     |
      | where_eq | score    | Float NaN |
    Then it fails with exactly "orm error bad_request: people: score: not a finite Float"
    When I run the people query ending in "all":
      | step     | argument | value                     |
      | where_in | score    | Float 1.0; Float Infinity |
    Then it fails with exactly "orm error bad_request: people: score: not a finite Float"
    When I run the people query ending in "update_all":
      | step    | argument   | value |
      | where   | 1 = 1      |       |
      | offset  | 1          |       |
      | changes | {"age": 5} |       |
    Then it fails with exactly "orm error bad_request: people: update_all cannot use order_by, limit or offset"
    When I run the people query ending in "update_all":
      | step     | argument   | value |
      | where    | 1 = 1      |       |
      | order_by | id         |       |
      | changes  | {"age": 5} |       |
    Then it fails with exactly "orm error bad_request: people: update_all cannot use order_by, limit or offset"
    When I run the people query ending in "update_all":
      | step    | argument   | value |
      | changes | {"age": 5} |       |
    Then it fails mentioning "update_all needs a condition"
    When I run the people query ending in "delete_all":
      | step | argument | value |
    Then it fails mentioning "delete_all needs a condition"
    And the query "select id, name, age from people" returns:
      | id    | name     | age    |
      | Int 1 | Text ana | Int 31 |

    Examples:
      | adapter  |
      | sqlite   |
      | postgres |
      | mysql    |
