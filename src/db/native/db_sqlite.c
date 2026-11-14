/*
 * The native SQLite driver of agentica-db: an Agentica native module (agentica_native.h) over the system SQLite.
 *
 * It opens libsqlite3 itself at the first `open` (libsqlite3.so.0, libsqlite3.dylib or winsqlite3.dll, the libraries
 * that the FFI adapter names), so building it needs only a C compiler: no SQLite headers, no import library, and one
 * `build` table for every system. The prototypes below are the stable C API of SQLite 3.
 *
 * A connection (resource Conn) keeps a bounded cache of prepared statements keyed by the sql text, finalized when they
 * are evicted and when the connection closes. A query runs in one call where it can:
 *   - quick, a short call on the scheduler, for a cached statement that only reads (SELECT, WITH, VALUES, a PRAGMA
 *     that sets nothing): it binds, steps and reads every row within a budget of SQLite VM instructions and a row and
 *     byte cap, or gives none (the budget ran out, the result is too big, a lock, or the connection is busy on another
 *     thread) and the caller runs fetch. The budget is counted, not timed: a clock read can be a system call.
 *     The same call runs a cached write whose plan bounds its own work (no scan of a table or an index, no trigger,
 *     no virtual table: see short_plan) and a BEGIN, in a WAL database (inline_writes); a write that commits (a
 *     COMMIT, or a write outside a transaction) only when the pool takes the checkpoints of the connection, so the
 *     commit never checkpoints, the commit does not sync the WAL, and the transaction ran only such writes
 *     (write_now). A write cannot be stopped midway (SQLite rolls back the whole transaction that an interrupted write
 *     is in), so it has no budget of instructions: its plan bounds it, and so do the instructions of its last run, at
 *     most QUICK_TXN_WRITES of them in a transaction, and a value or row of at most QUICK_BYTES (a longer one fails
 *     the statement alone, which fetch runs again). In a pool, no write runs there while a checkpoint runs or the WAL
 *     is to start again, which syncs it (wal_share). A lock comes back at once there, and the caller runs fetch.
 *     Accepted: a schema change by another connection between two runs makes SQLite prepare the statement again inside
 *     the step, so that one run follows a plan not read yet; the runs after it go to fetch, which reads it;
 *   - fetch, a dirty call on the compute pool, with a Cursor: it prepares (or takes the cached statement), binds,
 *     steps and reads up to the caps, and the next fetch goes on from there. A lock (SQLITE_BUSY, SQLITE_LOCKED) comes
 *     back at once with the rows so far, so the caller waits outside SQLite and fetches again.
 * Lock order: the lock of a connection (`conn.lock`) is never taken while SQLite's own mutex of the database is held
 * (the mutex may be taken under the lock: finalize does). The lock of a wal_share is taken last, under either, and
 * nothing is taken under it.
 */
#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#else
#if defined(__APPLE__)
#define _DARWIN_C_SOURCE
#else
#define _POSIX_C_SOURCE 200809L
#endif
#include <dlfcn.h>
#include <pthread.h>
#include <time.h>
#endif

#include <limits.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "agentica_native.h"

/* The SQLite C API that the driver uses. */
typedef struct sqlite3 sqlite3;
typedef struct sqlite3_stmt sqlite3_stmt;
typedef struct sqlite3_mutex sqlite3_mutex;
typedef long long sqlite3_int64;
typedef unsigned long long sqlite3_uint64;
typedef void (*sqlite3_destructor)(void *);

enum {
  SQLITE_OK = 0,
  SQLITE_ERROR = 1,
  SQLITE_BUSY = 5,
  SQLITE_LOCKED = 6,
  SQLITE_NOMEM = 7,
  SQLITE_INTERRUPT = 9,
  SQLITE_TOOBIG = 18,
  SQLITE_RANGE = 25,
  SQLITE_ROW = 100,
  SQLITE_DONE = 101,
  SQLITE_INTEGER = 1,
  SQLITE_FLOAT = 2,
  SQLITE_TEXT = 3,
  SQLITE_BLOB = 4,
  SQLITE_UTF8 = 1,
  SQLITE_TXN_NONE = 0,
  SQLITE_TXN_READ = 1,
  SQLITE_STMTSTATUS_VM_STEP = 4,
  SQLITE_DBSTATUS_CACHE_WRITE = 9,
  SQLITE_STMTSTATUS_REPREPARE = 5,
  SQLITE_OPEN_NOMUTEX = 0x8000,
  SQLITE_OPEN_FULLMUTEX = 0x10000,
};
/* sqlite3_txn_state came in 3.34.0; an older library does not have it, and a write is then waited for. */
#define TXN_STATE_VERSION 3034000
/* sqlite3_limit's id of the longest string, blob or row; sqlite3_wal_checkpoint_v2's mode that waits for nobody. */
#define SQLITE_LIMIT_LENGTH 0
#define SQLITE_CHECKPOINT_PASSIVE 0
#define SQLITE_TRANSIENT ((sqlite3_destructor)-1)

typedef struct {
  int (*libversion_number)(void);
  int (*open_v2)(const char *, sqlite3 **, int, const char *);
  int (*close_v2)(sqlite3 *);
  const char *(*errstr)(int);
  const char *(*errmsg)(sqlite3 *);
  int (*extended_errcode)(sqlite3 *);
  void (*interrupt)(sqlite3 *);
  int (*get_autocommit)(sqlite3 *);
  int (*changes)(sqlite3 *);
  int (*total_changes)(sqlite3 *);
  int (*prepare_v2)(sqlite3 *, const char *, int, sqlite3_stmt **, const char **);
  int (*finalize)(sqlite3_stmt *);
  int (*reset)(sqlite3_stmt *);
  int (*clear_bindings)(sqlite3_stmt *);
  int (*step)(sqlite3_stmt *);
  int (*stmt_readonly)(sqlite3_stmt *);
  int (*bind_parameter_count)(sqlite3_stmt *);
  int (*bind_null)(sqlite3_stmt *, int);
  int (*bind_int64)(sqlite3_stmt *, int, sqlite3_int64);
  int (*bind_double)(sqlite3_stmt *, int, double);
  int (*bind_text64)(sqlite3_stmt *, int, const char *, sqlite3_uint64, sqlite3_destructor, unsigned char);
  int (*bind_blob64)(sqlite3_stmt *, int, const void *, sqlite3_uint64, sqlite3_destructor);
  int (*bind_zeroblob)(sqlite3_stmt *, int, int);
  int (*column_count)(sqlite3_stmt *);
  const char *(*column_name)(sqlite3_stmt *, int);
  int (*column_type)(sqlite3_stmt *, int);
  sqlite3_int64 (*column_int64)(sqlite3_stmt *, int);
  double (*column_double)(sqlite3_stmt *, int);
  const unsigned char *(*column_text)(sqlite3_stmt *, int);
  const void *(*column_blob)(sqlite3_stmt *, int);
  int (*column_bytes)(sqlite3_stmt *, int);
  void (*progress_handler)(sqlite3 *, int, int (*)(void *), void *);
  sqlite3_mutex *(*db_mutex)(sqlite3 *);
  void (*mutex_enter)(sqlite3_mutex *);
  void (*mutex_leave)(sqlite3_mutex *);
  int (*mutex_try)(sqlite3_mutex *);
  int (*stmt_status)(sqlite3_stmt *, int, int);
  void *(*wal_hook)(sqlite3 *, int (*)(void *, sqlite3 *, const char *, int), void *);
  int (*wal_checkpoint_v2)(sqlite3 *, const char *, int, int *, int *);
  int (*limit)(sqlite3 *, int, int);
  int (*db_status)(sqlite3 *, int, int *, int *, int);
  /* Optional: NULL in a library older than 3.34.0. */
  int (*txn_state)(sqlite3 *, const char *);
} sqlite_api;

static sqlite_api sq;

/* The symbols of sqlite_api in its order, each with the offset of its field; the last one is optional. */
#define SYM(NAME, FIELD) {"sqlite3_" NAME, offsetof(sqlite_api, FIELD)}
static const struct {
  const char *name;
  size_t offset;
} SYMBOLS[] = {
  SYM("libversion_number", libversion_number),
  SYM("open_v2", open_v2),
  SYM("close_v2", close_v2),
  SYM("errstr", errstr),
  SYM("errmsg", errmsg),
  SYM("extended_errcode", extended_errcode),
  SYM("interrupt", interrupt),
  SYM("get_autocommit", get_autocommit),
  SYM("changes", changes),
  SYM("total_changes", total_changes),
  SYM("prepare_v2", prepare_v2),
  SYM("finalize", finalize),
  SYM("reset", reset),
  SYM("clear_bindings", clear_bindings),
  SYM("step", step),
  SYM("stmt_readonly", stmt_readonly),
  SYM("bind_parameter_count", bind_parameter_count),
  SYM("bind_null", bind_null),
  SYM("bind_int64", bind_int64),
  SYM("bind_double", bind_double),
  SYM("bind_text64", bind_text64),
  SYM("bind_blob64", bind_blob64),
  SYM("bind_zeroblob", bind_zeroblob),
  SYM("column_count", column_count),
  SYM("column_name", column_name),
  SYM("column_type", column_type),
  SYM("column_int64", column_int64),
  SYM("column_double", column_double),
  SYM("column_text", column_text),
  SYM("column_blob", column_blob),
  SYM("column_bytes", column_bytes),
  SYM("progress_handler", progress_handler),
  SYM("db_mutex", db_mutex),
  SYM("mutex_enter", mutex_enter),
  SYM("mutex_leave", mutex_leave),
  SYM("mutex_try", mutex_try),
  SYM("stmt_status", stmt_status),
  SYM("wal_hook", wal_hook),
  SYM("wal_checkpoint_v2", wal_checkpoint_v2),
  SYM("limit", limit),
  SYM("db_status", db_status),
  SYM("txn_state", txn_state),
};
#define SYMBOL_COUNT (sizeof SYMBOLS / sizeof SYMBOLS[0])

/* ---- The system: the library loader and a mutex. ---- */

static char load_error[512];

#if defined(_WIN32)
typedef SRWLOCK lock_t;
static void lock_init(lock_t *l) { InitializeSRWLock(l); }
static void lock_destroy(lock_t *l) { (void)l; }
static void lock_take(lock_t *l) { AcquireSRWLockExclusive(l); }
static bool lock_try(lock_t *l) { return TryAcquireSRWLockExclusive(l) != 0; }
static void lock_drop(lock_t *l) { ReleaseSRWLockExclusive(l); }


static void *library;
static INIT_ONCE load_once = INIT_ONCE_STATIC_INIT;

static void *symbol(const char *name) {
  FARPROC p = GetProcAddress((HMODULE)library, name);
  void *out;
  memcpy(&out, &p, sizeof out);
  return out;
}

static bool open_library(void) {
  /* Only the system folder: winsqlite3.dll ships there, and no other folder may plant one. */
  library = (void *)LoadLibraryExW(L"winsqlite3.dll", NULL, LOAD_LIBRARY_SEARCH_SYSTEM32);
  if (!library) snprintf(load_error, sizeof load_error, "winsqlite3.dll: error %lu", (unsigned long)GetLastError());
  return library != NULL;
}

static bool load_symbols(void);
static BOOL CALLBACK load_callback(PINIT_ONCE once, PVOID parameter, PVOID *context) {
  (void)once;
  (void)parameter;
  (void)context;
  (void)load_symbols();
  return TRUE;
}
static void load_library_once(void) { InitOnceExecuteOnce(&load_once, load_callback, NULL, NULL); }
#else
typedef pthread_mutex_t lock_t;
/* A mutex that fails to set up or to lock is a broken process (EINVAL, EAGAIN): there is no state to go back to. */
static void lock_init(lock_t *l) {
  if (pthread_mutex_init(l, NULL) != 0) abort();
}
static void lock_destroy(lock_t *l) { (void)pthread_mutex_destroy(l); }
static void lock_take(lock_t *l) {
  if (pthread_mutex_lock(l) != 0) abort();
}
static bool lock_try(lock_t *l) { return pthread_mutex_trylock(l) == 0; }
static void lock_drop(lock_t *l) {
  if (pthread_mutex_unlock(l) != 0) abort();
}


static void *library;
static pthread_once_t load_once = PTHREAD_ONCE_INIT;

static void *symbol(const char *name) { return dlsym(library, name); }

