## The SQLite adapter, through the system libsqlite3.
##
## `open` gives a `Connection`, which the task that opened it owns: close it with `close`, or the end of the task
## closes it (a transaction still open is rolled back). Using a closed connection is a runtime error
## (`RUNTIME-NATIVE-CLOSED`).
##
## `open` sets up the connection for a web app. The parameters after a `?` change it (`sqlite/url.agc` reads them):
## `journal_mode` (default `wal`), `foreign_keys` (default `on`), `busy_timeout` (milliseconds, default 5000),
## `synchronous` (default `normal` in WAL, SQLite's `full` in other modes), `mmap_size` (134217728 bytes),
## `cache_size` (2000 pages) and `journal_size_limit` (67108864 bytes), the pragmas of Rails 8, and
## `fts5=required` (the open fails when this SQLite has no FTS5). `sqlite:app.db?journal_mode=delete&foreign_keys=off`
## is SQLite's own behavior. A name that starts with `file:` is a SQLite URI and goes to SQLite as it is, with its own
## `?` parameters (`file:app.db?mode=ro`); the defaults still apply to it (change one with its PRAGMA after `open`). A
## default `wal` that a read-only database refuses is skipped (for a `file:` name, one that SQLite will not set is
## skipped too); an explicit one is an error.
##
## Two drivers run the statements. The native one (`native.agc`, a native module built from `native/db_sqlite.c`)
## keeps a cache of prepared statements per connection (`statement_cache`, 100 by default) and reads many rows per
## call (`batch_rows`, `batch_bytes`); in WAL mode it runs a cached write whose plan bounds its work, and a BEGIN, in a
## short call on the scheduler, and a COMMIT too on a connection whose pool takes its checkpoints
## (`own_checkpoints`). The FFI one (`ffi.agc`) prepares each statement and steps it row by row. `open`
## takes the native driver when its library loads and the FFI one only when it does not (compiled bytecode run where
## the built library is gone); `AGENTICA_DB_SQLITE_DRIVER=native` or `ffi` chooses one (with `native`, a library that
## does not load is an error).
##
## A statement that finds a lock held by another connection (SQLITE_BUSY, or SQLITE_LOCKED for a table of a shared
## cache) is tried again after a short sleep until `busy_timeout` is over, then fails with that error; 0 fails at once
## (`wait.agc` says why the wait is not SQLite's). A write in a transaction that has read (a plain `BEGIN`, a read,
## then the write) is not waited for: SQLite does not wait there either, since the connection that holds the lock may
## be waiting for this one to let go of its read lock. It fails at once.
##
## `timeout_ms` (a url parameter, and an argument of `query` and `execute`; none by default) bounds a statement. A
## watchdog task calls `sqlite3_interrupt` when the time is over, and the statement fails with `sqlite error 9:
## interrupted`. The wait for a lock ends with the time too. SQLite rolls back the whole transaction when it
## interrupts a write inside one (`in_transaction?` is then false). A statement whose deadline has passed before its
## first step does not run at all, so nothing is rolled back and the transaction stays open. The watchdog is awaited
## before the call returns, so an interrupt never reaches the next statement.
##
## An engine failure is `sqlite error <code>: <message>`; a bad input is `sqlite error: <message>`.

import SqliteFfi from "ffi"
import SqliteLock from "lock"
import SqliteNative from "native"
import SqliteUrl from "url"
import SqliteWait from "wait"
import {Row, Value} from "../support/value"

## The statement that starts a transaction: IMMEDIATE takes the write lock at once, so a busy database fails at
## BEGIN, not in the middle of the body.
export BEGIN_SQL = "BEGIN IMMEDIATE"
# SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_URI: the URI flag makes `file:` names work the same on
# every build, whatever its default.
OPEN_FLAGS = 70
SQLITE_READONLY = 8
DRIVER_VARIABLE = "AGENTICA_DB_SQLITE_DRIVER"
NUL_SQL = "sqlite error: the sql contains a NUL character"

