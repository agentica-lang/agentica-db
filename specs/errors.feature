Feature: Errors
  A failure is `error(message)` in one of two shapes: an engine failure, `<adapter> error <code>: <message>`, and a
  bad input, refused before the statement runs, `<adapter> error: <message>`. A bad input is an error, not a halt.
  In a step text, [NUL] and [LF] stand for the characters a text cannot hold.

  Scenario Outline: A syntax error gives the engine code and message, and the connection works after it on <adapter>
    Given a "<adapter>" database
    When I query "selec 1"
    Then it fails with '<message>'
    And the query "select 1 as v" returns:
      | v     |
      | Int 1 |

    Examples:
      | adapter  | message                                               |
      | sqlite   | sqlite error 1: near "selec": syntax error            |
      | postgres | postgres error 42601: syntax error at or near "selec" |
      | mysql    | mysql error 1064: You have an error in your SQL syntax |

  Scenario Outline: A constraint violation gives the engine code on <adapter>
    Given a "<adapter>" database
    And I execute "create temporary table users (name varchar(50) not null unique)"
    And I execute "insert into users (name) values ('ana')"
    When I execute "insert into users (name) values ('ana')"
    Then it fails with "<prefix>"

    Examples:
      | adapter  | prefix                                                               |
      | sqlite   | sqlite error 19: UNIQUE constraint failed                            |
      | postgres | postgres error 23505: duplicate key value violates unique constraint |
      | mysql    | mysql error 1062: Duplicate entry 'ana' for key                      |

  Scenario Outline: A sql that is not one statement is refused before it runs on <adapter>
    Given a "<adapter>" database
    When I execute "select 1; selec 2"
    Then it fails with exactly "<adapter> error: the sql has more than one statement"
    When I execute "[LF] -- nothing[LF] /* here */ ;"
    Then it fails with exactly "<adapter> error: the sql has no statement"
    When I execute "select 1[NUL]"
    Then it fails with exactly "<adapter> error: the sql contains a NUL character"

    Examples:
      | adapter  |
      | sqlite   |
      | postgres |
      | mysql    |

  Scenario Outline: A parameter that does not fit is refused before the statement runs on <adapter>
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
      | mysql    |

  Scenario Outline: A text parameter with a NUL is refused before the statement runs on <adapter>
    Given a "<adapter>" database
    When I execute "select ?" with:
      | value        |
      | Text a[NUL]b |
    Then it fails with exactly "<adapter> error: a text parameter contains a NUL character"

    Examples:
      | adapter  |
      | postgres |
      | mysql    |