static bool open_library(void) {
#if defined(__APPLE__)
  /* dyld searches a bare name in the working directory too, where anyone could plant one; /usr/lib (on disk or in the
     dyld shared cache) is where the system's lives. */
  const char *name = "/usr/lib/libsqlite3.dylib";
#else
  /* dlopen never searches the working directory for a bare name on Linux. */
  const char *name = "libsqlite3.so.0";
#endif
  library = dlopen(name, RTLD_NOW | RTLD_LOCAL);
  if (!library) {
    const char *why = dlerror();
    snprintf(load_error, sizeof load_error, "%s", why ? why : name);
  }
  return library != NULL;
}

static bool load_symbols(void);
static void load_callback(void) { (void)load_symbols(); }
static void load_library_once(void) {
  if (pthread_once(&load_once, load_callback) != 0) abort();
}
#endif

/* Opens the library and fills `sq`, once per run; load_error says why when it failed. */
static bool load_symbols(void) {
  if (!open_library()) return false;
  for (size_t i = 0; i < SYMBOL_COUNT; i++) {
    void *p = symbol(SYMBOLS[i].name);
    bool optional = i + 1 == SYMBOL_COUNT;
    if (!p && !optional) {
      snprintf(load_error, sizeof load_error, "the library has no %s", SYMBOLS[i].name);
      return false;
    }
    /* POSIX and Windows give a function's address as an object pointer; every field is a function pointer. */
    memcpy((char *)&sq + SYMBOLS[i].offset, &p, sizeof p);
  }
  return true;
}

static bool library_ready(void) {
  load_library_once();
  return load_error[0] == '\0';
}

/* ---- The WAL of a pool. ---- */

/* What the connections of a pool and its checkpointer share about their WAL (the Wal resource). A commit that
   writes the first frame of the WAL also writes its header and syncs it, a disk flush even with synchronous NORMAL,
   so it must not run in a short call. That happens to a new WAL, and once a checkpoint has copied every frame: the
   next writer whose snapshot has every frame copied starts the WAL again from its first frame.
   - `hold` counts the reasons that no connection of the pool may write in a short call: each checkpoint while it
     runs, and `restart`.
   - `inflight` counts the short calls that run a write now (share_enter, share_leave). A checkpoint holds first and
     then waits for them to end, so that none takes its snapshot after the checkpoint and commits in a short call:
     share_enter counts itself before it looks at `hold`, and the checkpoint holds before it looks at `inflight`
     (sequentially consistent atomics), so at least one of them sees the other.
   - `restart` is set by a checkpoint that copied every frame (and for a new WAL), and keeps that checkpoint's hold.
     The first commit that starts after it ends it (share_committed): that commit starts the WAL again or appends to
     it, and either way no writer after it can start it again before another checkpoint.
   - `gen` counts the checkpoints that copied every frame, so that a commit that started before one does not end the
     hold that it left.
   - `copied` is the count of frames that the last checkpoint left copied, and `last` the frames in the WAL after the
     last commit, so that a commit tells how many frames of the WAL no checkpoint has copied yet: those past
     `copied`, or all of them once the WAL may have started again.
   - `stuck` is set for good by a PRAGMA that checkpoints or changes the checkpoints on a connection of the pool
     (wal_checkpoint, wal_autocheckpoint), which the share does not see.
   `hold`, `inflight`, `stuck` and `gen` are atomics, read without the lock (a short call never waits for it, and every
   step reads `gen`); `lock` guards the updates of `hold`, `restart`, `gen`, `copied`, `last` and `refs`. It is held
   for a few instructions, never while SQLite's mutex is wanted. */
typedef struct {
  lock_t lock;
  int refs;
  atomic_int hold;
  atomic_int inflight;
  atomic_bool stuck;
  atomic_uint_fast64_t gen;
  bool restart;
  int copied, last;
} wal_share;

/* A new share, for a WAL that may be empty: its first commit holds. NULL when out of memory. */
static wal_share *share_new(void) {
  wal_share *s = calloc(1, sizeof *s);
  if (!s) return NULL;
  lock_init(&s->lock);
  s->refs = 1;
  atomic_init(&s->hold, 1);
  atomic_init(&s->inflight, 0);
  atomic_init(&s->stuck, false);
  atomic_init(&s->gen, 0);
  s->restart = true;
  return s;
}

static void share_ref(wal_share *s) {
  lock_take(&s->lock);
  s->refs++;
  lock_drop(&s->lock);
}

static void share_unref(wal_share *s) {
  lock_take(&s->lock);
  bool last = --s->refs == 0;
  lock_drop(&s->lock);
  if (!last) return;
  lock_destroy(&s->lock);
  free(s);
}

/* A short call may write when nothing holds the writes: then it counts in `inflight` until share_leave. It never
   waits. */
static bool share_enter(wal_share *s) {
  atomic_fetch_add(&s->inflight, 1);
  if (atomic_load(&s->hold) == 0 && !atomic_load(&s->stuck)) return true;
  atomic_fetch_sub(&s->inflight, 1);
  return false;
}

static void share_leave(wal_share *s) { atomic_fetch_sub(&s->inflight, 1); }

static uint64_t share_gen(wal_share *s) { return (uint64_t)atomic_load(&s->gen); }

/* A moment of the compute pool's thread, while a checkpoint waits for the short writes that run to end. */
static void pause_briefly(void) {
#if defined(_WIN32)
  Sleep(0);
#else
  struct timespec t = {0, 50000};
  (void)nanosleep(&t, NULL);
#endif
}

/* A checkpoint starts: it holds the short writes until share_checkpointed, and waits for those that run (each a
   bounded write, which never waits itself). On the compute pool. */
static void share_checkpoint(wal_share *s) {
  lock_take(&s->lock);
  atomic_fetch_add(&s->hold, 1);
  lock_drop(&s->lock);
  while (atomic_load(&s->inflight) > 0) pause_briefly();
}

/* A checkpoint ended, with COPIED frames of the WAL copied (-1: it failed). One that copied every frame (WHOLE)
   leaves its hold to `restart`, or gives it back when `restart` holds already; any other gives it back. */
static void share_checkpointed(wal_share *s, bool whole, int copied) {
  lock_take(&s->lock);
  if (copied >= 0) s->copied = copied;
  if (whole) atomic_fetch_add(&s->gen, 1);
  if (whole && !s->restart)
    s->restart = true;
  else
    atomic_fetch_sub(&s->hold, 1);
  lock_drop(&s->lock);
}

/* A commit of a connection of the pool left FRAMES frames in the WAL; GEN is what share_gen gave before its step. The
   frames that no checkpoint has copied. A commit that ends `restart` may have started the WAL again, whatever its
   frames, and so may one with fewer frames than the last (or two commits that report out of order): `copied` then
   counts nothing, which only counts more frames, and so checkpoints sooner. */
static int share_committed(wal_share *s, uint64_t gen, int frames) {
  lock_take(&s->lock);
  bool again = frames < s->last;
  if (s->restart && (uint64_t)atomic_load(&s->gen) == gen) {
    s->restart = false;
    atomic_fetch_sub(&s->hold, 1);
    again = true;
  }
  if (again) s->copied = 0;
  s->last = frames;
  int uncopied = frames > s->copied ? frames - s->copied : frames;
  lock_drop(&s->lock);
  return uncopied;
}

static void share_stick(wal_share *s) { atomic_store(&s->stuck, true); }

/* ---- Connections and their statement cache. ---- */

/* What a short call may run of a cached statement (entry.kind): nothing, a read, a write, a BEGIN or a COMMIT. */
enum { K_NONE, K_READ, K_WRITE, K_BEGIN, K_COMMIT };

/* A cached statement. `busy` while a call or a Cursor runs it; `kind` is what a short call may run of it (classify),
   as read when SQLite had prepared it again `checked` times (after a schema change; -1: not read yet). `dirty` when
   a free function gave it back without its reset, which the next fetch makes. `steps` is the count of SQLite VM
   instructions of its last run (INT_MAX before the first one ends), which a write must keep within the budget of a
   short call. `long_value` is set for good once a run of a write made a value or row past QUICK_BYTES, or rows past
   the caps (a cost of INT_MAX): the short calls leave it to fetch, until SQLite prepares it again. A read is not
   marked: a short call stops it at the caps, and the next key may give a small result. */
typedef struct {
  char *sql;
  size_t len;
  uint64_t hash;
  sqlite3_stmt *stmt;
  uint64_t used;
  bool busy;
  unsigned char kind;
  bool dirty;
  int checked;
  int steps;
  bool long_value;
} entry;

/* A statement that a free function could not finalize, left for the next fetch or the last free. */
typedef struct orphan {
  sqlite3_stmt *stmt;
  struct orphan *next;
} orphan;

/* The C state of a connection, shared by its Conn and its Cursors, and freed when the last of them is (`refs`).
   `lock` guards refs, closed, the entries, the orphans, `pending` (the dirty entries and the orphans), `level` (the
   writes that a short call may run), `hooked` and the counters. quick_left and quick_over belong to the quick call
   that holds SQLite's mutex of the database, the only place they are written, so the progress handler (which runs
   inside sqlite3_step, under that mutex) reads them safely. `frames` (what the WAL hook saw) and `txn_writes` (the
   steps of writes in the open transaction, TXN_HEAVY once one ran on the compute pool) are read and written only under
   that mutex too, and so is `share` (the WAL of the pool, set once by own_checkpoints), which the connection holds a
   reference to. */
typedef struct {
  lock_t lock;
  int refs;
  bool closed;
  sqlite3 *db;
  entry *entries;
  int capacity;
  orphan *orphans;
  int pending;
  uint64_t tick, hits, misses, evictions, shorts, fallbacks;
  int level;
  bool hooked;
  int64_t quick_left;
  bool quick_over;
  int frames;
  int txn_writes;
  wal_share *share;
} conn;

/* The writes that a short call may run (conn.level): none; a write inside a transaction and a BEGIN; also a write that
   commits. */
enum { W_NONE, W_TRANSACTION, W_COMMIT };

typedef struct {
  conn *c;
} conn_state;

/* A statement that a query runs over several fetch calls. `e` is its cache entry, NULL for a statement of its own. */
typedef struct {
  conn *c;
  sqlite3_stmt *stmt;
  entry *e;
  bool started;
  int64_t bytes;
} cursor_state;

/* The state of a Wal resource: its reference to the share. */
typedef struct {
  wal_share *s;
} wal_state;

/* The largest statement cache, as the url's statement_cache allows (sqlite/url.agc). */
#define MAX_CACHE 10000
/* How often the progress handler runs, in SQLite VM instructions: a few microseconds of work. */
#define PROGRESS_OPS 200
/* The bytes that a value costs besides its text or blob, for the byte cap of a batch. */
#define VALUE_COST 16
/* A transaction whose COMMIT may run in a short call wrote in at most this many steps of short calls: its commit then
   writes the few pages that such writes touch to the WAL. A write on the compute pool makes it TXN_HEAVY. */
#define QUICK_TXN_WRITES 64
#define TXN_HEAVY INT_MAX
/* What a short call may read at most, whatever the batch allows: a bigger row is copied on the compute pool. It is
   also the longest value or row that a short call makes (SQLITE_LIMIT_LENGTH), and the most bytes of rows that a
   write may have given in its last run to run in one. */
#define QUICK_BYTES 262144

static int progress(void *arg) {
  conn *c = arg;
  if (c->quick_left == 0 || --c->quick_left > 0) return 0;
  c->quick_over = true;
  return 1;
}

/* The WAL hook of a connection whose pool takes its checkpoints (own_checkpoints). It replaces SQLite's
   autocheckpoint, which would checkpoint inside the COMMIT, and only notes the frames in the WAL after the commit;
   the batch gives the adapter those that no checkpoint has copied (share_committed). SQLite calls it at the end of
   the step that committed, under its mutex of the database, where step() reads it. */
static int wal_frames(void *arg, sqlite3 *db, const char *name, int frames) {
  (void)db;
  /* An ATTACHed database has a WAL of its own, which the pool does not count. */
  if (name && strcmp(name, "main") == 0) ((conn *)arg)->frames = frames;
  return SQLITE_OK;
}

static uint64_t hash_text(const char *s, size_t n) {
  uint64_t h = 14695981039346656037ull;
  for (size_t i = 0; i < n; i++) h = (h ^ (unsigned char)s[i]) * 1099511628211ull;
  return h;
}

/* Finalizes the orphans; it waits for SQLite's mutex, so only a call on the compute pool or the last free (no one
   else holds the connection) makes it. */
