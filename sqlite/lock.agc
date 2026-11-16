## The rule of the SQLite adapter on which lock failures it waits for, apart from the connection so that a unit test
## can reach it. It reads extended error codes (`sqlite3_extended_errcode`).

SQLITE_BUSY = 5

## Whether an extended error code is a lock that another connection will let go, which the adapter waits for:
## SQLITE_BUSY, its WAL recovery, and a table of a shared cache. A stale snapshot (517) and a table lock inside one
## connection (6) are not.
def waitable?(extended: Int) -> Bool
  extended == SQLITE_BUSY or extended == SQLITE_BUSY_RECOVERY or extended == SQLITE_LOCKED_SHAREDCACHE
end

## Whether an extended error code is SQLITE_BUSY itself, with no sub-code: the failure of a write that a connection
## with a read transaction asks for while another connection holds the write lock.
def plain_busy?(extended: Int) -> Bool = extended == SQLITE_BUSY

private

# The extended codes that mean "wait and try again": a WAL that another connection is recovering, and a table of a
# shared cache held by another connection. SQLITE_BUSY_SNAPSHOT (517) is not one of them: the snapshot of a read
# transaction is stale for good, and only a rollback helps.
SQLITE_BUSY_RECOVERY = 261
SQLITE_LOCKED_SHAREDCACHE = 262
