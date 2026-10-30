Feature: Orm writes
  Orm inserts, updates, deletes and patches the rows of a table through its schema. The scenarios use the `people`
  table and the struct Person of the driver, as in orm.feature, with a key the database numbers: the `create` column of
  the examples is the table of each adapter. An insert leaves out a generated key and the JsonField age of a Partial
  that is Absent (the database default applies) and gives the row back as the database stored it; an age that is
  `none` is a NULL. Update, delete and patch give the number of rows they changed. A cell `Absent` is a JsonField with
  no value, so only a partial person has one.

  Scenario Outline: An insert gives the row back with its generated key and its defaults on <adapter>
    Given a "<adapter>" database
    And I execute "create temporary table people (id <key>, name varchar(50) not null, age integer default 7, admin boolean not null, score double precision not null)"
    When I insert the partial person:
      | name     | age    | admin     | score     |
      | Text ana | Absent | Bool true | Float 1.5 |
    Then the result is:
      | id    | name     | age   | admin     | score     |
      | Int 1 | Text ana | Int 7 | Bool true | Float 1.5 |
    When I insert the person:
      | id     | name     | age  | admin      | score     |
      | Int 40 | Text bob | Null | Bool false | Float 2.0 |
    Then the result is:
      | id    | name     | age  | admin      | score     |
      | Int 2 | Text bob | Null | Bool false | Float 2.0 |
    And the query "select id, name from people order by id" returns:
      | id    | name     |
      | Int 1 | Text ana |
      | Int 2 | Text bob |

    Examples:
      | adapter  | key                                |
      | sqlite   | integer primary key                |
      | postgres | serial primary key                 |
      | mysql    | integer primary key auto_increment |

  Scenario Outline: An insert that the database refuses gives the error of the database on <adapter>
    Given a "<adapter>" database
    And I execute "create temporary table people (id <key>, name varchar(50) not null unique, age integer, admin boolean not null, score double precision not null)"
    And I execute "insert into people (id, name, admin, score) values (1, 'ana', true, 1.5)"
    When I insert the person:
      | name     | age  | admin     | score     |
      | Text ana | Null | Bool true | Float 1.5 |
    Then it fails with "<prefix>"

    Examples:
      | adapter  | key                                | prefix                                                               |
      | sqlite   | integer primary key                | sqlite error 19: UNIQUE constraint failed                            |
      | postgres | serial primary key                 | postgres error 23505: duplicate key value violates unique constraint |
      | mysql    | integer primary key auto_increment | mysql error 1062: Duplicate entry 'ana' for key                      |

  Scenario Outline: An update sets every column but the key, and counts the rows it changed on <adapter>
    Given a "<adapter>" database
    And I execute "create temporary table people (id integer primary key, name varchar(50) not null, age integer, admin boolean not null, score double precision not null)"
    And I execute "insert into people (id, name, age, admin, score) values (1, 'ana', 31, true, 1.5), (2, 'bob', 20, false, 2.0)"
    When I update the person:
      | id    | name     | age   | admin      | score     |
      | Int 1 | Text ann | Null  | Bool false | Float 3.0 |
    Then the changed row count is 1
    When I update the person:
      | id    | name     | age    | admin      | score     |
      | Int 9 | Text nob | Int 5 | Bool false | Float 3.0 |
    Then the changed row count is 0
    When I update the partial person:
      | id    | name     | age    | admin      | score     |
      | Int 2 | Text rob | Absent | Bool false | Float 5.0 |
    Then the changed row count is 1
    And the query "select id, name, age, score from people order by id" returns:
      | id    | name     | age    | score     |
      | Int 1 | Text ann | Null   | Float 3.0 |
      | Int 2 | Text rob | Int 20 | Float 5.0 |

    Examples:
      | adapter  |
      | sqlite   |
      | postgres |
      | mysql    |

  Scenario Outline: A delete counts the rows it removed, and a patch changes only the keys it has on <adapter>
    Given a "<adapter>" database
    And I execute "create temporary table people (id integer primary key, name varchar(50) not null, age integer, admin boolean not null, score double precision not null)"
    And I execute "insert into people (id, name, age, admin, score) values (1, 'ana', 31, true, 1.5), (2, 'bob', 20, false, 2.0), (3, 'cy', 9, true, 0.25)"
    When I patch the person 1 with "{\"age\": null, \"score\": 3}"
    Then the changed row count is 1
    When I patch the person 3 with "{\"score\": 4, \"age\": null}"
    Then the changed row count is 1
    When I patch the person 9 with "{\"name\": \"nobody\"}"
    Then the changed row count is 0
    When I delete the person 2
    Then the changed row count is 1
    When I delete the person 2
    Then the changed row count is 0
    And the query "select id, name, age, score from people order by id" returns:
      | id    | name     | age   | score      |
      | Int 1 | Text ana | Null  | Float 3.0  |
      | Int 3 | Text cy  | Null  | Float 4.0  |

    Examples:
      | adapter  |
      | sqlite   |
      | postgres |
      | mysql    |

  Scenario Outline: A write the schema or the value does not allow fails before any sql runs on <adapter>
    Given a "<adapter>" database
    And I execute "create temporary table people (id integer primary key, name varchar(50) not null, age integer, admin boolean not null, score double precision not null)"
    And I execute "insert into people (id, name, age, admin, score) values (1, 'ana', 31, true, 1.5)"
    When I patch the person 1 with "{\"nickname\": \"x\"}"
    Then it fails with exactly "orm error bad_request: people: the changes have a key that is not a column"
    When I patch the person 1 with "{\"id\": 5}"
    Then it fails with exactly "orm error bad_request: people: the primary key id cannot be changed"
    When I patch the person 1 with "{\"name\": null}"
    Then it fails with exactly "orm error bad_request: people: name: NULL in a field that is not Optional or JsonField"
    When I patch the person 1 with "{\"age\": \"old\"}"
    Then it fails with exactly "orm error bad_request: people: age: expected Int"
    When I patch the person 1 with "{\"score\": 9007199254740993}"
    Then it fails with exactly "orm error bad_request: people: score: 9007199254740993 does not fit a Float exactly"
    When I patch the person 1 with "[1]"
    Then it fails with exactly "orm error bad_request: people: the changes are not a JSON object"
    When I patch the person 1 with "{}"
    Then it fails with exactly "orm error bad_request: people: no column to change"
    When I delete the person with the key "Text 1"
    Then it fails with exactly "orm error bad_request: people: the key id has type Int, not Text"
    When I delete the person 1 from the "injection" schema
    Then it fails with exactly "orm error schema: a; drop table x: the table name is not a plain identifier"
    And the query "select id, name, age, score from people" returns:
      | id    | name     | age    | score     |
      | Int 1 | Text ana | Int 31 | Float 1.5 |

    Examples:
      | adapter  |
      | sqlite   |
      | postgres |
      | mysql    |

  Scenario Outline: An insert with a key that is not generated keeps the key of the value on <adapter>
    Given a "<adapter>" database
    And I execute "create temporary table people (id integer primary key, name varchar(50) not null, age integer, admin boolean not null, score double precision not null)"
    When I insert the person with its own key:
      | id     | name     | age  | admin     | score     |
      | Int 40 | Text ana | Null | Bool true | Float 1.5 |
    Then the result is:
      | id     | name     | age  | admin     | score     |
      | Int 40 | Text ana | Null | Bool true | Float 1.5 |
    And the query "select id from people" returns:
      | id     |
      | Int 40 |

    Examples:
      | adapter  |
      | sqlite   |
      | postgres |
      | mysql    |

  Scenario Outline: A value with nothing to write fails before any sql runs on <adapter>
    Given a "<adapter>" database
    When I insert a marker with no note
    Then it fails with exactly "orm error bad_request: markers: no column to insert"
    When I update a marker with no note
    Then it fails with exactly "orm error bad_request: markers: no column to update"

    Examples:
      | adapter  |
      | sqlite   |
      | postgres |
      | mysql    |