static void finalize_orphans(conn *c) {
  lock_take(&c->lock);
  orphan *list = c->orphans;
  c->orphans = NULL;
  lock_drop(&c->lock);
  int count = 0;
  while (list) {
    orphan *next = list->next;
    /* finalize gives the error of the statement's last step, which no one asks for. */
    (void)sq.finalize(list->stmt);
    free(list);
    list = next;
    count++;
  }
  lock_take(&c->lock);
  c->pending -= count;
  lock_drop(&c->lock);
}

static void conn_unref(conn *c) {
  lock_take(&c->lock);
  bool last = --c->refs == 0;
  lock_drop(&c->lock);
  if (!last) return;
  /* The connection closed already (conn_free); the last orphan finalized closes its zombie. */
  finalize_orphans(c);
  for (int i = 0; i < c->capacity; i++) free(c->entries[i].sql);
  free(c->entries);
  if (c->share) share_unref(c->share);
  lock_destroy(&c->lock);
  free(c);
}

/* The cache entry of SQL that no one runs, marked busy; NULL on a miss or when it is busy. Under c->lock. */
static entry *find_idle(conn *c, const char *sql, size_t len, uint64_t hash) {
  for (int i = 0; i < c->capacity; i++) {
    entry *e = &c->entries[i];
    if (e->sql && !e->busy && e->hash == hash && e->len == len && memcmp(e->sql, sql, len) == 0) {
      e->busy = true;
      e->used = ++c->tick;
      return e;
    }
  }
  return NULL;
}

static bool cached(conn *c, const char *sql, size_t len, uint64_t hash) {
  for (int i = 0; i < c->capacity; i++) {
    entry *e = &c->entries[i];
    if (e->sql && e->hash == hash && e->len == len && memcmp(e->sql, sql, len) == 0) return true;
  }
  return false;
}

/* A letter in lowercase; any other byte as it is (`| 0x20` would make `_` a DEL). */
static char lower(char c) { return c >= 'A' && c <= 'Z' ? (char)(c | 0x20) : c; }

/* Where SQL goes on from I past white space and comments: a line comment (two dashes, to the end of the line) and a
   block comment (slash and star, to star and slash, or to the end of the text as SQLite allows). */
static size_t skip_space(const char *sql, size_t len, size_t i) {
  for (;;) {
    while (i < len && (sql[i] == ' ' || (sql[i] >= '\t' && sql[i] <= '\r'))) i++;
    if (i + 1 < len && sql[i] == '-' && sql[i + 1] == '-') {
      while (i < len && sql[i] != '\n') i++;
    } else if (i + 1 < len && sql[i] == '/' && sql[i + 1] == '*') {
      i += 2;
      while (i < len && !(sql[i] == '*' && i + 1 < len && sql[i + 1] == '/')) i++;
      i = i < len ? i + 2 : len;
    } else {
      return i;
    }
  }
}

/* Whether SQL starts with WORD (any case), as a whole word, after white space and comments; *AT is where the word
   ends. */
static bool starts_with_word(const char *sql, size_t len, const char *word, size_t *at) {
  size_t i = skip_space(sql, len, 0), n = strlen(word), k = 0;
  while (k < n && i + k < len && lower(sql[i + k]) == word[k]) k++;
  if (k != n) return false;
  *at = i + n;
  if (*at == len) return true;
  char next = (char)(sql[*at] | 0x20);
  return !(next >= 'a' && next <= 'z') && sql[*at] != '_';
}

static bool blank(const char *s, const char *end) {
  while (s < end && (*s == ' ' || (*s >= '\t' && *s <= '\r'))) s++;
  return s == end;
}

/* Whether SQL from *AT starts with WORD as a whole word; *AT moves past it when it does. */
static bool take_word(const char *sql, size_t len, size_t *at, const char *word) {
  size_t end;
  if (!starts_with_word(sql + *at, len - *at, word, &end)) return false;
  *at += end;
  return true;
}

/* Whether nothing but white space, comments and one `;` follows AT. */
static bool ends_at(const char *sql, size_t len, size_t at) {
  size_t rest = skip_space(sql, len, at);
  if (rest < len && sql[rest] == ';') rest++;
  return skip_space(sql, len, rest) == len;
}

/* Whether a statement that only reads may run in a short call: a SELECT, WITH or VALUES, or one of the PRAGMAs that
   read a counter (`PRAGMA data_version`, `user_version`), with nothing after it but a `;`. A short call can be stopped
   and run again from its start (the progress handler interrupts it), which only a statement without effects allows;
   another PRAGMA may have effects or run long in one instruction. */
static bool quick_text(const char *sql, size_t len) {
  static const char *const words[] = {"select", "with", "values"};
  static const char *const pragmas[] = {"data_version", "user_version"};
  size_t at = 0;
  for (size_t w = 0; w < sizeof words / sizeof words[0]; w++)
    if (take_word(sql, len, &at, words[w])) return true;
  if (!take_word(sql, len, &at, "pragma")) return false;
  for (size_t w = 0; w < sizeof pragmas / sizeof pragmas[0]; w++)
    if (take_word(sql, len, &at, pragmas[w])) return ends_at(sql, len, at);
  return false;
}

/* K_BEGIN for `BEGIN [DEFERRED | IMMEDIATE] [TRANSACTION]`, K_COMMIT for `COMMIT` or `END [TRANSACTION]`, each with
   nothing after it but a `;`; else K_NONE. BEGIN EXCLUSIVE, ROLLBACK and the savepoints run on the compute pool. */
static unsigned char control_kind(const char *sql, size_t len) {
  size_t at = 0;
  if (take_word(sql, len, &at, "begin")) {
    if (!take_word(sql, len, &at, "deferred")) (void)take_word(sql, len, &at, "immediate");
    (void)take_word(sql, len, &at, "transaction");
    return ends_at(sql, len, at) ? K_BEGIN : K_NONE;
  }
  if (take_word(sql, len, &at, "commit") || take_word(sql, len, &at, "end")) {
    (void)take_word(sql, len, &at, "transaction");
    return ends_at(sql, len, at) ? K_COMMIT : K_NONE;
  }
  return K_NONE;
}

/* Whether a statement that writes may run in a short call by its words: an INSERT, UPDATE, DELETE or REPLACE (a
   WITH before it, a DDL statement or a PRAGMA never does). Its plan decides the rest (write_plan). */
static bool write_text(const char *sql, size_t len) {
  static const char *const words[] = {"insert", "update", "delete", "replace"};
  size_t at = 0;
  for (size_t w = 0; w < sizeof words / sizeof words[0]; w++)
    if (take_word(sql, len, &at, words[w])) return true;
  return false;
}

static bool distinct_names(sqlite3_stmt *stmt, int *repeated) {
  int n = sq.column_count(stmt);
  for (int i = 0; i < n; i++) {
    const char *a = sq.column_name(stmt, i);
    for (int j = 0; j < n; j++) {
      if (j == i) continue;
      const char *b = sq.column_name(stmt, j);
      if (a && b && strcmp(a, b) == 0) {
        *repeated = i;
        return false;
      }
    }
  }
  return true;
}

/* Puts a statement that was just prepared into the cache, evicting the one used least long ago that no one runs;
   the entry (marked busy), or NULL when the cache is off, full of busy statements, or already holds that sql. The
   evicted statement goes to *EVICTED, which the caller finalizes outside the lock. Under c->lock. */
static entry *insert(conn *c, const char *sql, size_t len, uint64_t hash, sqlite3_stmt *stmt,
                     sqlite3_stmt **evicted) {
  *evicted = NULL;
  if (c->capacity == 0 || cached(c, sql, len, hash)) return NULL;
  entry *slot = NULL;
  for (int i = 0; i < c->capacity && !slot; i++)
    if (!c->entries[i].sql) slot = &c->entries[i];
  if (!slot) {
    for (int i = 0; i < c->capacity; i++) {
      entry *e = &c->entries[i];
      if (!e->busy && (!slot || e->used < slot->used)) slot = e;
    }
  }
  if (!slot) return NULL;
  char *copy = malloc(len ? len : 1);
  if (!copy) return NULL;
  memcpy(copy, sql, len);
  if (slot->sql) {
    *evicted = slot->stmt;
    free(slot->sql);
    c->evictions++;
    /* Its finalize, which the caller makes, ends what its reset would. */
    if (slot->dirty) c->pending--;
  }
  *slot = (entry){copy, len, hash, stmt, ++c->tick, true, K_NONE, false, -1, INT_MAX, false};
  return slot;
}

#define NO_STEPS (-1)

/* The SQLite VM instructions of the run of STMT that ends, and the count starts again for the next one. Under
   SQLite's mutex of the database or on the compute pool: SQLite does not say that reading the counter never waits. */
static int run_steps(sqlite3_stmt *stmt) { return sq.stmt_status(stmt, SQLITE_STMTSTATUS_VM_STEP, 1); }

/* The cost of a run that ends (entry.steps): its instructions, or INT_MAX when its rows took more than QUICK_BYTES
   (the RETURNING of a write, which a short call cannot stop midway). Where run_steps may be called. */
static int run_cost(sqlite3_stmt *stmt, int64_t bytes) {
  int steps = run_steps(stmt);
  return bytes > QUICK_BYTES ? INT_MAX : steps;
}

/* Gives a statement back after its run: reset, unbound, and idle in the cache, or finalized when it has no entry or
   the connection closed meanwhile (then its entry is emptied here, the only owner left). RESET is false when the
   caller has reset it already; HIT counts a run of the cached statement (a short call counts only one that ended).
   STEPS is the count of run_steps for the entry, or NO_STEPS to keep the one it has (the statement did not run). */
static void release(conn *c, sqlite3_stmt *stmt, entry *e, bool reset, bool hit, int steps) {
  /* reset gives the error of the last step again, which the caller has read already. */
  if (reset) {
    (void)sq.reset(stmt);
    (void)sq.clear_bindings(stmt);
  }
  bool finalize = e == NULL;
  lock_take(&c->lock);
  if (e && steps != NO_STEPS) e->steps = steps;
  if (e && steps == INT_MAX && e->kind != K_READ) e->long_value = true;
  /* Only a short call counts a hit here, one that ran its statement whole. */
  if (hit) {
    c->hits++;
    c->shorts++;
  }
  if (e && c->closed) {
    finalize = true;
    free(e->sql);
    *e = (entry){0};
  } else if (e) {
    e->busy = false;
  }
  lock_drop(&c->lock);
  /* The result of finalize is the error of the last step, read already. */
  if (finalize) (void)sq.finalize(stmt);
}

static void conn_free(void *state) {
  conn *c = ((conn_state *)state)->c;
  if (!c) return;
  /* The idle statements go now; a busy one belongs to its Cursor, which finalizes it (release). */
  lock_take(&c->lock);
  c->closed = true;
  for (int i = 0; i < c->capacity; i++) {
    entry *e = &c->entries[i];
    if (!e->sql || e->busy) continue;
    /* The finalize ends what the reset of a dirty entry would. */
    if (e->dirty) c->pending--;
    (void)sq.finalize(e->stmt);
    free(e->sql);
    *e = (entry){0};
  }
  lock_drop(&c->lock);
  /* close_v2 leaves a zombie while a Cursor still holds a statement, and closes at its finalize. It only fails for a
     NULL or bad handle, which this one never is. */
  (void)sq.close_v2(c->db);
  conn_unref(c);
}

/* Gives a statement back from a free function, which never waits for SQLite's mutex: the VM runs it under its own
   lock, so a wait there stops every scheduler for the whole step of another thread. Without the mutex a cached
   statement goes back dirty (the next fetch resets it) and another one, or one of a closed connection, becomes an
   orphan. It never finalizes: the last finalize of a closed connection frees the mutex, and only a statement that is
   not reset needs one here. */
static void give_back(conn *c, sqlite3_stmt *stmt, entry *e) {
  sqlite3_mutex *m = sq.db_mutex(c->db);
  bool reset = sq.mutex_try(m) == SQLITE_OK;
  if (reset) {
    /* reset gives the error of the last step again, which the cursor's query has read already. */
    (void)sq.reset(stmt);
    (void)sq.clear_bindings(stmt);
    sq.mutex_leave(m);
  }
  orphan *node = NULL;
  lock_take(&c->lock);
  bool kept = e && !c->closed;
  if (kept) {
    e->busy = false;
    e->dirty = !reset;
    if (!reset) c->pending++;
  } else {
    if (e) {
      free(e->sql);
      *e = (entry){0};
    }
    node = malloc(sizeof *node);
    if (node) {
      *node = (orphan){stmt, c->orphans};
      c->orphans = node;
      c->pending++;
    }
  }
  lock_drop(&c->lock);
  /* Out of memory for the node: the one case that waits rather than leaks. */
  if (!kept && !node) (void)sq.finalize(stmt);
}

