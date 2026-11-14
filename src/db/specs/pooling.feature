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

  # The block runs past lease_ms: the caller gets the lease timeout, and the connection is closed and replaced. A
  # shorter lease_ms can time out the CREATE before it on a busy CI runner.
  Scenario Outline: A block that runs past lease_ms ends its connection on <adapter>
    Given a "<adapter>" database
    When I start a pool on "[URL]" with:
      | option   | value |
      | size     | 1     |
      | lease_ms | 1000  |
    And I execute "create temporary table t (x integer)" in the pool
    And I keep a connection of the pool for 3000 ms
    Then it fails with "pool error: lease timed out after 1000 ms"
    When I query "select x from t" in the pool
    Then it fails with "<missing table>"

    Examples:
      | adapter  | missing table                  |
      | sqlite   | sqlite error 1: no such table  |
      | postgres | postgres error 42P01:          |
      | mysql    | mysql error 1146:              |

  # The caller is cancelled while it holds the connection: its block is cancelled with it (it does not run on for the
  # 10 s it asked), and the connection is closed and replaced, so the next caller gets a new one at once.
  Scenario Outline: A caller cancelled while it holds a connection gives it up on <adapter>
    Given a "<adapter>" database
    When I start a pool on "[URL]" with:
      | option      | value |
      | size        | 1     |
      | checkout_ms | 3000  |
    And I execute "create temporary table t (x integer)" in the pool
    And I cancel a task that keeps a connection of the pool for 10000 ms
    And I query "select x from t" in the pool
    Then it fails with "<missing table>"

    Examples:
      | adapter  | missing table                  |
      | sqlite   | sqlite error 1: no such table  |
      | postgres | postgres error 42P01:          |
      | mysql    | mysql error 1146:              |

  # The caller is cancelled inside a transaction that has written: the connection is interrupted, closed and replaced,
  # never lent back in the middle of the transaction. The row does not stay, and the next write does not wait for the
  # lock of the cancelled one (it would wait busy_timeout).
  Scenario: A caller cancelled inside a transaction leaves no row and no lock on sqlite
    Given a "sqlite" database
    When I start a pool on "sqlite:[SCRATCH]/pool.db" with:
      | option | value |
      | size   | 2     |
    And I execute "create table notes (writer integer not null)" in the pool
    And I cancel a task that holds a transaction with "insert into notes (writer) values (1)" for 10000 ms
    And I execute "insert into notes (writer) values (2)" in the pool within 1000 ms
    Then the changed row count is 1
    When I query "select writer from notes" in the pool
    Then the result is:
      | writer |
      | Int 2  |

  # lease_ms 0 runs the block in the task of its caller; above 0 it runs in a task of the pool.
  Scenario Outline: A block runs <where> with lease_ms <lease_ms> on <adapter>
    Given a "<adapter>" database
    When I start a pool on "[URL]" with:
      | option   | value      |
      | size     | 1          |
      | lease_ms | <lease_ms> |
    Then a block of the pool runs <where>

    Examples:
      | adapter  | lease_ms | where                       |
      | sqlite   | 0        | in the task of its caller   |
      | postgres | 0        | in the task of its caller   |
      | mysql    | 0        | in the task of its caller   |
      | sqlite   | 30000    | in a task of its own        |

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

  Scenario Outline: Nobody may wait when max_waiting is 0, so a busy pool refuses the caller on <adapter>
    Given a "<adapter>" database
    When I start a pool on "[URL]" with:
      | option      | value |
      | size        | 1     |
      | max_waiting | 0     |
    And another task keeps a connection of the pool for 500 ms while I query "select 1 as v" in the pool
    Then it fails with "pool error: queue full (max_waiting 0)"
    When I query "select 1 as v" in the pool
    Then the result is:
      | v     |
      | Int 1 |

    Examples:
      | adapter  |
      | sqlite   |
      | postgres |
      | mysql    |

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

  # The writers of one pool wait in line at Db.transaction and get their turn in the order they came: a channel serves
  # the tasks that wait for it first come, first served. Each writer comes 50 ms after the one before and holds its
  # transaction 150 ms; without the line they would try BEGIN again in any order.
  Scenario Outline: The writers of a pool take turns in the order they came, lease_ms <lease_ms>, on sqlite
    Given a "sqlite" database
    When I start a pool on "sqlite:[SCRATCH]/pool.db" with:
      | option   | value      |
      | size     | 4          |
      | lease_ms | <lease_ms> |
    And I execute "create table notes (id integer primary key, writer integer not null)" in the pool
    And 4 writers of the pool come in turn, each holding its transaction
    Then it succeeds
    When I query "select writer from notes order by id" in the pool
    Then the result is:
      | writer |
      | Int 1  |
      | Int 2  |
      | Int 3  |
      | Int 4  |

    Examples:
      | lease_ms |
      | 30000    |
      | 0        |

  # A block that crashes or runs past lease_ms inside its transaction holds the turn, which the pool gives back when it
  # checks the connection in. A turn left taken would hold the next writer for its whole wait: busy_timeout, at most
  # half of lease_ms, so 1000 ms here.
  Scenario Outline: A block that <ends> in its transaction gives the turn back to the pool on sqlite
    Given a "sqlite" database
    When I start a pool on "sqlite:[SCRATCH]/pool.db?busy_timeout=3000" with:
      | option   | value |
      | size     | 2     |
      | lease_ms | 2000  |
    And I execute "create table notes (writer integer not null)" in the pool
    And a block of the pool "<ends>" in its transaction, then a writer takes less than 500 ms
    Then the changed row count is 1

    Examples:
      | ends               |
      | crashes            |
      | outlasts its lease |

  # A block that checks out a second connection inside its transaction and starts one there waits behind its own turn:
  # the wait ends after busy_timeout, and the BEGIN fails at once as SQLite's lock makes it (it does not wait for the
  # lock again), long before the lease ends: under 1.5 times busy_timeout in all.
  Scenario: A transaction on a second connection inside a transaction of the pool fails as locked on sqlite
    Given a "sqlite" database
    When I start a pool on "sqlite:[SCRATCH]/pool.db?busy_timeout=500" with:
      | option   | value |
      | size     | 2     |
      | lease_ms | 3000  |
    And I execute "create table notes (writer integer not null)" in the pool
    And a block of the pool starts a transaction on a second connection, all within 750 ms
    Then it fails with "sqlite error 5: database is locked"

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
      | url                          |
      | sqlite::memory:              |
      | sqlite:file::memory:         |
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

  Scenario: A pool refuses a sqlite:// url as Db.open does, without the password, on sqlite
    Given a "sqlite" database
    When I start a pool on "sqlite://user:hunter2@h/x" with:
      | option | value |
      | size   | 1     |
    Then it fails with "db error: unsupported database url with scheme sqlite://: write sqlite:PATH"
    And the failure never shows "hunter2"

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