## An open database, the time its statements wait for a lock, and the limit of a statement (0: none). `link` is
## public because a struct has no private fields, but its type is not exported (a user cannot name it): treat it as
## opaque and pass the `Connection` around. `deadline` is set only on the copy that a bounded call works with.
## `gate` is the line of the writers of a pool (`with_gate`). `wal` is true for a connection of the native driver in
## WAL mode, whose checkpoints a pool can take (`own_checkpoints`, which sets `checkpoints`), and `sync_commits` when a
## commit syncs the WAL (`synchronous` full or extra), which keeps the COMMIT on the compute pool.
export struct Connection
  link: Link
  busy_timeout: Int
  timeout_ms: Int = 0
  deadline: Int = 0
  gate: Optional[Gate] = none
  wal: Bool = false
  sync_commits: Bool = true
  checkpoints: Optional[Checkpoints] = none
end

## How a pool takes the WAL checkpoints of its connections: a commit that leaves `frames` frames or more in the WAL
## that no checkpoint has copied wakes the checkpointer of the pool through `nudge` (a channel of one value, which it
## never waits to send), and one that leaves `cap` frames or more checkpoints at once on its own connection, so the WAL
## stays near `cap` when the checkpointer lags (while no reader holds an older snapshot, as with SQLite's own
## checkpoints). `wal` is what the
## connections and the checkpoints share in the native module (`checkpoints`).
export struct Checkpoints
  nudge: Channel[Int]
  frames: Int
  cap: Int
  wal: SqliteNative.Wal
end

# What `configure` set: the journal mode in force (empty when not known) and the `synchronous` level (empty: SQLite's).
struct Journal
  mode: String
  synchronous: String
end

# The line of the writers of a pool. `turn` is the pool's, with its one token; `held` is this connection's, and holds a
# value while its transaction has the turn, so that only the holder gives the token back. `wait_ms` is how long a
# writer waits for its turn.
struct Gate
  turn: Channel[Int]
  held: Channel[Int]
  wait_ms: Int
end

# The connection of the driver that runs it, with what a call of the native one may give at once.
enum Link
  Native(SqliteNative.Conn, SqliteNative.Fetch)
  Ffi(SqliteFfi.Handle)
end

# What the watchdog of a bounded call needs.
struct Watch
  link: Link
  ms: Int
end

## Opens a database file, or `:memory:`; the file is created when it does not exist. A `?` ends the path and starts
## the settings (see the top of this file); a path that holds a `?` (as does the Windows `\\?\` prefix) cannot be
## opened by name, except as a `file:` URI.
export def open(path: String) -> Result[Connection]
  if has_nul?(path)
    return error("sqlite error: the path contains a NUL character")
  end

  target = try SqliteUrl.parse(path)
  link = try connect(target)
  conn = Connection(link: link, busy_timeout: target.settings.busy_timeout, timeout_ms: target.settings.timeout_ms)
  configured = configure(uncached(conn), target.settings)
  case configured
    ok(journal) -> return ok(with_journal(conn, journal))
    error(message) ->
      close(conn)
      return error(message)
  end
end

## The checkpoints of a pool, none where the native driver does not load (its connections run the FFI driver, whose
## checkpoints stay SQLite's).
export def checkpoints(nudge: Channel[Int], frames: Int, cap: Int) -> Optional[Checkpoints]
  if not SqliteNative.available?()
    return none
  end

  return some(Checkpoints(nudge: nudge, frames: frames, cap: cap, wal: SqliteNative.wal()))
end

## The connection with its checkpoints taken by a pool (`plan`): SQLite's autocheckpoint is off, and each commit
## wakes the pool's checkpointer or checkpoints at the cap (see `Checkpoints`). Where the commits do not sync the WAL,
## a COMMIT, and a write that commits, can then run in a short call: no commit of the connection checkpoints. A
## connection of the FFI driver, or not in WAL mode, is given back as it is (SQLite's autocheckpoint stays).
export def own_checkpoints(conn: Connection, plan: Checkpoints) -> Connection
  if not conn.wal or closed?(conn.link)
    return conn
  end

  case conn.link
    Link.Native(native, _) ->
      SqliteNative.own_checkpoints(native, plan.wal)
      SqliteNative.inline_writes(native, not conn.sync_commits)
      return conn.with(checkpoints: some(plan))
    Link.Ffi(_) -> return conn
  end
