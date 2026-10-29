Feature: Orm errors
  An Orm failure is a text, and `Orm.classify` turns it into a kind a handler can `case` on: BadRequest (a column, a
  value or a key the caller got wrong), Conflict (a unique or foreign-key violation), NotDecodable (a row that does
  not fit its struct), Schema (a schema that is not sound) and Database (any other error of the database, or of the
  Orm's own bookkeeping). The scenarios use the `people` table and the struct Person of the driver, as in
  orm_writes.feature.

  Scenario Outline: Each failure has its kind on <adapter>
    Given a "<adapter>" database
    And I execute "create temporary table people (id <key>, name varchar(50) not null unique, age integer, admin boolean not null, score double precision not null)"
    And I execute "insert into people (name, admin, score) values ('ana', true, 1.5)"
    When I insert the person:
      | name     | age  | admin     | score     |
      | Text ana | Null | Bool true | Float 1.5 |
    Then it fails with "<conflict>"
    And the failure is a "Conflict" error
    When I read people with "select id, name, admin from people"
    Then it fails with "orm error decode: people: score: missing column"
    And the failure is a "NotDecodable" error
    When I run the people query ending in "all":
      | step     | argument | value  |
      | where_eq | nickname | Text x |
    Then it fails with "orm error bad_request: people: nickname is not a column of the table"
    And the failure is a "BadRequest" error
    When I check the "injection" schema
    Then it fails with "orm error schema: a; drop table x: the table name is not a plain identifier"
    And the failure is a "Schema" error
    When I read people with "select id from nowhere"
    Then it fails with "<missing>"
    And the failure is a "Database" error

    Examples:
      | adapter  | key                                | conflict                | missing                       |
      | sqlite   | integer primary key                | sqlite error 19: UNIQUE | sqlite error 1: no such table |
      | postgres | serial primary key                 | postgres error 23505:   | postgres error 42P01:         |
      | mysql    | integer primary key auto_increment | mysql error 1062:       | mysql error 1146:             |

  Scenario: A foreign-key violation is a conflict on sqlite
    Given a "sqlite" database
    And I execute "pragma foreign_keys = on"
    And I execute "create table parents (id integer primary key)"
    And I execute "create table children (id integer primary key, parent integer not null references parents (id))"
    When I execute "insert into children (parent) values (7)"
    Then it fails with "sqlite error 19: FOREIGN KEY"
    And the failure is a "Conflict" error
