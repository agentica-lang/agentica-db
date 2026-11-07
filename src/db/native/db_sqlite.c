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
 *     thread) and the caller runs fetch. The budget is counted, not timed: a clock read can be a system call;
 *   - fetch, a dirty call on the compute pool, with a Cursor: it prepares (or takes the cached statement), binds,
 *     steps and reads up to the caps, and the next fetch goes on from there. A lock (SQLITE_BUSY, SQLITE_LOCKED) comes
 *     back at once with the rows so far, so the caller waits outside SQLite and fetches again.
 * Lock order: the lock of a connection (`conn.lock`) is never taken while SQLite's own mutex of the database is held
 * (the mutex may be taken under the lock: finalize does).
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
#endif

#include <limits.h>
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
  SQLITE_TXN_READ = 1,
  SQLITE_STMTSTATUS_REPREPARE = 5,
  SQLITE_OPEN_NOMUTEX = 0x8000,
  SQLITE_OPEN_FULLMUTEX = 0x10000,
};
/* sqlite3_txn_state came in 3.34.0; an older library does not have it, and a write is then waited for. */
#define TXN_STATE_VERSION 3034000
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

/* ---- Connections and their statement cache. ---- */

/* A cached statement. `busy` while a call or a Cursor runs it; `quick` when it may run in a short call: it only
   reads, gives columns with distinct names, its sql passes quick_text and its plan has no long instruction, as read
   when SQLite had prepared it again `checked` times (after a schema change; -1: not read yet). `dirty` when a free
   function gave it back without its reset, which the next fetch makes. */
typedef struct {
  char *sql;
  size_t len;
  uint64_t hash;
  sqlite3_stmt *stmt;
  uint64_t used;
  bool busy;
  bool quick;
  bool dirty;
  int checked;
} entry;

/* A statement that a free function could not finalize, left for the next fetch or the last free. */
typedef struct orphan {
  sqlite3_stmt *stmt;
  struct orphan *next;
} orphan;

/* The C state of a connection, shared by its Conn and its Cursors, and freed when the last of them is (`refs`).
   `lock` guards refs, closed, the entries, the orphans, `pending` (the dirty entries and the orphans) and the
   counters. quick_left and quick_over belong to the
   quick call that holds SQLite's mutex of the database, the only place they are written, so the progress handler
   (which runs inside sqlite3_step, under that mutex) reads them safely. */
typedef struct {
  lock_t lock;
  int refs;
  bool closed;
  sqlite3 *db;
  entry *entries;
  int capacity;
  orphan *orphans;
  int pending;
  uint64_t tick, hits, misses, evictions;
  int64_t quick_left;
  bool quick_over;
} conn;

typedef struct {
  conn *c;
} conn_state;

/* A statement that a query runs over several fetch calls. `e` is its cache entry, NULL for a statement of its own. */
typedef struct {
  conn *c;
  sqlite3_stmt *stmt;
  entry *e;
  bool started;
} cursor_state;

/* The largest statement cache, as the url's statement_cache allows (sqlite/url.agc). */
#define MAX_CACHE 10000
/* How often the progress handler runs, in SQLite VM instructions: a few microseconds of work. */
#define PROGRESS_OPS 200
/* The bytes that a value costs besides its text or blob, for the byte cap of a batch. */
#define VALUE_COST 16