/* Settles what the free functions left: resets the dirty entries and finalizes the orphans. A write given back before
   its end still counts as running for SQLite, which then commits nothing else on the connection until it is reset
   (and that reset rolls back what came after it), and an orphan holds a read snapshot.
   So every fetch settles them before it runs, the short call does not run while any are left, and the adapter's
   in_transaction? settles first. It waits for SQLite's mutex: only a call on the compute pool makes it. */
static void settle(conn *c) {
  lock_take(&c->lock);
  bool any = c->pending > 0;
  lock_drop(&c->lock);
  if (!any) return;
  finalize_orphans(c);
  for (;;) {
    entry *e = NULL;
    lock_take(&c->lock);
    for (int i = 0; i < c->capacity && !e; i++) {
      entry *at = &c->entries[i];
      if (at->sql && !at->busy && at->dirty) e = at;
    }
    if (e) {
      e->busy = true;
      e->dirty = false;
    }
    lock_drop(&c->lock);
    if (!e) return;
    sqlite3_mutex *m = sq.db_mutex(c->db);
    sq.mutex_enter(m);
    /* The error of the statement's last step, which its query read already. */
    (void)sq.reset(e->stmt);
    (void)sq.clear_bindings(e->stmt);
    sq.mutex_leave(m);
    lock_take(&c->lock);
    c->pending--;
    lock_drop(&c->lock);
    release(c, e->stmt, e, false, false, NO_STEPS);
  }
}

static void cursor_free(void *state) {
  cursor_state *cur = state;
  if (!cur->c) return;
  if (cur->stmt) give_back(cur->c, cur->stmt, cur->e);
  conn_unref(cur->c);
}

/* ---- Terms. ---- */

enum { VALUE, BATCH, FETCH, CACHE_STATS };
enum { V_NULL, V_INT, V_FLOAT, V_TEXT, V_BLOB, V_BOOL };
enum { CONN, CURSOR, WAL };
enum { F_KEEP, F_CACHE, F_ROWS, F_BYTES, F_QUICK_ROWS, F_QUICK_STEPS };

/* The length of the UTF-8 character at S, or 0 for a byte that does not start one (as the VM reads text). */
static size_t utf8_char(const unsigned char *s, size_t len) {
  unsigned char c = s[0];
  size_t n;
  uint32_t cp;
  if (c < 0x80) return 1;
  if (c >= 0xC2 && c <= 0xDF) {
    n = 1;
    cp = c & 0x1F;
  } else if (c >= 0xE0 && c <= 0xEF) {
    n = 2;
    cp = c & 0x0F;
  } else if (c >= 0xF0 && c <= 0xF4) {
    n = 3;
    cp = c & 0x07;
  } else {
    return 0;
  }
  if (len - 1 < n) return 0;
  for (size_t k = 1; k <= n; k++) {
    if ((s[k] & 0xC0) != 0x80) return 0;
    cp = (cp << 6) | (s[k] & 0x3F);
  }
  if ((n == 2 && cp < 0x800) || (n == 3 && cp < 0x10000) || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) return 0;
  return n + 1;
}

/* A String of the bytes, each byte that is not UTF-8 replaced by U+FFFD, as the FFI adapter reads text. */
static an_term text(an_env *env, const char *data, size_t len) {
  const unsigned char *s = (const unsigned char *)(data ? data : "");
  size_t i = 0, step;
  while (i < len && (step = utf8_char(s + i, len - i)) != 0) i += step;
  if (i == len) return an_string(env, (const char *)s, len);
  if (len > (SIZE_MAX - 1) / 3) return an_raise(env, "sqlite: a text is too long");
  char *out = malloc(len * 3 + 1);
  if (!out) return an_raise(env, "sqlite: out of memory");
  /* The valid start is copied whole; the scan goes on from the first bad byte. */
  memcpy(out, s, i);
  size_t at = i;
  while (i < len) {
    step = utf8_char(s + i, len - i);
    if (step) {
      memcpy(out + at, s + i, step);
      at += step;
      i += step;
    } else {
      memcpy(out + at, "\xEF\xBF\xBD", 3);
      at += 3;
      i++;
    }
  }
  an_term t = an_string(env, out, at);
  free(out);
  return t;
}

static an_term text0(an_env *env, const char *s) { return text(env, s, s ? strlen(s) : 0); }

/* What went wrong in a call, as the adapter's error text: `sqlite error <code>: <message>` or `sqlite error:
   <message>`; empty when nothing did. */
typedef struct {
  char text[1024];
} failure;

static void fail_input(failure *f, const char *message) {
  snprintf(f->text, sizeof f->text, "sqlite error: %s", message);
}

static void fail_code(failure *f, conn *c, int code) {
  if (code == SQLITE_INTERRUPT) {
    snprintf(f->text, sizeof f->text, "sqlite error %d: interrupted", SQLITE_INTERRUPT);
  } else {
    const char *message = sq.errmsg(c->db);
    snprintf(f->text, sizeof f->text, "sqlite error %d: %s", code, message ? message : "");
  }
}

typedef struct {
  int code, extended;
  bool upgrade, readonly;
  failure why;
  int changes;
  int frames;
} outcome;

static an_term batch(an_env *env, const outcome *o, an_term rows) {
  an_term fields[8] = {
    an_int(env, o->code),       an_int(env, o->extended), an_bool(env, o->upgrade), an_bool(env, o->readonly),
    text0(env, o->why.text),    rows,                     an_int(env, o->changes),  an_int(env, o->frames),
  };
  return an_struct(env, BATCH, fields);
}

static bool lock_code(int code) { return code == SQLITE_BUSY || code == SQLITE_LOCKED; }

/* ---- Binding and reading. ---- */

/* Binds PARAMS (a List[Value], argument ARG of the call); false with the failure in F, or with *OVER when the texts
   and blobs have more than LIMIT bytes in all. The text of a failed bind comes from its code, not from the
   connection's last message, which another thread may have set meanwhile. */
static bool bind_all(an_env *env, sqlite3_stmt *stmt, an_term params, int arg, size_t limit, bool *over, failure *f) {
  an_list_cursor walk;
  size_t count, bound = 0;
  an_term item;
  *over = false;
  if (!an_list_cursor_begin(env, params, &walk, &count)) {
    (void)an_badarg(env, arg);
    fail_input(f, "the parameters are not a list");
    return false;
  }
  int wanted = sq.bind_parameter_count(stmt);
  if ((size_t)wanted != count) {
    char message[160];
    snprintf(message, sizeof message, "the sql has %d %s, got %zu", wanted, wanted == 1 ? "parameter" : "parameters",
             count);
    fail_input(f, message);
    return false;
  }
  for (int index = 1; an_list_next(env, &walk, &item); index++) {
    uint32_t variant;
    an_term payload;
    int64_t n;
    double x;
    bool flag;
    const char *data;
    const uint8_t *bytes;
    size_t len;
    int rc = SQLITE_RANGE;
    if (!an_get_variant(env, item, VALUE, &variant)) variant = UINT32_MAX;
    bool has_payload = variant != V_NULL && variant != UINT32_MAX;
    if (has_payload && !an_get_payload(env, item, VALUE, 0, &payload)) variant = UINT32_MAX;
    switch (variant) {
    case V_NULL:
      rc = sq.bind_null(stmt, index);
      break;
    case V_INT:
      if (an_get_int(env, payload, &n)) rc = sq.bind_int64(stmt, index, n);
      break;
    case V_FLOAT:
      if (an_get_float(env, payload, &x)) rc = sq.bind_double(stmt, index, x);
      break;
    case V_TEXT:
      if (an_get_string(env, payload, &data, &len)) {
        if (len > limit - bound) {
          *over = true;
          return false;
        }
        bound += len;
        /* A NULL pointer would bind NULL: an empty text needs a real one. SQLite copies the text (transient). */
        rc = sq.bind_text64(stmt, index, data ? data : "", len, SQLITE_TRANSIENT, SQLITE_UTF8);
      }
      break;
    case V_BLOB:
      if (an_get_bytes(env, payload, &bytes, &len)) {
        if (len > limit - bound) {
          *over = true;
          return false;
        }
        bound += len;
        rc = len == 0 ? sq.bind_zeroblob(stmt, index, 0) : sq.bind_blob64(stmt, index, bytes, len, SQLITE_TRANSIENT);
      }
      break;
    case V_BOOL:
      if (an_get_bool(env, payload, &flag)) rc = sq.bind_int64(stmt, index, flag ? 1 : 0);
      break;
    default:
      break;
    }
    if (rc != SQLITE_OK) {
      snprintf(f->text, sizeof f->text, "sqlite error %d: %s", rc, sq.errstr(rc));
      return false;
    }
  }
  return true;
}

/* The value of column COL of the row at the statement's cursor; adds its size to *BYTES. */
static an_term read_value(an_env *env, sqlite3_stmt *stmt, int col, int64_t *bytes) {
  an_term payload;
  int kind = sq.column_type(stmt, col);
  *bytes += VALUE_COST;
  if (kind == SQLITE_INTEGER) {
    payload = an_int(env, sq.column_int64(stmt, col));
    return an_enum(env, VALUE, V_INT, &payload);
  }
  if (kind == SQLITE_TEXT) {
    /* The pointer first, then its length: column_bytes is right only after the conversion. */
    const unsigned char *p = sq.column_text(stmt, col);
    int len = sq.column_bytes(stmt, col);
    *bytes += len;
    payload = text(env, (const char *)p, p ? (size_t)len : 0);
    return an_enum(env, VALUE, V_TEXT, &payload);
  }
  if (kind == SQLITE_FLOAT) {
    payload = an_float(env, sq.column_double(stmt, col));
    return an_enum(env, VALUE, V_FLOAT, &payload);
  }
  if (kind == SQLITE_BLOB) {
    const void *p = sq.column_blob(stmt, col);
    int len = sq.column_bytes(stmt, col);
    *bytes += len;
    payload = an_bytes(env, p ? p : "", p ? (size_t)len : 0);
    return an_enum(env, VALUE, V_BLOB, &payload);
  }
  return an_enum(env, VALUE, V_NULL, NULL);
}

/* The columns that a row reads with names made once per call. Terms live only in C locals (the collector scans the
   stack, not malloc memory), so they are arrays on the stack; a wider row makes its names again for each row. */
#define MAX_NAMES 64

typedef struct {
  int n;
  an_term names[MAX_NAMES];
  an_term values[MAX_NAMES];
} columns;

static void columns_begin(an_env *env, sqlite3_stmt *stmt, columns *cols) {
  cols->n = sq.column_count(stmt);
  if (cols->n > MAX_NAMES) return;
  for (int col = 0; col < cols->n; col++) cols->names[col] = text0(env, sq.column_name(stmt, col));
}

/* The row at the statement's cursor as a Map[String, Value]; adds its size to *BYTES. */
static an_term read_row(an_env *env, sqlite3_stmt *stmt, columns *cols, int64_t *bytes) {
  if (cols->n <= MAX_NAMES) {
    for (int col = 0; col < cols->n; col++) cols->values[col] = read_value(env, stmt, col, bytes);
    return an_map_from(env, cols->names, cols->values, (size_t)cols->n);
  }
  an_term row = an_map_from(env, NULL, NULL, 0);
  for (int col = 0; col < cols->n; col++) {
    an_term name = text0(env, sq.column_name(stmt, col));
    row = an_map_put(env, row, name, read_value(env, stmt, col, bytes));
  }
  return row;
}

/* One step under SQLite's mutex of the database, so that the error code and message are this step's, and so are the
   changes: SQLite counts them when the statement ends, in the step that gives SQLITE_DONE, and a statement that writes
   nothing leaves the total as it was (sqlite3_changes then still holds an earlier statement's count). The frames that
   the WAL hook saw in a commit of this step go to O. A step that starts outside a transaction starts the count of the
   writes of the next one (a BEGIN, or a write that commits itself); a write counts one more step when SHORT_CALL ran
   it, and makes the transaction heavy when the compute pool did. A BEGIN IMMEDIATE is not read-only for SQLite, but
   it only opens the transaction: it counts nothing. A commit to the WAL of a pool tells its share
   (share_committed). */
