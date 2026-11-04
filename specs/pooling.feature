Feature: Pooling
  DbPool lends the connections of a pool one caller at a time: `I query "..." in the pool` and `I execute "..." in the
  pool` each run in one block of the pool. A temporary table belongs to one connection, so it shows which connection a
  block got. The pools of this feature have one connection (a pool of `sqlite::memory:` cannot have more), except where
  a scenario says otherwise.

  Scenario Outline: A connection is reused by the next caller on <adapter>
    Given a "<adapter>" database
    When I start a pool on "[URL]" with:
      | option | value |
      | size   | 1     |
    And I execute "create temporary table t (x integer)" in the pool
    And I execute "insert into t values (7)" in the pool
    And I query "select x from t" in the pool
    Then the result is:
      | x     |
      | Int 7 |

    Examples:
      | adapter  |
      | sqlite   |
      | postgres |
      | mysql    |

  Scenario Outline: A transaction left open is rolled back when the connection comes back on <adapter>
    Given a "<adapter>" database
    When I start a pool on "[URL]" with:
      | option | value |
      | size   | 1     |
    And I execute "create temporary table t (x integer)" in the pool
    And I run these statements in one block of the pool:
      | sql                       |
      | begin                     |
      | insert into t values (1)  |
    And I query "select count(*) as n from t" in the pool
    Then the result is:
      | n     |
      | Int 0 |

    Examples:
      | adapter  |
      | sqlite   |
      | postgres |
      | mysql    |

  # A block that crashes costs its connection: the next caller gets a new one, which has no temporary table.
  Scenario Outline: A block that crashes ends its connection on <adapter>
    Given a "<adapter>" database
    When I start a pool on "[URL]" with:
      | option | value |
      | size   | 1     |
    And I execute "create temporary table t (x integer)" in the pool
    And I run a block that crashes in the pool
    Then it fails with "task crashed"
    When I query "select x from t" in the pool
    Then it fails with "<missing table>"

    Examples:
      | adapter  | missing table                  |
      | sqlite   | sqlite error 1: no such table  |
      | postgres | postgres error 42P01:          |
      | mysql    | mysql error 1146:              |

  # The block runs past lease_ms: the caller gets the lease timeout, and the connection is closed and replaced.
  Scenario Outline: A block that runs past lease_ms ends its connection on <adapter>
    Given a "<adapter>" database
    When I start a pool on "[URL]" with:
      | option   | value |
      | size     | 1     |
      | lease_ms | 200   |
    And I execute "create temporary table t (x integer)" in the pool
    And I keep a connection of the pool for 3000 ms
    Then it fails with "pool error: lease timed out after 200 ms"
    When I query "select x from t" in the pool
    Then it fails with "<missing table>"

    Examples:
      | adapter  | missing table                  |
      | sqlite   | sqlite error 1: no such table  |
      | postgres | postgres error 42P01:          |
      | mysql    | mysql error 1146:              |

  # The block closes its connection and ends with ok: the pool must not lend the closed connection to the next caller.
  Scenario Outline: A connection that the block closed is replaced on <adapter>
    Given a "<adapter>" database
    When I start a pool on "[URL]" with:
      | option | value |
      | size   | 1     |
    And I run a block that closes its connection in the pool
    Then it succeeds
    When I query "select 1 as v" in the pool
    Then the result is:
      | v     |
      | Int 1 |

    Examples:
      | adapter  |
      | sqlite   |
      | postgres |
      | mysql    |

  # The block ends its own session. The statement fails, libpq knows the connection is down, and the next caller gets a
  # new one.
  Scenario: A connection that the server ended during the block is replaced on postgres
    Given a "postgres" database
    When I start a pool on "[URL]" with:
      | option | value |
      | size   | 1     |
    And I query "select pg_terminate_backend(pg_backend_pid())" in the pool
    Then it fails with "postgres error"
    When I query "select 1 as v" in the pool
    Then the result is:
      | v     |
      | Int 1 |

  # A statement that runs past lease_ms on SQLite is interrupted, so closing its connection does not wait for it: the
  # next caller gets the new connection within its checkout_ms.
  Scenario: A long statement that outlives lease_ms does not stall the pool on sqlite
    Given a "sqlite" database
    When I start a pool on "[URL]" with:
      | option      | value |
      | size        | 1     |
      | lease_ms    | 300   |
      | checkout_ms | 3000  |
    And I query "[SLOW]" in the pool
    Then it fails with "pool error: lease timed out after 300 ms"
    When I query "select 1 as v" in the pool
    Then the result is:
      | v     |
      | Int 1 |

  Scenario Outline: A caller that waits too long for a connection gets a checkout timeout on <adapter>
    Given a "<adapter>" database
    When I start a pool on "[URL]" with:
      | option      | value |
      | size        | 1     |
      | checkout_ms | 200   |
    And another task keeps a connection of the pool for 1000 ms while I query "select 1 as v" in the pool
    Then it fails with "pool error: checkout timed out after 200 ms"
    When I query "select 1 as v" in the pool
    Then the result is:
      | v     |
      | Int 1 |

    Examples:
      | adapter  |
      | sqlite   |
      | postgres |
      | mysql    |

  # Two connections to one file: the second caller does not wait for the first.
  Scenario: Two callers use two connections at once on sqlite
    Given a "sqlite" database
    When I start a pool on "sqlite:[SCRATCH]/pool.db" with:
      | option      | value |
      | size        | 2     |
      | checkout_ms | 200   |
    And another task keeps a connection of the pool for 1000 ms while I query "select 1 as v" in the pool
    Then the result is:
      | v     |
      | Int 1 |

  Scenario Outline: A pool of a private in-memory database cannot have more than one connection on sqlite
    Given a "sqlite" database
    When I start a pool on "<url>" with:
      | option | value |
      | size   | 2     |
    Then it fails with "db error: a pool of a private in-memory database can have one connection only"
    When I start a pool on "<url>" with:
      | option       | value |
      | max_overflow | 1     |
    Then it fails with "db error: a pool of a private in-memory database can have one connection only"
    When I start a pool on "<url>" with:
      | option | value |
    Then it succeeds

    Examples:
      | url                         |
      | sqlite::memory:             |
      | sqlite:file::memory:        |
      | sqlite:file:pool?mode=memory |

  # With cache=shared every connection sees one database, so the pool may have many.
  Scenario: A pool of a shared in-memory database can have more than one connection on sqlite
    Given a "sqlite" database
    When I start a pool on "sqlite:file:pool?mode=memory&cache=shared" with:
      | option | value |
      | size   | 2     |
    And I execute "create table t (x integer)" in the pool
    And I query "select count(*) as n from t" in the pool
    Then the result is:
      | n     |
      | Int 0 |

  Scenario: A pool whose connections do not open does not start on sqlite
    Given a "sqlite" database
    When I start a pool on "sqlite:[SCRATCH]/missing/pool.db" with:
      | option | value |
      | size   | 1     |
    Then it fails with "sqlite error"

  # The url timeout_ms and the timeout_ms of a call both work on a pooled connection, which works after a timeout.
  Scenario Outline: A statement timeout works through the pool on <adapter>
    Given a "<adapter>" database
    When I start a pool on "[URL]&timeout_ms=<limit>" with:
      | option | value |
      | size   | 1     |
    And I query "[SLOW]" in the pool
    Then it fails with a timeout
    When I query "[WORK]" in the pool with a timeout of 0 ms
    Then the result is:
      | n     |
      | Int 1 |
    When I query "[SLOW]" in the pool with a timeout of 100 ms
    Then it fails with a timeout

    Examples:
      | adapter  | limit |
      | sqlite   | 20    |
      | postgres | 200   |
      | mysql    | 200   |
