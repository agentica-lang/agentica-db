## The wait of a SQLite statement that finds a lock, which both drivers (`ffi.agc` and `native.agc`) share. The wait is
## made here and not by SQLite (its busy timeout stays 0): a call on the compute pool that sleeps in SQLite's busy
## handler holds one of its threads, which has one per scheduler, so the writers that wait would keep the writer that
## holds the lock from finishing. Here the task sleeps and its thread is free.

import SqliteLock from "lock"

export SQLITE_LOCKED = 6
export SQLITE_INTERRUPT = 9
## The text of a statement that SQLite interrupted, or that did not start because its deadline had passed.
export INTERRUPTED = "sqlite error 9: interrupted"
# The sleep between two tries starts at 1 ms, grows with the time already waited and stops at 25 ms.
MAX_PAUSE_MS = 25

## How long a statement waits for a lock: `busy_timeout` ms from its first refusal, and never past `deadline` (a
## `Time.monotonic_ms`, 0 for none), the end of the `timeout_ms` of the call.
export struct Wait
  busy_timeout: Int
  deadline: Int = 0
end

## Whether a result code is SQLITE_BUSY or SQLITE_LOCKED, the two that can be a lock of another connection.
export def lock_code?(code: Int) -> Bool = code == SqliteLock.SQLITE_BUSY or code == SQLITE_LOCKED

## True when `code` (with its `extended` code) says that another connection holds a lock and the wait that began at
## `started` is not over, so the caller pauses and tries again.
export def lock_wait?(wait: Wait, code: Int, extended: Int, started: Int) -> Bool
  return false if not lock_code?(code) or not SqliteLock.waitable?(extended)

  now = Time.monotonic_ms()
  return false if wait.deadline > 0 and now >= wait.deadline

  now - started < wait.busy_timeout
end

## Whether the deadline of the call has passed. An interrupt that came before the first step is lost (SQLite ignores
## one while no statement runs), so the drivers ask this before it.
export def expired?(wait: Wait) -> Bool = wait.deadline > 0 and Time.monotonic_ms() >= wait.deadline

## Sleeps a little: the task parks, so its thread of the compute pool is free for the connection that holds the lock.
## The sleep never goes past the end of the wait, nor the deadline of the call.
export def pause(wait: Wait, started: Int) -> Void
  now = Time.monotonic_ms()
  waited = now - started
  length = waited / 4 + 1
  if length > MAX_PAUSE_MS
    length = MAX_PAUSE_MS
  end

  left = wait.busy_timeout - waited
  if wait.deadline > 0 and wait.deadline - now < left
    left = wait.deadline - now
  end

  if length > left
    length = left
  end

  if length < 1
    length = 1
  end

  Task.sleep(length)
end