static int step(conn *c, sqlite3_stmt *stmt, bool short_call, outcome *o) {
  sqlite3_mutex *m = sq.db_mutex(c->db);
  sq.mutex_enter(m);
  uint64_t gen = c->share ? share_gen(c->share) : 0;
  bool fresh = sq.get_autocommit(c->db) != 0;
  if (fresh) c->txn_writes = 0;
  c->frames = 0;
  int before = sq.total_changes(c->db);
  int rc = sq.step(stmt);
  if (rc == SQLITE_DONE) o->changes = sq.total_changes(c->db) == before ? 0 : sq.changes(c->db);
  if (c->share && c->frames > 0) {
    int uncopied = share_committed(c->share, gen, c->frames);
    if (uncopied > o->frames) o->frames = uncopied;
  }
  bool begun = fresh && !sq.get_autocommit(c->db);
  if (!sq.stmt_readonly(stmt) && !begun)
    c->txn_writes = short_call && c->txn_writes < TXN_HEAVY - 1 ? c->txn_writes + 1 : TXN_HEAVY;
  if (rc != SQLITE_ROW && rc != SQLITE_DONE) {
    o->code = rc;
    o->extended = sq.extended_errcode(c->db);
    fail_code(&o->why, c, rc);
    /* A write that a read transaction of this connection asks for while another holds the write lock: SQLite does
       not wait (the holder may wait for this read lock), so neither must the caller. */
    o->upgrade = rc == SQLITE_BUSY && o->extended == SQLITE_BUSY && !sq.stmt_readonly(stmt) && sq.txn_state &&
                 sq.libversion_number() >= TXN_STATE_VERSION && sq.txn_state(c->db, NULL) == SQLITE_TXN_READ;
    /* A write that a lock stopped still counts as running for SQLite: no other statement of the connection commits
       until its reset, and the error of a later step would roll them back. The reset, under this mutex, undoes only
       what the write began; its next fetch runs it again from its start. */
    if (lock_code(rc) && !sq.stmt_readonly(stmt)) (void)sq.reset(stmt);
  }
  sq.mutex_leave(m);
  return rc;
}

/* ---- Preparing. ---- */

/* With busy timeout 0, SQLite reports the parse error of a stale schema ("no such table") when the read lock that
   checks the schema is refused. This read loads the current schema; its code, a lock for the caller to wait for. */
static int recheck_schema(conn *c) {
  static const char SQL[] = "SELECT 1 FROM main.sqlite_master LIMIT 1";
  sqlite3_stmt *stmt = NULL;
  int rc = sq.prepare_v2(c->db, SQL, (int)sizeof SQL - 1, &stmt, NULL);
  if (rc == SQLITE_OK && stmt) rc = sq.step(stmt);
  /* finalize keeps the error of the step for extended_errcode. */
  if (stmt) (void)sq.finalize(stmt);
  return rc == SQLITE_ROW || rc == SQLITE_DONE ? SQLITE_OK : rc;
}

/* Whether SQLite checked the schema under no lock of this connection: outside any transaction. */
static bool schema_unchecked(conn *c) {
  if (sq.get_autocommit(c->db) == 0) return false;
  return !sq.txn_state || sq.libversion_number() < TXN_STATE_VERSION || sq.txn_state(c->db, NULL) == SQLITE_TXN_NONE;
}

/* Prepares the one statement of SQL, refusing none or a second one; the statement, or NULL with the failure in O
   (a lock comes back as its code, for the caller to wait). */
static sqlite3_stmt *prepare(conn *c, const char *sql, size_t len, outcome *o) {
  sqlite3_stmt *stmt = NULL, *more = NULL;
  const char *tail = NULL;
  if (len > INT_MAX) {
    o->code = SQLITE_TOOBIG;
    fail_input(&o->why, "the sql is too long");
    return NULL;
  }
  sqlite3_mutex *m = sq.db_mutex(c->db);
  sq.mutex_enter(m);
  int rc = sq.prepare_v2(c->db, sql, (int)len, &stmt, &tail);
  if (rc == SQLITE_ERROR && schema_unchecked(c)) {
    failure parsed;
    fail_code(&parsed, c, rc);
    int checked = recheck_schema(c);
    if (lock_code(checked)) {
      /* The caller waits for the lock and fetches again; when the wait ends it reports the error of SQL, not the
         lock. */
      o->code = checked;
      o->extended = sq.extended_errcode(c->db);
      o->why = parsed;
      sq.mutex_leave(m);
      return NULL;
    }
    rc = checked == SQLITE_INTERRUPT ? checked : sq.prepare_v2(c->db, sql, (int)len, &stmt, &tail);
  }
  if (rc != SQLITE_OK) {
    o->code = rc;
    o->extended = sq.extended_errcode(c->db);
    fail_code(&o->why, c, rc);
  } else if (!stmt) {
    o->code = -1;
    fail_input(&o->why, "the sql has no statement");
  } else if (tail && !blank(tail, sql + len)) {
    /* Text after the first statement that is only comments gives no statement: still one statement. */
    int left = (int)(sql + len - tail);
    rc = sq.prepare_v2(c->db, tail, left, &more, NULL);
    if (rc == SQLITE_OK && more) (void)sq.finalize(more);
    if (lock_code(rc)) {
      o->code = rc;
      o->extended = sq.extended_errcode(c->db);
      fail_code(&o->why, c, rc);
    } else if (rc != SQLITE_OK || more) {
      o->code = -1;
      fail_input(&o->why, "the sql has more than one statement");
    }
  }
  sq.mutex_leave(m);
  if (o->why.text[0] && stmt) {
    (void)sq.finalize(stmt);
    stmt = NULL;
  }
  return stmt;
}

/* What ends a plan for a write in a short call (short_plan): a count(*) of a whole table, a trigger or a foreign key
   action (OP_Program, whose instructions the plan does not show), a DELETE of a whole table, a sort, a two-pass UPDATE
   or DELETE, a virtual table (FTS5 merges its segments in a write and at the COMMIT, a work that no plan bounds) and
   the statements that change the schema. */
static const char *const WRITE_LONG[] = {
  "Count",   "Program",  "Clear",      "Destroy",   "Sort",        "SorterSort",  "SorterNext", "RowSetRead",
  "VBegin",  "VOpen",    "VFilter",    "VNext",     "VUpdate",     "VCreate",     "VDestroy",   "ParseSchema",
  "Checkpoint", "Vacuum", "IncrVacuum", "JournalMode", "IntegrityCk",
};
static bool opcode_in(const char *op, const char *const *list, size_t n) {
  for (size_t i = 0; i < n; i++)
    if (strcmp(op, list[i]) == 0) return true;
  return false;
}

/* The root page of sqlite_sequence in the main database, 0 when there is none. Under SQLite's mutex. */
static sqlite3_int64 sequence_root(conn *c) {
  static const char SQL[] = "SELECT rootpage FROM main.sqlite_master WHERE name = 'sqlite_sequence'";
  sqlite3_stmt *stmt = NULL;
  sqlite3_int64 root = 0;
  if (sq.prepare_v2(c->db, SQL, (int)sizeof SQL - 1, &stmt, NULL) == SQLITE_OK && stmt &&
      sq.step(stmt) == SQLITE_ROW)
    root = sq.column_int64(stmt, 0);
  /* finalize gives the error of the step, which leaves root at 0. */
  if (stmt) (void)sq.finalize(stmt);
  return root;
}

/* What the first pass of a write plan finds at each address (plan_scan.ops): an OP_Yield, or an instruction that opens
   cursor `cursors[addr]` on a table or an index (P_REAL) or on a transient table (P_TRANSIENT); `guarded` when an
   OP_FkIfZero before it skips it while no foreign key is broken. `fk_end` is where the last such region ends. */
enum { P_OTHER, P_YIELD, P_REAL, P_TRANSIENT };

typedef struct {
  unsigned char *ops;
  bool *guarded;
  sqlite3_int64 *cursors;
  sqlite3_int64 count;
  sqlite3_int64 room;
  sqlite3_int64 fk_end;
} plan_scan;

/* Whether an instruction at AT that loops over cursor CURSOR scans a table or an index. SQLite numbers its cursors per
   statement and gives a number to another table in another part of the plan, so the cursor is the one of the nearest
   instruction before AT that opens that number, or of the nearest after it (a transient table that the setup at the
   end of the plan opens). A cursor that nothing opens counts as a scan. */
static bool scans(const plan_scan *scan, sqlite3_int64 at, sqlite3_int64 cursor) {
  for (sqlite3_int64 i = at - 1; i >= 0; i--)
    if (scan->ops[i] >= P_REAL && scan->cursors[i] == cursor) return scan->ops[i] == P_REAL;
  for (sqlite3_int64 i = at + 1; i < scan->count; i++)
    if (scan->ops[i] >= P_REAL && scan->cursors[i] == cursor) return scan->ops[i] == P_REAL;
  return true;
}

/* Notes what the instruction OP at ADDR is in SCAN, which grows to hold it; false when out of memory. SEQUENCE is the
   root page of sqlite_sequence, whose cursor is not a scan (see short_plan). */
static bool note_op(plan_scan *scan, sqlite3_int64 addr, const char *op, sqlite3_int64 p1, sqlite3_int64 p2,
                    sqlite3_int64 p3, sqlite3_int64 sequence) {
  if (addr >= scan->room) {
    /* The room doubles, so that a long plan costs a few reallocs. addr is at most INT_MAX (short_plan). */
    sqlite3_int64 room = scan->room > 0 ? scan->room * 2 : 64;
    if (room <= addr) room = addr + 1;
    unsigned char *ops = realloc(scan->ops, (size_t)room);
    if (!ops) return false;
    scan->ops = ops;
    bool *guarded = realloc(scan->guarded, (size_t)room * sizeof *guarded);
    if (!guarded) return false;
    scan->guarded = guarded;
    sqlite3_int64 *cursors = realloc(scan->cursors, (size_t)room * sizeof *cursors);
    if (!cursors) return false;
    scan->cursors = cursors;
    for (sqlite3_int64 i = scan->room; i < room; i++) {
      ops[i] = P_OTHER;
      guarded[i] = false;
      cursors[i] = -1;
    }
    scan->room = room;
  }
  if (addr >= scan->count) scan->count = addr + 1;
  scan->guarded[addr] = addr < scan->fk_end;
  if (strcmp(op, "FkIfZero") == 0 && p2 > scan->fk_end) scan->fk_end = p2;
  static const char *const REAL[] = {"OpenRead", "OpenWrite", "ReopenIdx", "OpenDup"};
  static const char *const TRANSIENT[] = {"OpenEphemeral", "OpenAutoindex", "OpenPseudo", "SorterOpen"};
  /* OpenDup copies another cursor and has no root page of its own; p3 is the database, 0 for main. */
  bool counter = strcmp(op, "OpenDup") != 0 && sequence != 0 && p2 == sequence && p3 == 0;
  if (strcmp(op, "Yield") == 0) {
    scan->ops[addr] = P_YIELD;
  } else if (opcode_in(op, REAL, sizeof REAL / sizeof REAL[0])) {
    scan->ops[addr] = counter ? P_TRANSIENT : P_REAL;
    scan->cursors[addr] = p1;
  } else if (opcode_in(op, TRANSIENT, sizeof TRANSIENT / sizeof TRANSIENT[0])) {
    scan->ops[addr] = P_TRANSIENT;
    scan->cursors[addr] = p1;
  }
  return true;
}

/* Whether the plan of SQL (EXPLAIN: one row per instruction, with its address, opcode, p1, p2 and p3) lets the
   statement run in a short call; a plan that cannot be read does not. A read (WRITE false) must not have OP_Count, the
   count(*) of a whole table, which reads its pages in one instruction where the progress handler never runs: the
   budget bounds the rest. A write cannot be stopped midway, so its plan must bound its work by itself:
   - none of WRITE_LONG;
   - no OP_Rewind, OP_Last, OP_Next or OP_Prev on a cursor of a table or an index (a scan, whole or of a range: only
     the lookups of one row, by key or by a unique index, are left), except sqlite_sequence, the one row per table
     that an INSERT into an AUTOINCREMENT table reads and writes, and the OP_Next or OP_Prev that an OP_FkIfZero
     skips while no foreign key is broken: the rows of an index of a child table that point to the new key of an
     INSERT into a parent table, which exist only when the statement fails on its own foreign key or deferred
     violations wait. That loop starts at a seek of the key; one that starts at OP_Rewind or OP_Last (a child table
     with no index on its key, scanned whole when deferred violations wait) is refused like any other scan;
   - no OP_Goto back, but to the start (the one jump back of every plan) or to an OP_Yield: the loop that takes the
     rows of a coroutine (INSERT ... SELECT, a list of VALUES rows). The rows of a coroutine come from the scans that
     the rules above refuse, or from the text of the statement; a recursive CTE loops back to its queue, and is long.
   A loop over a transient table stays, which the rules above bound: the rows of RETURNING, of an `IN (?, ?)` list, of
   a coroutine. The count of instructions of the last run (entry.steps) is the check of what the plan does not show.
   The first pass notes the cursors and the OP_Yield, which a jump can reach before the address that has them. */