end

## Whether a pool can take the checkpoints of the connection: the native driver runs it, in WAL mode.
export def checkpointable?(conn: Connection) -> Bool
  return conn.wal
end

## Runs a PASSIVE checkpoint of the WAL of a pool (`plan`), which copies to the database what the WAL holds and no
## reader needs, and never waits for a lock. The checkpointer of a pool calls it on a connection of its own, and a
## commit at the cap on its own. A connection of the FFI driver does nothing.
export def checkpoint(conn: Connection, plan: Checkpoints) -> Void
  case conn.link
    Link.Native(native, _) -> SqliteNative.checkpoint(native, plan.wal)
    Link.Ffi(_) -> return
  end
end

## Closes the connection; closing it again does nothing. Closing the last connection of a WAL database checkpoints
## it, which can take a while: this call blocks the task meanwhile.
export def close(conn: Connection) -> Void
  case conn.link
    Link.Native(native, _) -> Native.close(native)
    Link.Ffi(handle) -> Native.close(handle)
  end
end

## Runs one statement with bound parameters and gives its rows, which are empty for a statement without a result.
## Two columns with one name are an error: alias them. `timeout_ms` is the limit of this call: -1 takes the one of the
## connection, 0 is none.
export def query(conn: Connection, sql: String, params: List[Value], timeout_ms: Int = -1) -> Result[List[Row]]
  return bounded(conn, timeout_ms) do |run| run_query(run, sql, params) end
end

## Runs one statement with bound parameters and gives the number of rows it inserted, updated or deleted.
## `timeout_ms` is as in `query`.
export def execute(conn: Connection, sql: String, params: List[Value], timeout_ms: Int = -1) -> Result[Int]
  return bounded(conn, timeout_ms) do |run| run_execute(run, sql, params) end
end

## Whether a transaction is open, which SQLite knows without asking the database. A closed connection is not in one.
export def in_transaction?(conn: Connection) -> Bool
  if closed?(conn.link)
    return false
  end

  case conn.link
    Link.Native(native, _) ->
      # A cancelled query may have left a write that SQLite never ended, a transaction that autocommit does not show.
      SqliteNative.settle(native)
      return not SqliteNative.autocommit?(native)
    Link.Ffi(handle) -> return SqliteFfi.sqlite3_get_autocommit(handle) == 0
  end
end

## Whether the connection is open. SQLite has no link that can be lost, so a closed handle is all there is to know
## without running a statement.
export def connected?(conn: Connection) -> Bool
  return not closed?(conn.link)
end

## Stops the statement that is running on the connection, if any, which then fails with `sqlite error 9: interrupted`.
## A pool calls it when a block outlives its lease: `close` waits for a running statement, and this lets it end.
## An interrupt while no statement runs does nothing. Not for `Db`: only the pool reaches it.
export def interrupt(conn: Connection) -> Void
  if not closed?(conn.link)
    interrupt_link(conn.link)
  end
end

## Whether the connection works: it is open and answers `SELECT 1`.
export def healthy?(conn: Connection) -> Bool
  if closed?(conn.link)
    return false
  end

  return run_query(conn, "SELECT 1", []).ok?
end

## The connection in the line of writers `turn`, a channel that holds one token, which a pool gives to its connections.
## A writer waits for its turn up to `busy_timeout`, the time it would wait for SQLite's lock, and at most half of
## `lease_ms`: the lease counts from the start of the block, and must not end a writer that waits.
export def with_gate(conn: Connection, turn: Channel[Int], lease_ms: Int) -> Connection
  wait_ms = conn.busy_timeout
  if wait_ms > lease_ms / 2
    wait_ms = lease_ms / 2
  end

  held: Channel[Int] = Channel.new(1)
  return conn.with(gate: some(Gate(turn: turn, held: held, wait_ms: wait_ms)))
