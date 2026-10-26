Feature: Opening and closing a database
  Db.open takes a url and gives a connection. Db.close ends it, and closing twice is safe.

  Scenario Outline: Closing twice is safe on <adapter>
    Given a "<adapter>" database
    When I close the database
    And I close the database
    Then it succeeds

    Examples:
      | adapter  |
      | sqlite   |
      | postgres |

  Scenario Outline: An unknown url scheme is a db error: <url>
    When I open "<url>"
    Then it fails with "db error: "
    And it fails mentioning "<scheme>"

    Examples:
      | url               | scheme |
      | ftp://host/db     | ftp    |
      | pg://user@host/db | pg     |

  Scenario Outline: An error never shows the password: <url>
    When I open "<url>"
    Then it fails with "db error: "
    And the failure never shows "hunter2"

    Examples:
      | url                        |
      | pg://user:hunter2@host/db  |
      | host=h password=hunter2:x  |

  Scenario Outline: Only sqlite:PATH names a SQLite database: <url>
    When I open "<url>"
    Then it fails with "db error: "

    Examples:
      | url                |
      | sqlite:///tmp/x.db |
      | sqlite:            |
      | sqlite             |