static bool short_plan(conn *c, const char *sql, size_t len, bool write) {
  static const char PREFIX[] = "EXPLAIN ";
  size_t n = sizeof PREFIX - 1;
  if (len > INT_MAX - n) return false;
  char *text = malloc(n + len);
  if (!text) return false;
  memcpy(text, PREFIX, n);
  memcpy(text + n, sql, len);
  sqlite3_stmt *plan = NULL;
  bool ok = false;
  plan_scan scan = {NULL, NULL, NULL, 0, 0, 0};
  sqlite3_mutex *m = sq.db_mutex(c->db);
  sq.mutex_enter(m);
  sqlite3_int64 sequence = write ? sequence_root(c) : 0;
  if (sq.prepare_v2(c->db, text, (int)(n + len), &plan, NULL) == SQLITE_OK && plan) {
    int rc = SQLITE_DONE;
    ok = true;
    for (int pass = write ? 0 : 1; pass < 2 && ok; pass++) {
      /* reset gives the error of the last step, which the loop has read. */
      (void)sq.reset(plan);
      while (ok && (rc = sq.step(plan)) == SQLITE_ROW) {
        const char *op = (const char *)sq.column_text(plan, 1);
        sqlite3_int64 addr = sq.column_int64(plan, 0), p1 = sq.column_int64(plan, 2), p2 = sq.column_int64(plan, 3);
        if (!op || addr < 0 || addr > INT_MAX) {
          ok = false;
        } else if (!write) {
          ok = strcmp(op, "Count") != 0;
        } else if (pass == 0) {
          ok = note_op(&scan, addr, op, p1, p2, sq.column_int64(plan, 4), sequence);
        } else if (addr >= scan.count) {
          /* Another connection changed the schema between the passes and this step prepared the plan again, longer:
             the arrays of the first pass do not reach it (they are NULL after an empty one). The statement runs in a
             normal call. */
          ok = false;
        } else if (opcode_in(op, WRITE_LONG, sizeof WRITE_LONG / sizeof WRITE_LONG[0])) {
          ok = false;
        } else if (strcmp(op, "Rewind") == 0 || strcmp(op, "Last") == 0) {
          ok = !scans(&scan, addr, p1);
        } else if (strcmp(op, "Next") == 0 || strcmp(op, "Prev") == 0) {
          ok = scan.guarded[addr] || !scans(&scan, addr, p1);
        } else if (strcmp(op, "Goto") == 0 && p2 < addr) {
          ok = p2 == 1 || (p2 >= 0 && p2 < scan.count && scan.ops[p2] == P_YIELD);
        }
      }
      if (ok && rc != SQLITE_DONE) ok = false;
    }
  }
  /* finalize gives the error of the last step, which only decides `ok`. */
  if (plan) (void)sq.finalize(plan);
  sq.mutex_leave(m);
  free(scan.ops);
  free(scan.guarded);
  free(scan.cursors);
  free(text);
  return ok;
}

/* What a short call may run of a statement (entry.kind). A BEGIN or a COMMIT by its words (control_kind; SQLite
   counts a BEGIN IMMEDIATE as a write). Else its columns must have distinct names, and a read needs its words
   (quick_text), columns, and a plan without a long instruction; a write its words (write_text) and a plan that bounds
   it (short_plan). */
static unsigned char classify(conn *c, sqlite3_stmt *stmt, const char *sql, size_t len) {
  int repeated, columns = sq.column_count(stmt);
  unsigned char control = control_kind(sql, len);
  if (control != K_NONE) return control;
  if (columns > 0 && !distinct_names(stmt, &repeated)) return K_NONE;
  if (sq.stmt_readonly(stmt))
    return columns > 0 && quick_text(sql, len) && short_plan(c, sql, len, false) ? K_READ : K_NONE;
  return write_text(sql, len) && short_plan(c, sql, len, true) ? K_WRITE : K_NONE;
}

/* The statement of SQL for a fetch: the cached one when it is idle, else a new one, cached when there is room (and
   CACHE: the settings that `open` runs once are not). NULL with the failure in O. */
static sqlite3_stmt *acquire(conn *c, const char *sql, size_t len, bool cache, entry **e, outcome *o) {
  *e = NULL;
  if (!cache) return prepare(c, sql, len, o);
  uint64_t hash = hash_text(sql, len);
  bool dirty = false;
  lock_take(&c->lock);
  *e = find_idle(c, sql, len, hash);
  if (*e) {
    c->hits++;
    dirty = (*e)->dirty;
    (*e)->dirty = false;
  } else {
    c->misses++;
  }
  lock_drop(&c->lock);
  sqlite3_stmt *stmt;
  if (*e) {
    stmt = (*e)->stmt;
    if (dirty) {
      sqlite3_mutex *m = sq.db_mutex(c->db);
      sq.mutex_enter(m);
      /* The error of the last step again, which its query read already. */
      (void)sq.reset(stmt);
      (void)sq.clear_bindings(stmt);
      sq.mutex_leave(m);
      lock_take(&c->lock);
      c->pending--;
      lock_drop(&c->lock);
    }
  } else {
    stmt = prepare(c, sql, len, o);
    if (!stmt) return NULL;
    sqlite3_stmt *evicted;
    lock_take(&c->lock);
    *e = insert(c, sql, len, hash, stmt, &evicted);
    lock_drop(&c->lock);
    if (evicted) (void)sq.finalize(evicted);
  }
  /* The plan is read for a new entry, and again when SQLite has prepared the statement again since (a schema change
     can bring in a long instruction). The entry is busy, so this call is its only reader meanwhile. */
  int prepared = sq.stmt_status(stmt, SQLITE_STMTSTATUS_REPREPARE, 0);
  if (*e && prepared != (*e)->checked) {
    unsigned char kind = classify(c, stmt, sql, len);
    lock_take(&c->lock);
    (*e)->kind = kind;
    (*e)->long_value = false;
    (*e)->checked = prepared;
    lock_drop(&c->lock);
  }
  return stmt;
}

/* False with the failure in O when two columns of the result have one name; RAN says that the statement has written
   already. */
static bool check_names(sqlite3_stmt *stmt, outcome *o, bool ran) {
  int repeated;
  if (distinct_names(stmt, &repeated)) return true;
  char message[sizeof o->why.text - 32];
  snprintf(message, sizeof message, "%sthe result has the column %s twice, alias one of them",
           ran ? "the statement ran, but " : "", sq.column_name(stmt, repeated));
  o->code = -1;
  fail_input(&o->why, message);
  return false;
}

/* ---- The functions of the module. ---- */

typedef struct {
  bool keep, cache;
  int64_t rows, bytes, quick_rows, quick_steps;
} fetch_options;

static bool read_options(an_env *env, an_term t, fetch_options *out) {
  an_term f[6];
  for (uint32_t i = 0; i < 6; i++)
    if (!an_get_field(env, t, FETCH, i, &f[i])) return false;
  return an_get_bool(env, f[F_KEEP], &out->keep) && an_get_bool(env, f[F_CACHE], &out->cache) &&
         an_get_int(env, f[F_ROWS], &out->rows) &&
         an_get_int(env, f[F_BYTES], &out->bytes) && an_get_int(env, f[F_QUICK_ROWS], &out->quick_rows) &&
         an_get_int(env, f[F_QUICK_STEPS], &out->quick_steps);
}

static conn *conn_of(an_env *env, an_term t) {
  conn_state *s;
  if (!an_get_resource(env, t, CONN, (void **)&s) || !s->c) return NULL;
  return s->c;
}

/* connect(path, flags, cache): a connection with a statement cache of CACHE statements (0: none). */
static an_term fn_connect(an_env *env, int argc, const an_term *argv) {
  const char *path;
  size_t len;
  int64_t flags, capacity;
  char message[640];
  (void)argc;
  if (!an_get_string(env, argv[0], &path, &len)) return an_badarg(env, 0);
  if (!an_get_int(env, argv[1], &flags) || flags < 0 || flags > INT_MAX) return an_badarg(env, 1);
  if (!an_get_int(env, argv[2], &capacity) || capacity < 0 || capacity > MAX_CACHE) return an_badarg(env, 2);
  if (!library_ready()) {
    int n = snprintf(message, sizeof message, "sqlite error: cannot load the SQLite library: %s", load_error);
    return an_error(env, message, n > 0 ? (size_t)n : 0);
  }
  /* The path holds no NUL (the adapter refuses one), but it has none at its end either. */
  char *name = malloc(len + 1);
  conn *c = calloc(1, sizeof *c);
  entry *entries = calloc((size_t)(capacity ? capacity : 1), sizeof *entries);
  if (!name || !c || !entries) {
    free(name);
    free(c);
    free(entries);
    return an_raise(env, "sqlite: out of memory");
  }
  memcpy(name, path, len);
  name[len] = '\0';
  sqlite3 *db = NULL;
  /* Serialized whatever the build's default (macOS ships SQLITE_THREADSAFE=2, whose connections have no mutex): the
     tasks of one connection run on several threads, and the cache and the short calls rely on the db mutex. */
  int open_flags = ((int)flags & ~SQLITE_OPEN_NOMUTEX) | SQLITE_OPEN_FULLMUTEX;
  int rc = sq.open_v2(name, &db, open_flags, NULL);
  free(name);
  if (rc == SQLITE_OK && !sq.db_mutex(db)) {
    /* SQLITE_THREADSAFE=0: no mutex at all, so one connection cannot be shared by threads. */
    (void)sq.close_v2(db);
    free(c);
    free(entries);
    static const char NO_THREADS[] = "sqlite error: this SQLite was built without threads (SQLITE_THREADSAFE=0)";
    return an_error(env, NO_THREADS, sizeof NO_THREADS - 1);
  }
  if (rc != SQLITE_OK) {
    /* The handle may be NULL (out of memory), which errmsg cannot take, so the text comes from the code. */
    if (db) (void)sq.close_v2(db);
    free(c);
    free(entries);
    int n = snprintf(message, sizeof message, "sqlite error %d: %s", rc, sq.errstr(rc));
    return an_error(env, message, n > 0 ? (size_t)n : 0);
  }
  lock_init(&c->lock);
  c->refs = 1;
  c->db = db;
  c->entries = entries;
  c->capacity = (int)capacity;
  sq.progress_handler(db, PROGRESS_OPS, progress, c);
  an_term out;
  conn_state *s = an_resource_new(env, CONN, &out);
  if (!s) {
    c->refs = 0;
    (void)sq.close_v2(db);
    free(entries);
    lock_destroy(&c->lock);
    free(c);
    return out;
  }
  s->c = c;
  return an_ok(env, out);
}

/* cursor(conn): a Cursor for one query, which holds the connection's state until it is closed. */
static an_term fn_cursor(an_env *env, int argc, const an_term *argv) {
  (void)argc;
  conn *c = conn_of(env, argv[0]);
  if (!c) return an_badarg(env, 0);
  an_term out;
  cursor_state *cur = an_resource_new(env, CURSOR, &out);
  if (!cur) return out;
  lock_take(&c->lock);
  c->refs++;
  lock_drop(&c->lock);
  cur->c = c;
  return out;
}

/* The bytes of the row at the statement's cursor, as the byte cap counts them, without reading it (column_bytes of a
   number would convert it to text, so a number counts VALUE_COST alone). */
static int64_t row_size(sqlite3_stmt *stmt, int n) {
  int64_t size = 0;
  for (int col = 0; col < n; col++) {
    int kind = sq.column_type(stmt, col);
    size += VALUE_COST;
    if (kind == SQLITE_TEXT || kind == SQLITE_BLOB) size += sq.column_bytes(stmt, col);
  }
  return size;
}

/* Whether C may be in a bare SQLite name: a letter, `_`, a byte of a UTF-8 character and, after the first, a digit
   or `$`. */
