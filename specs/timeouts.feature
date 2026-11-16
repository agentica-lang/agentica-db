Feature: Query timeouts
  The url parameter `timeout_ms` bounds every statement of the connection; a call can take its own `timeout_ms`
  (0 for none). A statement that runs longer fails with a failure that `Db.timeout?` knows, and the connection works
  after it. Without `timeout_ms` nothing is bounded.
  In a step text, [SLOW] is a statement of the adapter that runs for many seconds, and [WORK] one that works for about
  half a second and gives the row `n = 1`.

  Scenario Outline: A slow query times out and the connection works after it on <adapter>
    Given a "<adapter>" database
    When I open "[URL]&timeout_ms=200"
    And I query "[SLOW]"
    Then it fails with a timeout
    And the query "select 1 as v" returns:
      | v     |
      | Int 1 |

    Examples:
      | adapter  |
      | sqlite   |
      | postgres |
      | mysql    |

  Scenario Outline: A statement run with execute times out too on <adapter>
    Given a "<adapter>" database
    When I open "[URL]&timeout_ms=200"
    And I execute "[SLOW]"
    Then it fails with a timeout
    And the query "select 1 as v" returns:
      | v     |
      | Int 1 |

    Examples:
      | adapter  |
      | sqlite   |
      | postgres |
      | mysql    |

  # The call shortens the limit of the connection for itself only: the next statement has the limit of the url again.
  Scenario Outline: A call can shorten the timeout of the connection on <adapter>
    Given a "<adapter>" database
    When I open "[URL]&timeout_ms=60000"
    And I query "[SLOW]" with a timeout of 200 ms
    Then it fails with a timeout
    And the query "[WORK]" returns:
      | n     |
      | Int 1 |

    Examples:
      | adapter  |
      | sqlite   |
      | postgres |
      | mysql    |

  # 0 lifts the limit for one call, and the limit of the url is back after it. The limit is under what [WORK] takes
  # (20 ms on SQLite, whose [WORK] is quick on a fast machine), and the last statement is [SLOW], which any limit stops.
  Scenario Outline: A call can lift the timeout of the connection on <adapter>
    Given a "<adapter>" database
    When I open "[URL]&timeout_ms=<limit>"
    And I query "[WORK]" with a timeout of 0 ms
    Then the result is:
      | n     |
      | Int 1 |
    When I query "[SLOW]"
    Then it fails with a timeout

    Examples:
      | adapter  | limit |
      | sqlite   | 20    |
      | postgres | 200   |
      | mysql    | 200   |

  Scenario Outline: A connection without timeout_ms is not bounded on <adapter>
    Given a "<adapter>" database
    When I query "[WORK]"
    Then the result is:
      | n     |
      | Int 1 |

    Examples:
      | adapter  |
      | sqlite   |
      | postgres |
      | mysql    |

  Scenario Outline: A url timeout_ms that is not a number of milliseconds is refused on <adapter>
    Given a "<adapter>" database
    When I open "[URL]&timeout_ms=soon"
    Then it fails with "<prefix>"

    Examples:
      | adapter  | prefix                                                |
      | sqlite   | sqlite error: the url timeout_ms is not a number of   |
      | postgres | postgres error: the url timeout_ms is not a number of |
      | mysql    | mysql error: the url timeout_ms is not a number of    |

  Scenario Outline: A connection is in a transaction between BEGIN and ROLLBACK on <adapter>
    Given a "<adapter>" database
    Then the connection is not in a transaction
    When I execute "begin"
    Then the connection is in a transaction
    When I execute "rollback"
    Then the connection is not in a transaction

    Examples:
      | adapter  |
      | sqlite   |
      | postgres |
      | mysql    |

  Scenario Outline: A connection is healthy until it is closed on <adapter>
    Given a "<adapter>" database
    Then the connection is healthy
    When I close the database
    Then the connection is not healthy
    And the connection is not in a transaction

    Examples:
      | adapter  |
      | sqlite   |
      | postgres |
      | mysql    |
