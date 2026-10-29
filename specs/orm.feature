Feature: Orm
  Orm reads the rows of a query into plain structs, with the schema of a struct (the table, the columns and the
  codec of the struct). The scenarios use a `people` table and the struct Person of the driver:
  id: Int = 0, name: String, age: JsonField[Int], admin: Bool, score: Float. The cells of a result show the fields
  of the structs read: a field that is a JsonField shows its value, Null, or `Text absent` when the query left the
  column out.

  Scenario Outline: A query reads its rows into structs, with NULL and booleans, on <adapter>
    Given a "<adapter>" database
    And I execute "create temporary table people (id integer not null, name varchar(50) not null, age integer, admin boolean not null, score double precision not null)"
    And I execute "insert into people (id, name, age, admin, score) values (1, 'ana', 31, true, 1.5), (2, 'bob', null, false, 2.0), (3, 'cy', 9, true, 0.25)"
    When I read people with "select id, name, age, admin, score from people where id < ? order by id" and:
      | param |
      | Int 3 |
    Then the result is:
      | id    | name     | age    | admin      | score     |
      | Int 1 | Text ana | Int 31 | Bool true  | Float 1.5 |
      | Int 2 | Text bob | Null   | Bool false | Float 2.0 |

    Examples:
      | adapter  |
      | sqlite   |
      | postgres |
      | mysql    |

  Scenario Outline: A column the query leaves out is absent, and an extra column is ignored on <adapter>
    Given a "<adapter>" database
    And I execute "create temporary table people (id integer not null, name varchar(50) not null, age integer, admin boolean not null, score double precision not null)"
    And I execute "insert into people (id, name, age, admin, score) values (1, 'ana', 31, true, 1.5)"
    When I read people with "select id, name, admin, score, 7 as extra from people"
    Then the result is:
      | id    | name     | age         | admin     | score     |
      | Int 1 | Text ana | Text absent | Bool true | Float 1.5 |

    Examples:
      | adapter  |
      | sqlite   |
      | postgres |
      | mysql    |

  Scenario Outline: A row that does not fit the struct fails with the table name on <adapter>
    Given a "<adapter>" database
    And I execute "create temporary table people (id integer not null, name varchar(50) not null, age integer, admin boolean not null, score double precision not null)"
    And I execute "insert into people (id, name, age, admin, score) values (1, 'ana', 31, true, 1.5)"
    When I read people with "select id, name, admin from people"
    Then it fails with exactly "orm error: people: score: missing column"
    When I read people with "select id, null as name, admin, score from people"
    Then it fails with exactly "orm error: people: name: NULL in a field that is not a JsonField"
    When I read people with "select id, name, admin, 'x' as score from people"
    Then it fails with "orm error: people: score: "
    When I read people with "select id, name from nowhere"
    Then it fails with "<prefix>"

    Examples:
      | adapter  | prefix                                 |
      | sqlite   | sqlite error 1: no such table: nowhere |
      | postgres | postgres error 42P01: relation         |
      | mysql    | mysql error 1146: Table                |

  Scenario Outline: An Int reads as a Float unless it would round on <adapter>
    Given a "<adapter>" database
    And I execute "create temporary table people (id integer not null, name varchar(50) not null, age integer, admin boolean not null, score double precision not null)"
    And I execute "insert into people (id, name, age, admin, score) values (1, 'ana', 31, true, 1.5)"
    When I read people with "select id, name, age, admin, 2 as score from people"
    Then the result is:
      | id    | name     | age    | admin     | score     |
      | Int 1 | Text ana | Int 31 | Bool true | Float 2.0 |
    When I read people with "select id, name, age, admin, 9007199254740993 as score from people"
    Then it fails with exactly "orm error: people: score: 9007199254740993 does not fit a Float exactly"

    Examples:
      | adapter  |
      | sqlite   |
      | postgres |
      | mysql    |

  Scenario Outline: A query decoded by the caller gives the caller's values and errors on <adapter>
    Given a "<adapter>" database
    And I execute "create temporary table people (id integer not null, name varchar(50) not null)"
    And I execute "insert into people (id, name) values (1, 'ana'), (2, 'bob')"
    When I read the names with "select id, name from people order by id"
    Then the result is:
      | name     |
      | Text ana |
      | Text bob |
    When I read the names with "select id from people"
    Then it fails with exactly "no name in the row"

    Examples:
      | adapter  |
      | sqlite   |
      | postgres |
      | mysql    |

  Scenario Outline: A schema is checked against its table on <adapter>
    Given a "<adapter>" database
    And I execute "create temporary table people (id integer not null, name varchar(50) not null, age integer, admin boolean not null, score double precision not null)"
    When I check the "people" schema
    Then it succeeds
    When I check the "ghost" schema
    Then it fails with "<prefix>"
    When I check the "keyless" schema
    Then it fails with exactly "orm error: people: the primary key pk is not a column"
    When I check the "injection" schema
    Then it fails with exactly "orm error: a; drop table x: the table name is not a plain identifier"
    When I check the "list" schema
    Then it fails with exactly "orm error: people: the field tags has the type List[String], which a column cannot hold"

    Examples:
      | adapter  | prefix                                        |
      | sqlite   | sqlite error 1: no such column: nickname      |
      | postgres | postgres error 42703: column                  |
      | mysql    | mysql error 1054: Unknown column              |