static int progress(void *arg) {
  conn *c = arg;
  if (c->quick_left == 0 || --c->quick_left > 0) return 0;
  c->quick_over = true;
  return 1;
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

/* Whether SQL starts with WORD (any case), as a whole word, after white space; *AT is where the word ends. */
static bool starts_with_word(const char *sql, size_t len, const char *word, size_t *at) {
  size_t i = 0, n = strlen(word), k = 0;
  while (i < len && (sql[i] == ' ' || (sql[i] >= '\t' && sql[i] <= '\r'))) i++;
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

/* Whether a statement that only reads may run in a short call: a SELECT, WITH or VALUES, or one of the PRAGMAs that
   read a counter (`PRAGMA data_version`, `user_version`), with nothing after it but a `;`. A short call can be stopped
   and run again from its start (the progress handler interrupts it), which only a statement without effects allows;
   another PRAGMA may have effects or run long in one instruction. */
static bool quick_text(const char *sql, size_t len) {
  static const char *const words[] = {"select", "with", "values"};
  static const char *const pragmas[] = {"data_version", "user_version"};
  size_t at, end;
  for (size_t w = 0; w < sizeof words / sizeof words[0]; w++)
    if (starts_with_word(sql, len, words[w], &at)) return true;
  if (!starts_with_word(sql, len, "pragma", &at)) return false;
  for (size_t w = 0; w < sizeof pragmas / sizeof pragmas[0]; w++) {
    if (!starts_with_word(sql + at, len - at, pragmas[w], &end)) continue;
    const char *rest = sql + at + end, *stop = sql + len;
    while (rest < stop && (*rest == ' ' || (*rest >= '\t' && *rest <= '\r'))) rest++;
    if (rest < stop && *rest == ';') rest++;
    return blank(rest, stop);
  }
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
  *slot = (entry){copy, len, hash, stmt, ++c->tick, true, false, false, -1};
  return slot;
}

/* Gives a statement back after its run: reset, unbound, and idle in the cache, or finalized when it has no entry or
   the connection closed meanwhile (then its entry is emptied here, the only owner left). RESET is false when the
   caller has reset it already; HIT counts a run of the cached statement (a short call counts only one that ended). */
static void release(conn *c, sqlite3_stmt *stmt, entry *e, bool reset, bool hit) {
  /* reset gives the error of the last step again, which the caller has read already. */
  if (reset) {
    (void)sq.reset(stmt);
    (void)sq.clear_bindings(stmt);
  }
  bool finalize = e == NULL;
  lock_take(&c->lock);
  if (hit) c->hits++;
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

/* Settles what the free functions left: resets the dirty entries and finalizes the orphans. A statement that a lock
   stopped in its first step still counts as a running write for SQLite, which then commits nothing else on the
   connection until it is reset (and that reset rolls back what came after it), and an orphan holds a read snapshot.
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
    release(c, e->stmt, e, false, false);
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
enum { CONN, CURSOR };
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
} outcome;

static an_term batch(an_env *env, const outcome *o, an_term rows) {
  an_term fields[7] = {
    an_int(env, o->code),       an_int(env, o->extended), an_bool(env, o->upgrade), an_bool(env, o->readonly),
    text0(env, o->why.text),    rows,                     an_int(env, o->changes),
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
   nothing leaves the total as it was (sqlite3_changes then still holds an earlier statement's count). */
static int step(conn *c, sqlite3_stmt *stmt, outcome *o) {
  sqlite3_mutex *m = sq.db_mutex(c->db);
  sq.mutex_enter(m);
  int before = sq.total_changes(c->db);
  int rc = sq.step(stmt);
  if (rc == SQLITE_DONE) o->changes = sq.total_changes(c->db) == before ? 0 : sq.changes(c->db);
  if (rc != SQLITE_ROW && rc != SQLITE_DONE) {
    o->code = rc;
    o->extended = sq.extended_errcode(c->db);
    fail_code(&o->why, c, rc);
    /* A write that a read transaction of this connection asks for while another holds the write lock: SQLite does
       not wait (the holder may wait for this read lock), so neither must the caller. */
    o->upgrade = rc == SQLITE_BUSY && o->extended == SQLITE_BUSY && !sq.stmt_readonly(stmt) && sq.txn_state &&
                 sq.libversion_number() >= TXN_STATE_VERSION && sq.txn_state(c->db, NULL) == SQLITE_TXN_READ;
  }
  sq.mutex_leave(m);
  return rc;
}

/* ---- Preparing. ---- */

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

/* Whether the plan of SQL has an instruction that can run long by itself, where the progress handler never runs:
   OP_Count, the count(*) of a whole table, which reads its pages in one instruction. Such a read never runs in a short
   call. A plan that cannot be read counts as long. */
static bool long_instruction(conn *c, const char *sql, size_t len) {
  static const char PREFIX[] = "EXPLAIN ";
  size_t n = sizeof PREFIX - 1;
  if (len > INT_MAX - n) return true;
  char *text = malloc(n + len);
  if (!text) return true;
  memcpy(text, PREFIX, n);
  memcpy(text + n, sql, len);
  sqlite3_stmt *plan = NULL;
  bool found = true;
  int rc = SQLITE_DONE;
  sqlite3_mutex *m = sq.db_mutex(c->db);
  sq.mutex_enter(m);
  if (sq.prepare_v2(c->db, text, (int)(n + len), &plan, NULL) == SQLITE_OK && plan) {
    found = false;
    /* The opcode is column 1 of each row of the plan. */
    while (!found && (rc = sq.step(plan)) == SQLITE_ROW) {
      const unsigned char *op = sq.column_text(plan, 1);
      found = op && strcmp((const char *)op, "Count") == 0;
    }
    if (!found && rc != SQLITE_DONE) found = true;
  }
  /* finalize gives the error of the last step, which only decides `found`. */
  if (plan) (void)sq.finalize(plan);
  sq.mutex_leave(m);
  free(text);
  return found;
}

/* Whether a statement may run in a short call (entry.quick). */
static bool quick_plan(conn *c, sqlite3_stmt *stmt, const char *sql, size_t len) {
  int repeated;
  return sq.stmt_readonly(stmt) && sq.column_count(stmt) > 0 && quick_text(sql, len) &&
         distinct_names(stmt, &repeated) && !long_instruction(c, sql, len);
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
    bool quick = quick_plan(c, stmt, sql, len);
    lock_take(&c->lock);
    (*e)->quick = quick;
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
    /* The names are checked before the first step too, so that a write whose result cannot be read is refused
       before it writes; after a schema change only the first step shows the new columns (see below). */
    bool over;
    if (!bind_all(env, stmt, argv[3], 3, SIZE_MAX, &over, &o.why) || (opt.keep && !check_names(stmt, &o, false))) {
      if (o.code == 0) o.code = -1;
      release(c, stmt, e, true, false);
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
    int rc = step(c, stmt, &o);
    if (rc == SQLITE_ROW) {
      if (!opt.keep) continue;
      /* The columns are read after the step: SQLite prepares a statement again when the schema changed, and the new
         one may have other columns than before it ran. A write has run by its first row, and a reset would keep it
         too, so it runs to its end and the error says that it ran. */
      if (!named && !check_names(stmt, &o, !o.readonly)) {
        outcome rest = {0};
        while (!o.readonly && step(c, stmt, &rest) == SQLITE_ROW) continue;
        release(c, stmt, cur->e, true, false);
        cur->stmt = NULL;
        break;
      }
      if (!named) columns_begin(env, stmt, &cols);
      named = true;
      an_list_push(env, &rows, read_row(env, stmt, &cols, &bytes));
      if (++count >= opt.rows || bytes >= opt.bytes) {
        o.code = SQLITE_ROW;
        break;
      }
    } else if (rc == SQLITE_DONE) {
      o.code = SQLITE_DONE;
      release(c, stmt, cur->e, true, false);
      cur->stmt = NULL;
      break;
    } else if (lock_code(rc)) {
      /* The statement stays: the caller waits and fetches again, which steps it again, or gives up with finish. */
      break;
    } else {
      release(c, stmt, cur->e, true, false);
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
  if (cur->stmt) release(c, cur->stmt, cur->e, true, false);
  cur->stmt = NULL;
  cur->started = true;
  return an_void(env);
}

/* What a short call may read at most, whatever the batch allows: a bigger row is copied on the compute pool. */
#define QUICK_BYTES 262144

/* quick(conn, sql, params, options): the whole result of a cached read in this short call, or none for the caller
   to fetch it: not cached, not a read, busy on another thread, over the budget or the caps, or a lock. It never
   waits for a lock or SQLite's mutex, so the scheduler that runs it never stops for another thread. */
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
  /* A dirty entry needs its reset, which may wait: fetch makes it. */
  if (e && (!e->quick || e->dirty)) {
    e->busy = false;
    e = NULL;
  }
  lock_drop(&c->lock);
  if (!e) return an_none(env);
  sqlite3_stmt *stmt = e->stmt;
  sqlite3_mutex *m = sq.db_mutex(c->db);
  if (sq.mutex_try(m) != SQLITE_OK) {
    /* An idle entry is reset already: a reset here would wait for the mutex that another thread holds. */
    release(c, stmt, e, false, false);
    return an_none(env);
  }
  if (sq.stmt_status(stmt, SQLITE_STMTSTATUS_REPREPARE, 0) != e->checked) {
    /* SQLite prepared it again since its plan was read: fetch reads the plan again. A schema change that lands in
       this call's own step prepares it there, with a plan not read yet: that one run may meet a long instruction,
       and the next call falls back here. */
    sq.mutex_leave(m);
    release(c, stmt, e, false, false);
    return an_none(env);
  }
  bool done = false, fallback = false, over;
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
    bool named = false, repeated = false;
    c->quick_over = false;
    /* At least one call of the progress handler, which stops the statement at its first. */
    c->quick_left = opt.quick_steps > PROGRESS_OPS ? opt.quick_steps / PROGRESS_OPS : 1;
    while (!done && !fallback) {
      int rc = step(c, stmt, &o);
      if (rc == SQLITE_ROW) {
        /* Read after the step, as fetch does; columns that repeat a name since the schema changed are fetch's to
           report. */
        int which;
        if (!named) repeated = !distinct_names(stmt, &which);
        if (!named) columns_begin(env, stmt, &cols);
        named = true;
        /* A row past the caps: the result takes more than one batch, which only fetch gives. */
        fallback = repeated || count >= cap || bytes + row_size(stmt, cols.n) > most;
        if (fallback) break;
        an_list_push(env, &rows, read_row(env, stmt, &cols, &bytes));
        count++;
      } else if (rc == SQLITE_DONE) {
        o.code = SQLITE_DONE;
        done = true;
      } else {
        fallback = lock_code(rc) || (rc == SQLITE_INTERRUPT && c->quick_over);
        done = !fallback;
      }
    }
    c->quick_left = 0;
  }
  /* Reset under the mutex this call holds, so that giving the statement back never waits for another thread. */
  (void)sq.reset(stmt);
  (void)sq.clear_bindings(stmt);
  sq.mutex_leave(m);
  release(c, stmt, e, false, !fallback);
  an_term list = an_list_end(env, &rows);
  if (fallback) return an_none(env);
  o.readonly = true;
  o.changes = 0;
  return an_some(env, batch(env, &o, list));
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
  an_term fields[5] = {an_int(env, size), an_int(env, c->capacity), an_int(env, (int64_t)c->hits),
                       an_int(env, (int64_t)c->misses), an_int(env, (int64_t)c->evictions)};
  lock_drop(&c->lock);
  return an_struct(env, CACHE_STATS, fields);
}

static const an_type types[] = {
  {"Value", AN_ENUM, "Null | Int(Int) | Float(Float) | Text(String) | Blob(Bytes) | Bool(Bool)"},
  {"Batch", AN_STRUCT,
   "code: Int, extended: Int, upgrade: Bool, readonly: Bool, failure: String, rows: List[Map[String, Value]], "
   "changes: Int"},
  {"Fetch", AN_STRUCT, "keep: Bool, cache: Bool, rows: Int, bytes: Int, quick_rows: Int, quick_steps: Int"},
  {"CacheStats", AN_STRUCT, "size: Int, capacity: Int, hits: Int, misses: Int, evictions: Int"},
};

static const an_resource_type resources[] = {
  {"Conn", sizeof(conn_state), conn_free},
  {"Cursor", sizeof(cursor_state), cursor_free},
};

static const an_function functions[] = {
  {"connect", "(String, Int, Int) -> Result[Conn]", fn_connect, AN_DIRTY},
  {"cursor", "(Conn) -> Cursor", fn_cursor, AN_SHORT},
  {"fetch", "(Conn, Cursor, String, List[Value], Fetch) -> Batch", fn_fetch, AN_DIRTY},
  {"finish", "(Conn, Cursor) -> Void", fn_finish, AN_DIRTY},
  {"pending?", "(Conn) -> Bool", fn_pending, AN_SHORT},
  {"tidy", "(Conn) -> Void", fn_tidy, AN_DIRTY},
  {"quick", "(Conn, String, List[Value], Fetch) -> Optional[Batch]", fn_quick, AN_SHORT},
  {"interrupt", "(Conn) -> Void", fn_interrupt, AN_SHORT},
  {"autocommit?", "(Conn) -> Bool", fn_autocommit, AN_SHORT},
  {"cache_stats", "(Conn) -> CacheStats", fn_cache_stats, AN_SHORT},
};

AN_MODULE_TABLES("db_sqlite", functions, AN_COUNT(functions), types, AN_COUNT(types), resources, AN_COUNT(resources),
                 NULL)
