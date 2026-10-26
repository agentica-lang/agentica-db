Feature: Errors
  A failure is `error(message)` in one of two shapes: an engine failure, `<adapter> error <code>: <message>`, and a
  bad input, refused before the statement runs, `<adapter> error: <message>`. A bad input is an error, not a halt.
  In a step text, [NUL] and [LF] stand for the characters a text cannot hold.

  Scenario Outline: A syntax error gives the engine code and message on <adapter>
    Given a "<adapter>" database
    When I query "selec 1"
    Then it fails with exactly '<message>'

    Examples:
      | adapter  | message                                               |
      | sqlite   | sqlite error 1: near "selec": syntax error            |
      | postgres | postgres error 42601: syntax error at or near "selec" |

  Scenario Outline: A constraint violation gives the engine code on <adapter>
    Given a "<adapter>" database
    And I execute "create temp table users (name text not null unique)"
    And I execute "insert into users (name) values ('ana')"
    When I execute "insert into users (name) values ('ana')"
    Then it fails with "<prefix>"

    Examples:
      | adapter  | prefix                                                               |
      | sqlite   | sqlite error 19: UNIQUE constraint failed                            |
      | postgres | postgres error 23505: duplicate key value violates unique constraint |

  Scenario Outline: The wrong number of parameters is an error on <adapter>
    Given a "<adapter>" database
    When I execute "select ?"
    Then it fails with exactly "<adapter> error: the sql has 1 parameter, got 0"
    When I execute "select 1" with:
      | value |
      | Int 1 |
    Then it fails with exactly "<adapter> error: the sql has 0 parameters, got 1"

    Examples:
      | adapter  |
      | sqlite   |
      | postgres |

  Scenario Outline: A parameter the database cannot take is an error on <adapter>: <value>
    Given a "<adapter>" database
    When I execute "select ?" with:
      | value   |
      | <value> |
    Then it fails with exactly "<adapter> error: <message>"

    Examples:
      | adapter  | value        | message                                     |
      | sqlite   | Text a[NUL]b | a text parameter contains a NUL character   |
      | sqlite   | Blob 256     | a blob parameter has an item outside 0..255 |
      | postgres | Text a[NUL]b | a text parameter contains a NUL character   |
      | postgres | Blob 256     | a blob parameter has an item outside 0..255 |

  Scenario Outline: A sql with a NUL character is an error on <adapter>
    Given a "<adapter>" database
    When I execute "select 1[NUL]"
    Then it fails with exactly "<adapter> error: the sql contains a NUL character"

    Examples:
      | adapter  |
      | sqlite   |
      | postgres |

  Scenario Outline: A sql without a statement is an error on <adapter>: <sql>
    Given a "<adapter>" database
    When I execute "<sql>"
    Then it fails with exactly "<adapter> error: the sql has no statement"

    Examples:
      | adapter  | sql                              |
      | sqlite   | [LF] -- nothing[LF] /* here */ ; |
      | sqlite   | -- only a comment                |
      | sqlite   |                                  |
      | postgres | [LF] -- nothing[LF] /* here */ ; |
      | postgres | -- only a comment                |
      | postgres |                                  |