end

## Waits for the turn of this writer and gives the connection for its BEGIN. A wait that ends without the turn (a
## writer of the pool holds it longer, or one checked out inside its own transaction waits for itself) has spent the
## time of `busy_timeout`, so the BEGIN does not wait for SQLite's lock again: it takes the lock if it is free, and
## fails with `sqlite error 5: database is locked` if not, as after `busy_timeout` without the line.
export def enter_gate(conn: Connection) -> Connection
  case conn.gate
    none -> return conn
    some(gate) ->
      case gate.turn.recv(gate.wait_ms)
        ok(_) ->
          # A cancel that lands between the recv and this send loses the token: later writers then wait `wait_ms`
          # and go on to SQLite's lock, which is right but slow. Neither call parks, so it can land only there.
          _ = gate.held.send(1, 0)
          return conn
        error(_) -> return conn.with(busy_timeout: 0)
      end
  end
end

## Gives the turn back if this connection holds it, and only then: a writer that waited in vain, or a block that ended
## before its transaction, has no token to give, and the line never has more than one.
export def leave_gate(conn: Connection) -> Void
  case conn.gate
    none -> return
    some(gate) ->
      if gate.held.recv(0).ok?
        # The same window as in enter_gate: a cancel that lands here loses the token, and later writers wait `wait_ms`.
        _ = gate.turn.send(1, 0)
      end
  end
end

## The statement cache of a connection of the native driver; none for the FFI driver, which has none.
export def statement_cache(conn: Connection) -> Optional[SqliteNative.CacheStats]
  case conn.link
    Link.Native(native, _) -> return some(SqliteNative.cache_stats(native))
    Link.Ffi(_) -> return none
  end
end

# The driver that the variable names, else the native one when its library loads, else the FFI one.
def connect(target: SqliteUrl.Target) -> Result[Link]
  choice = System.env(DRIVER_VARIABLE).unwrap_or("")
  if choice == "ffi" or (choice == "" and not SqliteNative.available?())
    handle = try SqliteFfi.open(target.path, OPEN_FLAGS)
    return ok(Link.Ffi(handle))
  end

  if choice != "" and choice != "native"
    return error("sqlite error: #{DRIVER_VARIABLE} is #{choice}, expected native or ffi")
  end

  if not SqliteNative.available?()
    return error("sqlite error: the native driver is not built (#{DRIVER_VARIABLE}=native)")
  end

  settings = target.settings
  native = try SqliteNative.open(target.path, OPEN_FLAGS, settings.statement_cache)
  fetch = SqliteNative.Fetch(rows: settings.batch_rows, bytes: settings.batch_bytes)
  return ok(Link.Native(native, fetch))
end

# The connection with a native driver that does not cache the statements it runs: the pragmas of `open` run once.
def uncached(conn: Connection) -> Connection
  case conn.link
    Link.Native(native, fetch) -> return conn.with(link: Link.Native(native, fetch.with(cache: false)))
    Link.Ffi(_) -> return conn
  end
end

def closed?(link: Link) -> Bool
  case link
    Link.Native(native, _) -> return Native.closed?(native)
    Link.Ffi(handle) -> return Native.closed?(handle)
  end
end

def interrupt_link(link: Link) -> Void
  case link
    Link.Native(native, _) -> SqliteNative.interrupt(native)
    Link.Ffi(handle) -> SqliteFfi.sqlite3_interrupt(handle)
  end
end

def run_query(conn: Connection, sql: String, params: List[Value]) -> Result[List[Row]]
  if has_nul?(sql)
    return error(NUL_SQL)
  end

  wait = wait_of(conn)
  case conn.link
    Link.Native(native, fetch) ->
      done = try SqliteNative.query(native, wait, sql, params, fetch)
      after_commit(conn, done.frames)
      return ok(done.rows)
    Link.Ffi(handle) -> return SqliteFfi.query(handle, wait, sql, params)
  end