static bool name_byte(char c, bool first) {
  unsigned char b = (unsigned char)c;
  if (b >= 0x80 || c == '_' || (lower(c) >= 'a' && lower(c) <= 'z')) return true;
  return !first && ((c >= '0' && c <= '9') || c == '$');
}

/* The name at *AT after white space and comments, bare or quoted ("", ``, [], a doubled quote inside is one); *AT
   moves past it, however long it is. Its first CAP - 1 bytes go to OUT in lowercase, and *FITS says whether it all
   did. False when there is no name there (or its quote never closes). */
static bool take_name(const char *sql, size_t len, size_t *at, char *out, size_t cap, bool *fits) {
  size_t i = skip_space(sql, len, *at), n = 0;
  *fits = true;
  if (i >= len) return false;
  char open = sql[i], close = open == '[' ? ']' : open;
  if (open == '"' || open == '`' || open == '[') {
    for (i++; i < len; i++) {
      if (sql[i] == close) {
        if (close != ']' && i + 1 < len && sql[i + 1] == close) {
          i++;
        } else {
          break;
        }
      }
      if (n + 1 < cap) {
        out[n++] = lower(sql[i]);
      } else {
        *fits = false;
      }
    }
    if (i >= len) return false;
    i++;
  } else {
    while (i < len && name_byte(sql[i], n == 0)) {
      if (n + 1 < cap) {
        out[n++] = lower(sql[i]);
      } else {
        *fits = false;
      }
      i++;
    }
  }
  if (n == 0) return false;
  out[n] = '\0';
  *at = i;
  return true;
}

/* What a PRAGMA that changes how the connection commits does to the short writes, before it runs. Setting
   journal_mode, synchronous or locking_mode (`= value` or `(value)`) ends them on the connection (level W_NONE, as
   without a WAL); wal_checkpoint in any form (it checkpoints, which the share does not count) and setting
   wal_autocheckpoint (commits that checkpoint, on every database of the connection whatever the schema name) also on
   every connection of the pool, for good (share_stick). Reading a value changes nothing. The name may be quoted and
   follow a schema name of any length, with comments between the words. A PRAGMA whose name cannot be read counts as
   all of them. */
static void pragma_effect(conn *c, const char *sql, size_t len) {
  static const char *const level[] = {"journal_mode", "synchronous", "locking_mode"};
  char name[32];
  bool fits;
  size_t at = 0;
  if (!take_word(sql, len, &at, "pragma")) return;
  bool known = take_name(sql, len, &at, name, sizeof name, &fits);
  size_t dot = skip_space(sql, len, at);
  if (known && dot < len && sql[dot] == '.') {
    at = dot + 1;
    known = take_name(sql, len, &at, name, sizeof name, &fits);
  }
  bool stick = !known, drop = !known;
  if (known && fits) {
    size_t next = skip_space(sql, len, at);
    bool sets = next < len && (sql[next] == '=' || sql[next] == '(');
    stick = strcmp(name, "wal_checkpoint") == 0 || (sets && strcmp(name, "wal_autocheckpoint") == 0);
    drop = stick;
    for (size_t w = 0; w < sizeof level / sizeof level[0] && !drop; w++) drop = sets && strcmp(name, level[w]) == 0;
  }
  if (!drop) return;
  sqlite3_mutex *m = sq.db_mutex(c->db);
  sq.mutex_enter(m);
  wal_share *share = c->share;
  sq.mutex_leave(m);
  lock_take(&c->lock);
  c->level = W_NONE;
  lock_drop(&c->lock);
  if (stick && share) share_stick(share);
}

/* fetch(conn, cursor, sql, params, options): the next batch of the query, preparing and binding it at its first
   call. */
static an_term fn_fetch(an_env *env, int argc, const an_term *argv) {
  cursor_state *cur;
  const char *sql;
  size_t len;
  fetch_options opt;
  outcome o = {0};
  an_list_builder rows;
  (void)argc;
  conn *c = conn_of(env, argv[0]);
  if (!c) return an_badarg(env, 0);
  if (!an_get_resource(env, argv[1], CURSOR, (void **)&cur) || cur->c != c) return an_badarg(env, 1);
  if (!an_get_string(env, argv[2], &sql, &len)) return an_badarg(env, 2);
  if (!read_options(env, argv[4], &opt)) return an_badarg(env, 4);
  /* What the free functions left is settled here, on the compute pool, before this statement runs. */
  settle(c);
  an_list_begin(env, &rows, 0);
  o.readonly = true;
  if (!cur->stmt) {
    if (cur->started) return an_raise(env, "sqlite: the cursor is finished");
    entry *e = NULL;
    sqlite3_stmt *stmt = acquire(c, sql, len, opt.cache, &e, &o);
    if (!stmt) return batch(env, &o, an_list_end(env, &rows));
    pragma_effect(c, sql, len);
    /* The names are checked before the first step too, so that a write whose result cannot be read is refused
       before it writes; after a schema change only the first step shows the new columns (see below). */
    bool over;
    if (!bind_all(env, stmt, argv[3], 3, SIZE_MAX, &over, &o.why) || (opt.keep && !check_names(stmt, &o, false))) {
      if (o.code == 0) o.code = -1;
      release(c, stmt, e, true, false, NO_STEPS);
      cur->started = true;
      return batch(env, &o, an_list_end(env, &rows));
    }
    cur->stmt = stmt;
    cur->e = e;
    cur->started = true;
  }
  sqlite3_stmt *stmt = cur->stmt;
  o.readonly = sq.stmt_readonly(stmt) != 0;
  columns cols;
  bool named = false;
  int64_t count = 0, bytes = 0;
  for (;;) {
    int rc = step(c, stmt, false, &o);
    if (rc == SQLITE_ROW) {
      if (!opt.keep) continue;
      /* The columns are read after the step: SQLite prepares a statement again when the schema changed, and the new
         one may have other columns than before it ran. A write has run by its first row, and a reset would keep it
         too, so it runs to its end and the error says that it ran. */
      if (!named && !check_names(stmt, &o, !o.readonly)) {
        outcome rest = {0};
        while (!o.readonly && step(c, stmt, false, &rest) == SQLITE_ROW) continue;
        release(c, stmt, cur->e, true, false, run_cost(stmt, cur->bytes + bytes));
        cur->stmt = NULL;
        break;
      }
      if (!named) columns_begin(env, stmt, &cols);
      named = true;
      an_list_push(env, &rows, read_row(env, stmt, &cols, &bytes));
      if (++count >= opt.rows || bytes >= opt.bytes) {
        o.code = SQLITE_ROW;
        cur->bytes += bytes;
        break;
      }
    } else if (rc == SQLITE_DONE) {
      o.code = SQLITE_DONE;
      release(c, stmt, cur->e, true, false, run_cost(stmt, cur->bytes + bytes));
      cur->stmt = NULL;
      break;
    } else if (lock_code(rc)) {
      /* The statement stays: the caller waits and fetches again, which steps it again, or gives up with finish. */
      cur->bytes += bytes;
      break;
    } else {
      release(c, stmt, cur->e, true, false, run_cost(stmt, cur->bytes + bytes));
      cur->stmt = NULL;
      break;
    }
  }
  return batch(env, &o, an_list_end(env, &rows));
}

/* finish(conn, cursor): gives back the statement of a query that stopped at a lock, on the compute pool: its reset
   waits for SQLite's mutex, which another thread may hold for a long step. */
static an_term fn_finish(an_env *env, int argc, const an_term *argv) {
  cursor_state *cur;
  (void)argc;
  conn *c = conn_of(env, argv[0]);
  if (!c) return an_badarg(env, 0);
  if (!an_get_resource(env, argv[1], CURSOR, (void **)&cur) || cur->c != c) return an_badarg(env, 1);
  if (cur->stmt) release(c, cur->stmt, cur->e, true, false, NO_STEPS);
  cur->stmt = NULL;
  cur->started = true;
  return an_void(env);
}

/* Whether a short call may run a write of KIND now (see the top of this file): a BEGIN; a write inside a transaction
   that wrote in fewer than QUICK_TXN_WRITES short calls and none on the compute pool (its dirty pages stay few, so
   SQLite does not spill them to the WAL), or one that commits itself where the commits are short (W_COMMIT); a COMMIT
   where they are, of a transaction that wrote only in a few short calls. In a pool, none of them while the share
   holds: a checkpoint runs, or the next write to the WAL starts it again and syncs its header; and one that may runs
   counted in the share (share_enter), which the caller ends with share_leave. A BEGIN writes no frame, so holding it
   is not what keeps the sync off the scheduler: it keeps Db.transaction's BEGIN IMMEDIATE, which takes its snapshot
   at once, from taking one while a checkpoint runs, whose commit would then append to the WAL rather than start it
   again. With a compute pool of one thread such writers kept the WAL from starting again under 300 ms syncs. A
   deferred BEGIN takes no snapshot, and holding it only costs a call on the compute pool. Under SQLite's mutex of
   the database, which guards txn_writes and share. */
static bool write_now(conn *c, unsigned char kind, int level) {
  bool fits;
  if (kind == K_BEGIN)
    fits = true;
  else if (kind == K_WRITE)
    fits = sq.get_autocommit(c->db) ? level >= W_COMMIT : c->txn_writes < QUICK_TXN_WRITES;
  else
    fits = level >= W_COMMIT && c->txn_writes <= QUICK_TXN_WRITES;
  return fits && (!c->share || share_enter(c->share));
}

/* quick(conn, sql, params, options): the whole result of a cached statement in this short call, or none for the
   caller to fetch it: not cached, not one that a short call may run (classify, write_now), busy on another thread,
   a read over the budget or the caps, or a lock. It never waits for a lock or SQLite's mutex, so the scheduler that
   runs it never stops for another thread. A write has no budget and no row cap: once it has stepped it runs to its
   end here, and a lock, which comes before it has done anything that its reset does not undo, is the one fallback. */
