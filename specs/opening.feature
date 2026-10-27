Feature: Opening and closing a database
  Db.open takes a url and gives a connection. Db.close ends it, and closing twice is safe. A connection belongs to the
  task that opened it. A url that cannot be opened is an error that never shows the password.
  In a step text, [NUL] stands for a character a url cannot hold.

  Scenario Outline: Closing twice is safe on <adapter>
    Given a "<adapter>" database
    When I close the database
    And I close the database
    Then it succeeds

    Examples:
      | adapter  |
      | sqlite   |
      | postgres |
      | mysql    |

  Scenario Outline: A url no adapter takes is a db error that never shows the password: <url> (on sqlite, no server)
    When I open "<url>"
    Then it fails with "db error: "
    And it fails mentioning "<mention>"
    And the failure never shows "hunter2"

    Examples:
      | url                         | mention                  |
      | ftp://user:hunter2@host/db  | scheme ftp               |
      | host=h password=hunter2:x   | scheme (none)            |
      | sqlite://user:hunter2@h/x   | write sqlite:PATH        |
      | sqlite:                     | the path is empty        |

  Scenario Outline: A url that cannot be opened is an adapter error that never shows the password on <adapter>: <url>
    Given a "<adapter>" database
    When I open "<url>"
    Then it fails with "<failure>"
    And the failure never shows "hunter2"

    Examples:
      | adapter  | url                                                     | failure                                 |
      | sqlite   | sqlite:/no/such/dir/x.db                                | sqlite error 14: unable to open         |
      | postgres | postgres://u:hunter2@localhost:notaport/db              | postgres error: invalid integer value   |
      | postgres | postgres://u:hunter2@127.0.0.1:1/none?connect_timeout=2 | postgres error: connection to server at |
      | postgres | postgres://u:hunter2@localhost/db[NUL]                  | postgres error: the url contains        |
      | mysql    | mysql://u:hunter2@host:notaport/db                      | mysql error: the url port is not        |
      | mysql    | mysql://u:hunter2@127.0.0.1:1/none?connect_timeout=2    | mysql error 2002:                       |
      | mysql    | mysql://u:hunter2@localhost/db[NUL]                     | mysql error: the url contains           |

  Scenario Outline: A missing native library is an error, not a stop of the program: <adapter> (on sqlite, no server)
    Given a program whose native libraries are missing
    When the program opens "<url>"
    Then the program answers a line starting with "<failure>"

    Examples:
      | adapter  | url                      | failure                                 |
      | sqlite   | sqlite::memory:          | sqlite error: cannot load the SQLite    |
      | postgres | postgres://u@127.0.0.1/d | postgres error: cannot load the libpq   |
      | mysql    | mysql://u@127.0.0.1/d    | mysql error: cannot load the client lib |

  Scenario Outline: Using a closed connection is an error on <adapter>
    Given a "<adapter>" database
    When I close the database
    And I query "select 1"
    Then it fails with exactly "<adapter> error: the connection is closed"

    Examples:
      | adapter  |
      | postgres |
      | mysql    |

  Scenario Outline: A task opens its own connection and queries it on <adapter>
    Given a "<adapter>" database
    When another task opens its own connection and queries "select 42 as v"
    Then the result is:
      | v      |
      | Int 42 |

    Examples:
      | adapter  |
      | postgres |
      | mysql    |