end

def run_execute(conn: Connection, sql: String, params: List[Value]) -> Result[Int]
  if has_nul?(sql)
    return error(NUL_SQL)
  end

  wait = wait_of(conn)
  case conn.link
    Link.Native(native, fetch) ->
      done = try SqliteNative.execute(native, wait, sql, params, fetch)
      after_commit(conn, done.frames)
      return ok(done.changes)
    Link.Ffi(handle) -> return SqliteFfi.execute(handle, wait, sql, params)
  end
end

# A commit that left `frames` frames that no checkpoint has copied in the WAL of a connection whose pool takes its
# checkpoints: at the cap it checkpoints here, on the compute pool, and a writer of the pool still holds the turn of
# the writers meanwhile, so the WAL cannot grow past the cap by more than one transaction (while no reader holds an
# older snapshot); at the mark it wakes the checkpointer of the pool. The commit is done either way: a checkpoint that
# fails (another one runs) changes nothing.
def after_commit(conn: Connection, frames: Int) -> Void
  case conn.checkpoints
    none -> return
    some(plan) ->
      if frames >= plan.cap
        checkpoint(conn, plan)
      elsif frames >= plan.frames
        _ = plan.nudge.send(1, 0)
      end
  end
end

def wait_of(conn: Connection) -> SqliteWait.Wait
  return SqliteWait.Wait(busy_timeout: conn.busy_timeout, deadline: conn.deadline)
end

# Runs `body` with the limit of the call. With a limit, a watchdog task interrupts the statement when the time is over
# and the waits for a lock stop at the same deadline. The watchdog is cancelled and awaited before the call returns:
# an interrupt that came after the statement ended would be taken by the next one. It is a `Result[Void]` task so that
# the await of a cancelled one is a value.
def bounded[R](conn: Connection, timeout_ms: Int, body: Fn[Connection, Result[R]]) -> Result[R]
  limit = timeout_ms
  if limit < 0
    limit = conn.timeout_ms
  end

  if limit == 0
    return body.call(conn)
  end

  deadline = Time.monotonic_ms() + limit
  watchdog_task = Task.spawn(&watchdog, Watch(link: conn.link, ms: limit))
  done = body.call(conn.with(deadline: deadline))
  Task.cancel(watchdog_task)
  _ = Task.await(watchdog_task)
  return timed_out(done, limit, deadline)
end

def watchdog(watch: Watch) -> Result[Void]
  Task.sleep(watch.ms)
  interrupt_link(watch.link)
  return ok()
end

# A lock that was still held when the deadline stopped the wait is a timeout like an interrupt.
def timed_out[R](done: Result[R], limit: Int, deadline: Int) -> Result[R]
  case done
    ok(_) -> return done
    error(message) ->
      busy = message.start_with?("sqlite error #{SqliteLock.SQLITE_BUSY}:")
      locked = busy or message.start_with?("sqlite error #{SqliteWait.SQLITE_LOCKED}:")
      if locked and Time.monotonic_ms() >= deadline
        return error("#{SqliteWait.INTERRUPTED}, the timeout of #{limit} ms ended while waiting for a lock")
      end

      return done
  end
end

def configure(conn: Connection, settings: SqliteUrl.Settings) -> Result[Journal]
  if settings.fts5 and not fts5?(conn)
    return error("sqlite error: this SQLite was built without FTS5 (fts5=required)")
  end

  # Set in both cases: a build can turn foreign keys on by default.
  try run_execute(conn, "PRAGMA foreign_keys = #{on_off(settings.foreign_keys)}", [])
  mode = try set_journal_mode(conn, settings)
  level = try set_synchronous(conn, settings, mode)
  try run_query(conn, "PRAGMA mmap_size = #{settings.mmap_size}", [])
  try run_query(conn, "PRAGMA cache_size = #{settings.cache_size}", [])
  try run_query(conn, "PRAGMA journal_size_limit = #{settings.journal_size_limit}", [])
  return ok(Journal(mode: mode, synchronous: level))