static an_term fn_quick(an_env *env, int argc, const an_term *argv) {
  const char *sql;
  size_t len;
  fetch_options opt;
  outcome o = {0};
  (void)argc;
  conn *c = conn_of(env, argv[0]);
  if (!c) return an_badarg(env, 0);
  if (!an_get_string(env, argv[1], &sql, &len)) return an_badarg(env, 1);
  if (!read_options(env, argv[3], &opt)) return an_badarg(env, 3);
  if (!opt.cache || opt.quick_steps <= 0 || opt.quick_rows <= 0 || !lock_try(&c->lock)) return an_none(env);
  /* What a free function left needs a fetch first (settle), which may wait. */
  entry *e = c->pending > 0 ? NULL : find_idle(c, sql, len, hash_text(sql, len));
  int level = c->level;
  /* A dirty entry needs its reset, which may wait: fetch makes it. A write whose last run took more instructions than
     the budget of a read runs on the compute pool. */
  bool unfit = e && (e->kind == K_NONE || e->long_value || (e->kind != K_READ && level == W_NONE) ||
                     (e->kind == K_WRITE && e->steps > opt.quick_steps));
  if (e && (unfit || e->dirty)) {
    e->busy = false;
    e = NULL;
  }
  lock_drop(&c->lock);
  if (!e) return an_none(env);
  sqlite3_stmt *stmt = e->stmt;
  sqlite3_mutex *m = sq.db_mutex(c->db);
  if (sq.mutex_try(m) != SQLITE_OK) {
    /* An idle entry is reset already: a reset here would wait for the mutex that another thread holds. */
    release(c, stmt, e, false, false, NO_STEPS);
    return an_none(env);
  }
  bool writes = e->kind != K_READ;
  bool stale = sq.stmt_status(stmt, SQLITE_STMTSTATUS_REPREPARE, 0) != e->checked;
  if (stale || (writes && !write_now(c, e->kind, level))) {
    /* SQLite prepared it again since its plan was read: fetch reads the plan again. A schema change that lands in
       this call's own step prepares it there, with a plan not read yet: that one run may meet a long instruction,
       and the next call falls back here. A write that may not run now (write_now) runs on the compute pool. */
    sq.mutex_leave(m);
    release(c, stmt, e, false, false, NO_STEPS);
    return an_none(env);
  }
  bool done = false, fallback = false, toobig = false, big = false, over;
  o.readonly = sq.stmt_readonly(stmt) != 0;
  an_list_builder rows;
  an_list_begin(env, &rows, 0);
  columns cols;
  /* Big bound data can take long in one instruction (a JSON function over it): past QUICK_BYTES fetch runs it. */
  if (!bind_all(env, stmt, argv[2], 2, QUICK_BYTES, &over, &o.why)) {
    fallback = over;
    done = !over;
    if (!over) o.code = -1;
  } else {
    int64_t count = 0, bytes = 0;
    int64_t cap = opt.rows < opt.quick_rows ? opt.rows : opt.quick_rows;
    int64_t most = opt.bytes < QUICK_BYTES ? opt.bytes : QUICK_BYTES;
    bool named = false;
    c->quick_over = false;
    /* At least one call of the progress handler, which stops a read at its first; none for a write. */
    c->quick_left = writes ? 0 : opt.quick_steps > PROGRESS_OPS ? opt.quick_steps / PROGRESS_OPS : 1;
    /* One instruction can make or copy a value of any size (randomblob, a blob column), which neither the budget nor
       the plan bounds: a longer value or row fails with SQLITE_TOOBIG, which aborts only the statement, and fetch
       runs it again. A page that SQLite writes to the WAL before the commit (a spill of the page cache, which
       CACHE_WRITE counts in every version, CACHE_SPILL only in some) makes the transaction heavy. */
    int length = sq.limit(c->db, SQLITE_LIMIT_LENGTH, QUICK_BYTES);
    int written = 0, unused = 0;
    bool counts = writes && sq.db_status(c->db, SQLITE_DBSTATUS_CACHE_WRITE, &written, &unused, 0) == SQLITE_OK;
    while (!done && !fallback) {
      int rc = step(c, stmt, true, &o);
      if (rc == SQLITE_ROW) {
        if (!opt.keep) continue;
        /* Read after the step, as fetch does. Columns that repeat a name since the schema changed are fetch's to
           report for a read; a write has run by its first row, so it runs to its end and says so, as fetch does. */
        int which;
        if (!named && !distinct_names(stmt, &which)) {
          fallback = !writes;
          if (fallback) break;
          (void)check_names(stmt, &o, true);
          outcome rest = {0};
          while (step(c, stmt, true, &rest) == SQLITE_ROW) continue;
          if (rest.frames > o.frames) o.frames = rest.frames;
          done = true;
          break;
        }
        if (!named) columns_begin(env, stmt, &cols);
        named = true;
        /* A row of a read past the caps: the result takes more than one batch, which only fetch gives. The rows of a
           write are its RETURNING, which its plan bounds. */
        fallback = !writes && (count >= cap || bytes + row_size(stmt, cols.n) > most);
        if (fallback) break;
        /* The rows of a write are read whatever they take, since it ran: past the caps, its next run is fetch's. */
        if (writes && (count >= cap || bytes + row_size(stmt, cols.n) > most)) big = true;
        an_list_push(env, &rows, read_row(env, stmt, &cols, &bytes));
        count++;
      } else if (rc == SQLITE_DONE) {
        o.code = SQLITE_DONE;
        done = true;
      } else {
        toobig = rc == SQLITE_TOOBIG;
        fallback = lock_code(rc) || toobig || (!writes && rc == SQLITE_INTERRUPT && c->quick_over);
        done = !fallback;
      }
    }
    c->quick_left = 0;
    (void)sq.limit(c->db, SQLITE_LIMIT_LENGTH, length);
    int now = 0;
    if (counts && !sq.get_autocommit(c->db) &&
        sq.db_status(c->db, SQLITE_DBSTATUS_CACHE_WRITE, &now, &unused, 0) == SQLITE_OK && now != written)
      c->txn_writes = TXN_HEAVY;
  }
  /* Reset under the mutex this call holds, so that giving the statement back never waits for another thread. The
     reset of a write that a lock stopped undoes what it began. */
  (void)sq.reset(stmt);
  (void)sq.clear_bindings(stmt);
  /* Only a run to its end counts: a write that a lock stopped took a few steps of what it does. A value too long, or
     rows too big, send the next runs to fetch until one of them is cheap again. */
  int steps = run_steps(stmt);
  if (toobig || big) steps = INT_MAX;
  if (writes && c->share) share_leave(c->share);
  sq.mutex_leave(m);
  release(c, stmt, e, false, !fallback, (done && !fallback) || toobig ? steps : NO_STEPS);
  if (fallback) {
    lock_take(&c->lock);
    c->fallbacks++;
    lock_drop(&c->lock);
  }
  an_term list = an_list_end(env, &rows);
  if (fallback) return an_none(env);
  if (!writes) o.changes = 0;
  return an_some(env, batch(env, &o, list));
}

/* inline_writes(conn, commits): lets the short calls run the writes and the BEGIN of a transaction, and with COMMITS
   (only once own_checkpoints ran) a write that commits too. The adapter asks for it in a WAL database only, where a
   write inside a transaction never syncs a file (see the top of this file). */
static an_term fn_inline_writes(an_env *env, int argc, const an_term *argv) {
  bool commits;
  (void)argc;
  conn *c = conn_of(env, argv[0]);
  if (!c) return an_badarg(env, 0);
  if (!an_get_bool(env, argv[1], &commits)) return an_badarg(env, 1);
  lock_take(&c->lock);
  c->level = commits && c->hooked ? W_COMMIT : W_TRANSACTION;
  lock_drop(&c->lock);
  return an_void(env);
}

static void wal_free(void *state) {
  wal_state *w = state;
  if (w->s) share_unref(w->s);
}

/* The share of a Wal resource, or NULL (a bad argument). */
static wal_share *wal_of(an_env *env, an_term t) {
  wal_state *w;
  if (!an_get_resource(env, t, WAL, (void **)&w)) return NULL;
  return w->s;
}

/* wal(): a new share for the connections of a pool and its checkpointer. */
static an_term fn_wal(an_env *env, int argc, const an_term *argv) {
  (void)argc;
  (void)argv;
  an_term out;
  wal_state *w = an_resource_new(env, WAL, &out);
  if (!w) return out;
  w->s = share_new();
  if (!w->s) return an_raise(env, "sqlite: out of memory");
  return out;
}

/* own_checkpoints(conn, wal): the pool takes the checkpoints of this connection, whose WAL it shares in WAL. The WAL
   hook replaces SQLite's autocheckpoint (which is also a WAL hook), so no commit of the connection checkpoints, and
   gives the frames in the WAL after each commit (Batch.frames). On the compute pool: it takes SQLite's mutex of the
   database. A second call keeps the first share. */
static an_term fn_own_checkpoints(an_env *env, int argc, const an_term *argv) {
  (void)argc;
  conn *c = conn_of(env, argv[0]);
  if (!c) return an_badarg(env, 0);
  wal_share *share = wal_of(env, argv[1]);
  if (!share) return an_badarg(env, 1);
  sqlite3_mutex *m = sq.db_mutex(c->db);
  sq.mutex_enter(m);
  /* The previous hook (SQLite's autocheckpoint) is what it gives back, which nothing needs. */
  (void)sq.wal_hook(c->db, wal_frames, c);
  if (!c->share) {
    share_ref(share);
    c->share = share;
  }
  sq.mutex_leave(m);
  lock_take(&c->lock);
  c->hooked = true;
  lock_drop(&c->lock);
  return an_void(env);
}

/* checkpoint(conn, wal): a PASSIVE checkpoint of the WAL that the pool shares in WAL, on the compute pool. It copies
   what no reader needs and waits for nobody; while it runs, and after it when it copied every frame, the share holds
   the short writes of the pool. A failure (another checkpoint runs) changes nothing, and the next one goes on. */
static an_term fn_checkpoint(an_env *env, int argc, const an_term *argv) {
  (void)argc;
  conn *c = conn_of(env, argv[0]);
  if (!c) return an_badarg(env, 0);
  wal_share *share = wal_of(env, argv[1]);
  if (!share) return an_badarg(env, 1);
  int log = -1, copied = -1;
  share_checkpoint(share);
  int rc = sq.wal_checkpoint_v2(c->db, NULL, SQLITE_CHECKPOINT_PASSIVE, &log, &copied);
  share_checkpointed(share, rc == SQLITE_OK && log >= 0 && copied == log, rc == SQLITE_OK ? copied : -1);
  return an_void(env);
}

/* pending?(conn): whether free functions left statements to settle. */
static an_term fn_pending(an_env *env, int argc, const an_term *argv) {
  (void)argc;
  conn *c = conn_of(env, argv[0]);
  if (!c) return an_badarg(env, 0);
  lock_take(&c->lock);
  bool any = c->pending > 0;
  lock_drop(&c->lock);
  return an_bool(env, any);
}

/* tidy(conn): settles them, on the compute pool. */
static an_term fn_tidy(an_env *env, int argc, const an_term *argv) {
  (void)argc;
  conn *c = conn_of(env, argv[0]);
  if (!c) return an_badarg(env, 0);
  settle(c);
  return an_void(env);
}

static an_term fn_interrupt(an_env *env, int argc, const an_term *argv) {
  (void)argc;
  conn *c = conn_of(env, argv[0]);
  if (!c) return an_badarg(env, 0);
  sq.interrupt(c->db);
  return an_void(env);
}

static an_term fn_autocommit(an_env *env, int argc, const an_term *argv) {
  (void)argc;
  conn *c = conn_of(env, argv[0]);
  if (!c) return an_badarg(env, 0);
  return an_bool(env, sq.get_autocommit(c->db) != 0);
}

/* cache_stats(conn): what the statement cache holds and has done. */
static an_term fn_cache_stats(an_env *env, int argc, const an_term *argv) {
  (void)argc;
  conn *c = conn_of(env, argv[0]);
  if (!c) return an_badarg(env, 0);
  int64_t size = 0;
  lock_take(&c->lock);
  for (int i = 0; i < c->capacity; i++) size += c->entries[i].sql != NULL;
  an_term fields[7] = {an_int(env, size),
                       an_int(env, c->capacity),
                       an_int(env, (int64_t)c->hits),
                       an_int(env, (int64_t)c->misses),
                       an_int(env, (int64_t)c->evictions),
                       an_int(env, (int64_t)c->shorts),
                       an_int(env, (int64_t)c->fallbacks)};
  lock_drop(&c->lock);
  return an_struct(env, CACHE_STATS, fields);
}

static const an_type types[] = {
  {"Value", AN_ENUM, "Null | Int(Int) | Float(Float) | Text(String) | Blob(Bytes) | Bool(Bool)"},
  {"Batch", AN_STRUCT,
   "code: Int, extended: Int, upgrade: Bool, readonly: Bool, failure: String, rows: List[Map[String, Value]], "
   "changes: Int, frames: Int"},
  {"Fetch", AN_STRUCT, "keep: Bool, cache: Bool, rows: Int, bytes: Int, quick_rows: Int, quick_steps: Int"},
  {"CacheStats", AN_STRUCT,
   "size: Int, capacity: Int, hits: Int, misses: Int, evictions: Int, shorts: Int, fallbacks: Int"},
};

static const an_resource_type resources[] = {
  {"Conn", sizeof(conn_state), conn_free},
  {"Cursor", sizeof(cursor_state), cursor_free},
  {"Wal", sizeof(wal_state), wal_free},
};

static const an_function functions[] = {
  {"connect", "(String, Int, Int) -> Result[Conn]", fn_connect, AN_DIRTY},
  {"cursor", "(Conn) -> Cursor", fn_cursor, AN_SHORT},
  {"fetch", "(Conn, Cursor, String, List[Value], Fetch) -> Batch", fn_fetch, AN_DIRTY},
  {"finish", "(Conn, Cursor) -> Void", fn_finish, AN_DIRTY},
  {"pending?", "(Conn) -> Bool", fn_pending, AN_SHORT},
  {"tidy", "(Conn) -> Void", fn_tidy, AN_DIRTY},
  {"quick", "(Conn, String, List[Value], Fetch) -> Optional[Batch]", fn_quick, AN_SHORT},
  {"inline_writes", "(Conn, Bool) -> Void", fn_inline_writes, AN_SHORT},
  {"wal", "() -> Wal", fn_wal, AN_SHORT},
  {"own_checkpoints", "(Conn, Wal) -> Void", fn_own_checkpoints, AN_DIRTY},
  {"checkpoint", "(Conn, Wal) -> Void", fn_checkpoint, AN_DIRTY},
  {"interrupt", "(Conn) -> Void", fn_interrupt, AN_SHORT},
  {"autocommit?", "(Conn) -> Bool", fn_autocommit, AN_SHORT},
  {"cache_stats", "(Conn) -> CacheStats", fn_cache_stats, AN_SHORT},
};

AN_MODULE_TABLES("db_sqlite", functions, AN_COUNT(functions), types, AN_COUNT(types), resources, AN_COUNT(resources),
                 NULL)
