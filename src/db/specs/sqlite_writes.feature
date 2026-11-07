@native
Feature: SQLite writes in short calls and the checkpoints of a pool
  What the native SQLite driver adds to writes in WAL mode: a cached write whose plan bounds its work (a lookup of one
  row, no scan, trigger or virtual table) and a BEGIN run in a short call on the scheduler, and so does a COMMIT on a
  connection of a pool, which takes the checkpoints of the WAL off the commits: a checkpointer task checkpoints when a
  commit leaves `checkpoint_frames` frames in the WAL, and a commit that leaves `checkpoint_cap` frames checkpoints
  itself. The FFI driver has none of it, so these scenarios have the tag @native. The first run of a statement prepares
  it on the compute pool. [SCRATCH] is a folder of the scenario under tmp/.

  # Without a pool SQLite's autocheckpoint stays, which can checkpoint in a COMMIT: only the BEGIN and the insert of the
  # second transaction run in short calls.
  Scenario: A cheap write and the BEGIN of a transaction run in short calls, the COMMIT on the compute pool, on sqlite
    Given a "sqlite" database
    When I open "sqlite:[SCRATCH]/writes.db"
    And I execute "create table t (id integer primary key, n integer)"
    And I run these statements in a transaction:
      | sql                         |
      | insert into t (n) values (1) |
    And I run these statements in a transaction:
      | sql                         |
      | insert into t (n) values (1) |
    And I read how many statements ran in a short call
    Then the result is:
      | shorts |
      | Int 2  |

  # A short call never waits for a lock: the cached BEGIN that finds the write lock taken goes to the compute pool,
  # which waits for it, and the insert after it runs in a short call.
  Scenario: A cached BEGIN that finds the write lock taken waits for it on the compute pool on sqlite
    Given a "sqlite" database
    When I open "sqlite:[SCRATCH]/writes.db"
    And I execute "create table t (n integer)"
    And I run these statements in a transaction:
      | sql                      |
      | insert into t values (1) |
    And another connection to "sqlite:[SCRATCH]/writes.db" holds the write lock for 300 ms while I run these in a transaction:
      | sql                      |
      | insert into t values (1) |
    Then it succeeds
    When I read how many statements ran in a short call
    Then the result is:
      | shorts |
      | Int 1  |

  # In a pool the second transaction runs whole in short calls: its BEGIN, its two writes and its COMMIT. The insert
  # reads the row of its AUTOINCREMENT counter, checks its foreign key and takes the row of a SELECT that looks up one
  # row; the update looks up its row by key.
  Scenario: A transaction of cheap writes runs whole in short calls in a pool, and its rows stay after a reopen on sqlite
    Given a "sqlite" database
    When I start a pool on "sqlite:[SCRATCH]/writes.db" with:
      | option    | value |
      | size      | 1     |
      | health_ms | 0     |
    And I execute "create table rooms (id integer primary key autoincrement, n integer)" in the pool
    And I execute "create table notes (id integer primary key autoincrement, room_id integer not null references rooms (id), body text)" in the pool
    And I execute "insert into rooms (n) values (0)" in the pool
    And I run these statements in a transaction of the pool:
      | sql                                                                                                     |
      | insert into notes (room_id, body) select 1, 'hi' where exists (select 1 from rooms where id = 1)        |
      | update rooms set n = n + 1 where id = 1                                                                 |
    And I run these statements in a transaction of the pool:
      | sql                                                                                                     |
      | insert into notes (room_id, body) select 1, 'hi' where exists (select 1 from rooms where id = 1)        |
      | update rooms set n = n + 1 where id = 1                                                                 |
    And I read how many statements ran in a short call in the pool
    Then the result is:
      | shorts |
      | Int 4  |
    When I close the pool
    And I open "sqlite:[SCRATCH]/writes.db"
    Then the query "select (select n from rooms where id = 1) as n, (select count(*) from notes) as notes" returns:
      | n     | notes |
      | Int 2 | Int 2 |

  # A write that scans a table, or the COMMIT of a transaction that ran one, runs on the compute pool however often it
  # ran: one scheduler, and a ticker that would stop for the whole write if it ran there.
  Scenario Outline: A long write runs on the compute pool, never on the scheduler, <what> on sqlite
    Given the environment variable "AGENTICA_SCHEDULERS" is "1"
    And a "sqlite" database
    When I start a pool on "sqlite:[SCRATCH]/writes.db" with:
      | option | value |
      | size   | 1     |
    And I execute "create table t (n integer)" in the pool
    And I execute "create table u (n integer)" in the pool
    And I execute "insert into t with recursive c(v) as (select 1 union all select v + 1 from c where v < 1000000) select v from c" in the pool
    And I run these statements in a transaction of the pool:
      | sql   |
      | <sql> |
    And I run these statements in a transaction of the pool, and no scheduler stops for 100 ms:
      | sql   |
      | <sql> |
    Then it succeeds

    Examples:
      | what                  | sql                                                                                                 |
      | a scan                | update t set n = n + 1                                                                              |
      | a range of keys       | update t set n = n + 1 where rowid > 0                                                              |
      | an insert of a select | insert into u select n from t                                                                       |
      | a recursive CTE       | insert into u with recursive c(v) as (select 1 union all select v + 1 from c where v < 1000000) select v from c |

  # The writers take turns at the line of the pool while other blocks read: no reader sees half of a transaction, and
  # every row is there after a reopen. The checkpointer runs meanwhile, at a mark of a few frames.
  Scenario: Writers and readers of a pool see whole transactions, and every row stays after a reopen on sqlite
    Given the environment variable "AGENTICA_SCHEDULERS" is "4"
    And a "sqlite" database
    When I start a pool on "sqlite:[SCRATCH]/writes.db" with:
      | option            | value |
      | size              | 4     |
      | checkpoint_frames | 8     |
    And I execute "create table notes (id integer primary key, writer integer not null)" in the pool
    And 4 writers of the pool each commit 50 transactions of two rows into "notes" while readers count them
    Then it succeeds
    When I close the pool
    And I open "sqlite:[SCRATCH]/writes.db"
    Then the query "select count(*) as n, count(distinct writer) as writers from notes" returns:
      | n       | writers |
      | Int 400 | Int 4   |

  # A checkpointer that never runs (no commit reaches its mark, and its timer is ten minutes away): the commits
  # checkpoint at the cap, so the WAL file stays near 40 pages of 4096 bytes. Without the cap it would hold about 800.
  Scenario: The WAL stays bounded at the cap when the checkpointer lags on sqlite
    Given a "sqlite" database
    When I start a pool on "sqlite:[SCRATCH]/writes.db" with:
      | option            | value   |
      | size              | 1       |
      | checkpoint_frames | 1000000 |
      | checkpoint_ms     | 600000  |
      | checkpoint_cap    | 40      |
    And I execute "create table t (id integer primary key, body text)" in the pool
    And I commit 400 transactions in the pool, each running "insert into t (body) values ('a note')"
    Then the file "[SCRATCH]/writes.db-wal" holds at most 250000 bytes

  # The checkpointer keeps a connection of its own, and `close` stops it: the journal mode can change only once no
  # connection is open.
  Scenario: Closing the pool stops its checkpointer and closes its connection on sqlite
    Given a "sqlite" database
    When I start a pool on "sqlite:[SCRATCH]/writes.db" with:
      | option | value |
      | size   | 2     |
    And I execute "create table t (n integer)" in the pool
    And I commit 20 transactions in the pool, each running "insert into t values (1)"
    And I close the pool
    And I open "sqlite:[SCRATCH]/writes.db?journal_mode=delete"
    Then the query "select count(*) as n from t" returns:
      | n      |
      | Int 20 |

  Scenario Outline: A checkpoint option out of range does not start the pool, <option> <value> on sqlite
    Given a "sqlite" database
    When I start a pool on "sqlite:[SCRATCH]/writes.db" with:
      | option   | value   |
      | <option> | <value> |
    Then it fails with "db error: <option> must be <least> or more, got <value>"

    Examples:
      | option            | value | least |
      | checkpoint_frames | -1    | 0     |
      | checkpoint_cap    | -1    | 0     |
      | checkpoint_ms     | 0     | 1     |
