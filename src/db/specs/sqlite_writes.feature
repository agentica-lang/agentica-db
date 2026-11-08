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

  # A write of one row can still make or copy a long value in one instruction, which neither the plan nor the count
  # of instructions shows: in a short call a value or row over 256 KiB fails and the write runs again on the compute
  # pool, in the same transaction. Its later runs go there at once: only the first short call gives its statement back.
  # No checkpoint runs, which would send the next write to the compute pool anyway.
  Scenario Outline: A write that makes or copies a long value runs on the compute pool, <what> on sqlite
    Given the environment variable "AGENTICA_SCHEDULERS" is "1"
    And a "sqlite" database
    When I start a pool on "sqlite:[SCRATCH]/writes.db" with:
      | option            | value   |
      | size              | 1       |
      | checkpoint_frames | 1000000 |
      | checkpoint_ms     | 600000  |
      | checkpoint_cap    | 1000000 |
    And I execute "create table t (b blob)" in the pool
    And I execute "insert into t (b) values (randomblob(64000000))" in the pool
    And I run these statements in a transaction of the pool:
      | sql   |
      | <sql> |
    And I run these statements in a transaction of the pool, and no scheduler stops for 100 ms:
      | sql   |
      | <sql> |
    And I run these statements in a transaction of the pool, and no scheduler stops for 100 ms:
      | sql   |
      | <sql> |
    And I query "select count(*) as n from t" in the pool
    Then the result is:
      | n     |
      | Int 4 |
    When I read how many short calls left their statement to the compute pool in the pool
    Then the result is:
      | fallbacks |
      | Int 1     |

    Examples:
      | what               | sql                                               |
      | made by a function | insert into t (b) values (randomblob(64000000))   |
      | copied from a row  | insert into t (b) select b from t where rowid = 1 |

  # An insert into a parent table looks for the child rows that point to its new key while deferred violations of a
  # foreign key wait, here the child row that the transaction inserted first. With no index on the child's key that
  # scans the whole child table, so the insert runs on the compute pool, however cheap its last run was.
  Scenario: An insert that may scan a child table for its foreign key runs on the compute pool on sqlite
    Given the environment variable "AGENTICA_SCHEDULERS" is "1"
    And a "sqlite" database
    When I start a pool on "sqlite:[SCRATCH]/writes.db" with:
      | option | value |
      | size   | 1     |
    And I execute "create table parents (id integer primary key)" in the pool
    And I execute "create table children (parent_id integer references parents (id) deferrable initially deferred)" in the pool
    And I execute "insert into children with recursive c(v) as (select 1 union all select v + 1 from c where v < 4000000) select null from c" in the pool
    And I run these statements in a transaction of the pool:
      | sql                                 |
      | insert into parents (id) values (7) |
    And I run these statements in a transaction of the pool:
      | sql                                         |
      | insert into children (parent_id) values (7) |
    And I execute "delete from children where parent_id = 7" in the pool
    And I execute "delete from parents where id = 7" in the pool
    And I run these statements in a transaction of the pool, and no scheduler stops for 100 ms:
      | sql                                         |
      | insert into children (parent_id) values (7) |
      | insert into parents (id) values (7)         |
    Then it succeeds

  # A commit that writes the first frame of the WAL writes its header and syncs it, a disk flush even with
  # synchronous=normal: the first commit of a new WAL, and the first one after a checkpoint that copied every frame.
  # So after such a checkpoint the next transaction runs on the compute pool, its BEGIN too, so that its snapshot comes
  # after the checkpoint and its commit is the one that starts the WAL again. Here each transaction leaves two frames
  # that no checkpoint has copied, the cap, and checkpoints the whole WAL, so only every other one runs in short calls
  # after the first: 3 + 0 + 3 + 0 short calls (its BEGIN, its insert and its COMMIT).
  Scenario: The commit after a checkpoint of the whole WAL runs on the compute pool on sqlite
    Given a "sqlite" database
    When I start a pool on "sqlite:[SCRATCH]/writes.db" with:
      | option            | value   |
      | size              | 1       |
      | checkpoint_frames | 1000000 |
      | checkpoint_ms     | 600000  |
      | checkpoint_cap    | 2       |
    And I execute "create table t (n integer)" in the pool
    And I commit 5 transactions in the pool, each running "insert into t (n) values (1)"
    And I read how many statements ran in a short call in the pool
    Then the result is:
      | shorts |
      | Int 6  |

  # A transaction writes in at most 64 short calls: SQLite keeps its pages in memory until the commit, and more of them
  # could spill to the WAL inside a short call. The BEGIN and 64 inserts run there, the other 6 and the COMMIT on the
  # compute pool.
  Scenario: A transaction runs at most 64 writes in short calls on sqlite
    Given a "sqlite" database
    When I start a pool on "sqlite:[SCRATCH]/writes.db" with:
      | option | value |
      | size   | 1     |
    And I execute "create table t (n integer)" in the pool
    And I run "insert into t (n) values (1)" 70 times in a transaction of the pool
    And I run "insert into t (n) values (1)" 70 times in a transaction of the pool
    And I read how many statements ran in a short call in the pool
    Then the result is:
      | shorts |
      | Int 65 |

  # A PRAGMA that sets how a connection commits, here synchronous=FULL, whose commits sync the WAL, sends the writes of
  # that connection to the compute pool from then on, however it is written; one that only reads the value changes
  # nothing. The second transaction runs 3 short calls (its BEGIN, its insert, its COMMIT), and the third as many, or
  # none.
  Scenario Outline: A PRAGMA that sets how commits sync ends the short writes, and one that reads does not, <what> on sqlite
    Given a "sqlite" database
    When I start a pool on "sqlite:[SCRATCH]/writes.db" with:
      | option | value |
      | size   | 1     |
    And I execute "create table t (n integer)" in the pool
    And I commit 2 transactions in the pool, each running "insert into t (n) values (1)"
    And I execute "<pragma>" in the pool
    And I commit 1 transactions in the pool, each running "insert into t (n) values (1)"
    And I read how many statements ran in a short call in the pool
    Then the result is:
      | shorts       |
      | Int <shorts> |

    Examples:
      | what                                 | pragma                                         | shorts |
      | a set                                | PRAGMA synchronous = FULL                      | 3      |
      | a set after a comment, schema, quote | /* sync */ PRAGMA main . [synchronous] = FULL  | 3      |
      | a read                               | PRAGMA synchronous                             | 6      |

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