end

# A connection of the native driver in WAL mode runs its cheap writes inside a transaction, and its BEGIN, in short
# calls: there such a write syncs no file and takes no lock that it waits for. In the other modes a write can sync the
# journal when the page cache spills, so they stay on the compute pool.
def with_journal(conn: Connection, journal: Journal) -> Connection
  if journal.mode != "wal"
    return conn
  end

  case conn.link
    Link.Native(native, _) ->
      SqliteNative.inline_writes(native, false)
      quiet = journal.synchronous == "normal" or journal.synchronous == "off"
      return conn.with(wal: true, sync_commits: not quiet)
    Link.Ffi(_) -> return conn
  end
end

# NORMAL in WAL does not sync the WAL file at each commit, only at a checkpoint: a power loss (not a crash of the
# process) can lose the last commits, but never corrupts the database. That is why it is the default only there; in
# the other modes SQLite's own FULL stays, and a url that names the level always wins. `mode` is the journal mode in
# force, empty when it is not known (a database that cannot be written, which has nothing to sync). It gives the level
# set, empty when SQLite's own stays.
def set_synchronous(conn: Connection, settings: SqliteUrl.Settings, mode: String) -> Result[String]
  level = settings.synchronous
  if level.empty? and mode == "wal"
    level = "normal"
  end

  if level.empty?
    return ok("")
  end

  try run_execute(conn, "PRAGMA synchronous = #{level.upcase}", [])
  return ok(level)
end

def on_off(flag: Bool) -> String
  if flag
    return "ON"
  end

  return "OFF"
end

# The pragma answers with the mode in force. A memory database stays in `memory` whatever is asked, which is fine;
# any other answer means the mode did not change. When the url did not name a journal mode, the default WAL is
# best effort in two cases, so a url that worked before still opens: a database that cannot be written (code 8: a
# read-only file or `mode=ro`), and a `file:` URI, whose own parameters (`immutable=1`, `nolock=1`, `vfs=unix-none`)
# can rule WAL out. A plain path that cannot take WAL (a file system without shared memory) is an error, since a web
# app would rather stop at startup than run in another mode. An explicit journal_mode is always an error. It gives
# the mode in force (empty when the pragma was skipped).
def set_journal_mode(conn: Connection, settings: SqliteUrl.Settings) -> Result[String]
  mode = settings.journal_mode
  asked = run_query(conn, "PRAGMA journal_mode = #{mode.upcase}", [])
  case asked
    error(message) ->
      if not settings.journal_given and message.start_with?("sqlite error #{SQLITE_READONLY}:")
        return ok("")
      end

      return error(message)

    ok(rows) ->
      answer = "unknown"
      if not rows.empty?
        case rows[0].get("journal_mode", Value.Null)
          Value.Text(text) -> answer = text
          _ -> answer = "unknown"
        end
      end

      if answer != mode and answer != "memory" and not (settings.uri and not settings.journal_given)
        return error("sqlite error: journal_mode #{mode} could not be set, the database is in #{answer} mode")
      end

      return ok(answer)
  end
end

# Tries to create an FTS5 table in the temp schema, which no file keeps.
def fts5?(conn: Connection) -> Bool
  made = run_execute(conn, "CREATE VIRTUAL TABLE temp.agentica_fts5_probe USING fts5(x)", [])
  if not made.ok?
    return false
  end

  _ = run_execute(conn, "DROP TABLE temp.agentica_fts5_probe", [])
  return true
end

# A NUL ends a C.String early, and the VM stops the program at the call (RUNTIME-INVALID-CHARACTER); SQLite would read
# the native driver's sql only up to it.
def has_nul?(text: String) -> Bool
  return text.include?(String.from_code(0))
end
