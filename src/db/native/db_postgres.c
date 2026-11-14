/*
 * The native PostgreSQL driver of agentica-db: an Agentica native module (agentica_native.h) over the system libpq.
 *
 * It opens libpq itself at the first `connect` (libpq.so.5, libpq.5.dylib or libpq.dll, the libraries that the FFI
 * adapter names), so building it needs only a C compiler: no libpq headers, no import library. The prototypes below
 * are the stable C API of libpq 9.x and later.
 *
 * Every call but `connect` and `cancel` is short: the connection is in libpq's non-blocking mode, a call sends what it
 * can and reads what has come, and when it would wait it gives the socket back (`Step.state` READ or WRITE). The
 * adapter (postgres/native.agc) waits for it with Native.wait_readable or wait_writable, which parks only its task,
 * and calls `resume` again. The query of a connection goes through phases:
 *   - DRAIN: the results of a query that a cancelled task left on the connection, read and dropped, after one cancel
 *     request (CANCEL, the one compute call of the path, since PQcancel connects to the server);
 *   - CHORE: the DEALLOCATE of the statements that the cache let go, in one round trip, when enough are waiting and no
 *     transaction is open;
 *   - PREPARE: a statement that the cache does not hold yet is prepared under a name of its own (`agentica_N`);
 *   - EXEC: the cached statement runs by its name (PQsendQueryPrepared), or one that is not cached by its text;
 *   - ROWS: the result has come whole (libpq keeps it in a PGresult), and each call turns up to the caps of rows and
 *     bytes into Agentica values.
 * The cache is keyed by the sql that the adapter got (with its `?`), so a cached statement needs no translation and
 * no check in Agentica. A cached statement that the server refuses because its table changed (0A000, "cached plan
 * must not change result type") or forgot (26000) is dropped, and run once more when no transaction was open; a
 * statement that changes the schema (the adapter says so: `Plan.flush`) lets go of the whole cache.
 *
 * Calls on one connection are made one at a time: the adapter holds a Native.Mutex of the connection for the whole
 * query. `lock` below only refuses a call that would break that rule. A task cancelled in the middle of a query leaves
 * it on the connection, and the next query drains it first; the free function of the connection never waits (PQfinish
 * on a non-blocking socket).
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

#include <inttypes.h>
#include <limits.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "agentica_native.h"

/* The libpq C API that the driver uses (libpq-fe.h). */
typedef struct pg_conn PGconn;
typedef struct pg_result PGresult;
typedef struct pg_cancel PGcancel;
typedef struct pg_cancel_conn PGcancelConn;
typedef unsigned int Oid;

enum {
  CONNECTION_OK = 0,
  CONNECTION_BAD = 1,
  PGRES_EMPTY_QUERY = 0,
  PGRES_COMMAND_OK = 1,
  PGRES_TUPLES_OK = 2,
  PGRES_COPY_OUT = 3,
  PGRES_COPY_IN = 4,
  PGRES_COPY_BOTH = 8,
  PQTRANS_IDLE = 0,
  PQTRANS_UNKNOWN = 4,
  PG_DIAG_SQLSTATE = 'C',
  PG_DIAG_MESSAGE_PRIMARY = 'M',
  PG_DIAG_SOURCE_FUNCTION = 'R',
  PGRES_POLLING_FAILED = 0,
  PGRES_POLLING_OK = 3,
};

/* The type oids of pg_type.h that have a Value variant; every other type comes back as text. */
enum {
  BOOL_OID = 16,
  BYTEA_OID = 17,
  INT8_OID = 20,
  INT2_OID = 21,
  INT4_OID = 23,
  FLOAT4_OID = 700,
  FLOAT8_OID = 701,
};

typedef struct {
  PGconn *(*connectdb)(const char *);
  void (*finish)(PGconn *);
  int (*status)(const PGconn *);
  int (*transaction_status)(const PGconn *);
  char *(*error_message)(const PGconn *);
  int (*set_client_encoding)(PGconn *, const char *);
  int (*set_nonblocking)(PGconn *, int);
  int (*socket)(const PGconn *);
  int (*send_query)(PGconn *, const char *);
  int (*send_query_params)(PGconn *, const char *, int, const Oid *, const char *const *, const int *, const int *,
                           int);
  int (*send_prepare)(PGconn *, const char *, const char *, int, const Oid *);
  int (*send_query_prepared)(PGconn *, const char *, int, const char *const *, const int *, const int *, int);
  int (*flush)(PGconn *);
  int (*consume_input)(PGconn *);
  int (*is_busy)(PGconn *);
  PGresult *(*get_result)(PGconn *);
  int (*result_status)(const PGresult *);
  char *(*result_error_field)(const PGresult *, int);
  void (*clear)(PGresult *);
  char *(*cmd_status)(PGresult *);
  char *(*cmd_tuples)(PGresult *);
  int (*ntuples)(const PGresult *);
  int (*nfields)(const PGresult *);
  char *(*fname)(const PGresult *, int);
  Oid (*ftype)(const PGresult *, int);
  char *(*getvalue)(const PGresult *, int, int);
  int (*getlength)(const PGresult *, int, int);
  int (*getisnull)(const PGresult *, int, int);
  unsigned char *(*unescape_bytea)(const unsigned char *, size_t *);
  void (*freemem)(void *);
  int (*put_copy_end)(PGconn *, const char *);
  int (*get_copy_data)(PGconn *, char **, int);
  PGcancel *(*get_cancel)(PGconn *);
  int (*cancel)(PGcancel *, char *, int);
  void (*free_cancel)(PGcancel *);
} pq_api;

static pq_api pq;
/* The cancel requests of libpq 17 (PQcancelCreate and the rest), which can give up after a while: PQcancel, the one
   of older versions, waits as long as the system lets a connect wait. Loaded when the library has them. */
typedef struct {
  PGcancelConn *(*create)(PGconn *);
  int (*start)(PGcancelConn *);
  int (*poll)(PGcancelConn *);
  void (*finish)(PGcancelConn *);
} pq_cancel_api;

static pq_cancel_api pq_cancel;

#define SYM(NAME, FIELD) {NAME, offsetof(pq_api, FIELD)}
static const struct {
  const char *name;
  size_t offset;
} SYMBOLS[] = {
  SYM("PQconnectdb", connectdb),
  SYM("PQfinish", finish),
  SYM("PQstatus", status),
  SYM("PQtransactionStatus", transaction_status),
  SYM("PQerrorMessage", error_message),
  SYM("PQsetClientEncoding", set_client_encoding),
  SYM("PQsetnonblocking", set_nonblocking),
  SYM("PQsocket", socket),
  SYM("PQsendQuery", send_query),
  SYM("PQsendQueryParams", send_query_params),
  SYM("PQsendPrepare", send_prepare),
  SYM("PQsendQueryPrepared", send_query_prepared),
  SYM("PQflush", flush),
  SYM("PQconsumeInput", consume_input),
  SYM("PQisBusy", is_busy),
  SYM("PQgetResult", get_result),
  SYM("PQresultStatus", result_status),
  SYM("PQresultErrorField", result_error_field),
  SYM("PQclear", clear),
  SYM("PQcmdStatus", cmd_status),
  SYM("PQcmdTuples", cmd_tuples),
  SYM("PQntuples", ntuples),
  SYM("PQnfields", nfields),
  SYM("PQfname", fname),
  SYM("PQftype", ftype),
  SYM("PQgetvalue", getvalue),
  SYM("PQgetlength", getlength),
  SYM("PQgetisnull", getisnull),
  SYM("PQunescapeBytea", unescape_bytea),
  SYM("PQfreemem", freemem),
  SYM("PQputCopyEnd", put_copy_end),
  SYM("PQgetCopyData", get_copy_data),
  SYM("PQgetCancel", get_cancel),
  SYM("PQcancel", cancel),
  SYM("PQfreeCancel", free_cancel),
};
#define SYMBOL_COUNT (sizeof SYMBOLS / sizeof SYMBOLS[0])
/* load_symbols fills pq field by field: SYMBOLS must name every field, and each field is a function pointer. */
_Static_assert(sizeof(pq_api) == SYMBOL_COUNT * sizeof(void (*)(void)), "SYMBOLS names every field of pq_api");

/* ---- The system: the library loader and a lock. ---- */

static char load_error[512];

#if defined(_WIN32)
typedef SRWLOCK lock_t;
static void lock_init(lock_t *l) { InitializeSRWLock(l); }
static bool lock_try(lock_t *l) { return TryAcquireSRWLockExclusive(l) != 0; }
static void lock_drop(lock_t *l) { ReleaseSRWLockExclusive(l); }
static void lock_destroy(lock_t *l) { (void)l; }

static void *library;
static INIT_ONCE load_once = INIT_ONCE_STATIC_INIT;

static void *symbol(const char *name) {
  FARPROC p = GetProcAddress((HMODULE)library, name);
  void *out;
  memcpy(&out, &p, sizeof out);
  return out;
}

static bool open_library(void) {
  /* The folder of agentica.exe and the system folder, as the VM looks up `extern "libpq.dll"`; never PATH or the
     working directory, where anyone could plant one. */
  DWORD where = LOAD_LIBRARY_SEARCH_APPLICATION_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32;
  library = (void *)LoadLibraryExW(L"libpq.dll", NULL, where);
  if (!library) snprintf(load_error, sizeof load_error, "libpq.dll: error %lu", (unsigned long)GetLastError());
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
/* A mutex that fails to set up is a broken process (EAGAIN, ENOMEM): there is no state to go back to. */
static void lock_init(lock_t *l) {
  if (pthread_mutex_init(l, NULL) != 0) abort();
}
static bool lock_try(lock_t *l) { return pthread_mutex_trylock(l) == 0; }
static void lock_drop(lock_t *l) {
  if (pthread_mutex_unlock(l) != 0) abort();
}
static void lock_destroy(lock_t *l) { (void)pthread_mutex_destroy(l); }

static void *library;
static pthread_once_t load_once = PTHREAD_ONCE_INIT;

static void *symbol(const char *name) { return dlsym(library, name); }

#if defined(__APPLE__)
/* dyld searches a bare name in the working directory too, where anyone could plant one, and macOS has no system libpq:
   the folders of DYLD_LIBRARY_PATH (as for the FFI adapter), then where Homebrew and Postgres.app put it. */
static const char *const MAC_PATHS[] = {
  "/opt/homebrew/opt/libpq/lib/libpq.5.dylib",
  "/usr/local/opt/libpq/lib/libpq.5.dylib",
  "/opt/homebrew/lib/libpq.5.dylib",
  "/usr/local/lib/libpq.5.dylib",
  "/Applications/Postgres.app/Contents/Versions/latest/lib/libpq.5.dylib",
};

static bool open_library(void) {
  char path[1024];
  const char *dirs = getenv("DYLD_LIBRARY_PATH");
  while (dirs && *dirs && !library) {
    const char *end = strchr(dirs, ':');
    size_t n = end ? (size_t)(end - dirs) : strlen(dirs);
    if (n > 0 && dirs[0] == '/' && n < sizeof path - 16) {
      snprintf(path, sizeof path, "%.*s/libpq.5.dylib", (int)n, dirs);
      library = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    }
    dirs = end ? end + 1 : NULL;
  }
  for (size_t i = 0; i < sizeof MAC_PATHS / sizeof MAC_PATHS[0] && !library; i++)
    library = dlopen(MAC_PATHS[i], RTLD_NOW | RTLD_LOCAL);
  if (!library)
    snprintf(load_error, sizeof load_error, "libpq.5.dylib is in none of DYLD_LIBRARY_PATH, Homebrew or Postgres.app");
  return library != NULL;
}
#else
static bool open_library(void) {
  /* dlopen never searches the working directory for a bare name on Linux. */
  library = dlopen("libpq.so.5", RTLD_NOW | RTLD_LOCAL);
  if (!library) {
    const char *why = dlerror();
    snprintf(load_error, sizeof load_error, "%s", why ? why : "libpq.so.5");
  }
  return library != NULL;
}
#endif

static bool load_symbols(void);
static void load_callback(void) { (void)load_symbols(); }
static void load_library_once(void) {
  if (pthread_once(&load_once, load_callback) != 0) abort();
}
#endif

/* Opens the library and fills `pq`, once per run; load_error says why when it failed. */
static bool load_symbols(void) {
  if (!open_library()) return false;
  for (size_t i = 0; i < SYMBOL_COUNT; i++) {
    void *p = symbol(SYMBOLS[i].name);
    if (!p) {
      snprintf(load_error, sizeof load_error, "the library has no %s", SYMBOLS[i].name);
      return false;
    }
    /* POSIX and Windows give a function's address as an object pointer; every field is a function pointer. */
    memcpy((char *)&pq + SYMBOLS[i].offset, &p, sizeof p);
  }
  /* All four or none: a library without them sends the cancel with PQcancel. */
  void *create = symbol("PQcancelCreate"), *start = symbol("PQcancelStart"), *poll = symbol("PQcancelPoll"),
       *finish = symbol("PQcancelFinish");
  if (create && start && poll && finish) {
    memcpy(&pq_cancel.create, &create, sizeof create);
    memcpy(&pq_cancel.start, &start, sizeof start);
    memcpy(&pq_cancel.poll, &poll, sizeof poll);
    memcpy(&pq_cancel.finish, &finish, sizeof finish);
  }
  return true;
}

static bool library_ready(void) {
  load_library_once();
  return load_error[0] == '\0';
}

/* ---- Connections and their statement cache. ---- */

/* A cached statement: the sql that the adapter got, its translation (`$1` placeholders) for a prepare again, the name
   it is prepared under on the server, and the count of its parameters. */
typedef struct {
  char *sql;
  size_t len;
  uint64_t hash;
  char *text;
  char name[32];
  int count;
  uint64_t used;
} entry;

/* The names of the statements that the cache let go and that the server still holds, for the next CHORE. */
typedef struct {
  char (*names)[32];
  int size, capacity;
} dropped;

enum { COPY_NONE, COPY_OUT, COPY_IN };

enum { P_START, P_DRAIN, P_CHORE, P_CHORE_WAIT, P_SEND, P_PREPARE, P_EXEC, P_ROWS, P_DONE };

/* The bound parameters in the text format: VALUES points into BUFFER, NULL for an SQL NULL. */
typedef struct {
  int count;
  char *buffer;
  const char **values;
} params;

/* The query that runs on a connection, from `start` to its last rows. `slot` is its cache entry (-1: none, or not
   prepared yet), `hit` that it came from the cache (the one case a refusal of the server is tried again), `idle` that
   no transaction was open when it was sent, `replan` that the server refused it because its result type changed,
   `forgot` that it drops every prepared statement of the session (DEALLOCATE ALL, DISCARD ALL). */
typedef struct {
  int phase;
  bool keep, cache, flush, forgot, hit, retried, idle, cancelled, drain_only, dirty, big, prepared, replan;
  char *sql;
  size_t len;
  uint64_t hash;
  char *text;
  int count;
  params bound;
  int slot;
  char name[32];
  PGresult *res;
  char failure[1024];
  int row;
} query;

static void clear_params(params *p) {
  free(p->buffer);
  free(p->values);
  *p = (params){0};
}

/* Frees what the query holds. A PGresult is memory of its own: its PQclear never touches the connection. */
static void query_reset(query *q) {
  if (q->res) pq.clear(q->res);
  free(q->sql);
  free(q->text);
  clear_params(&q->bound);
  *q = (query){0};
  q->slot = -1;
}

/* The C state of a connection. `lock` is held by each call for its whole length (one call at a time: see the top). A
   query sent and not read to its end leaves `inflight`, which the next query drains: its task was cancelled. */
typedef struct {
  lock_t lock;
  PGconn *pg;
  entry *entries;
  int capacity;
  dropped gone;
  uint64_t tick, serial, hits, misses, evictions;
  bool inflight, flushing;
  int copy;
  /* The name of a statement whose PREPARE was sent and not read to its end, and whether its COMMAND_OK came (the
     server holds it): a drain lets it go. The result comes before the end of the PREPARE, so a task can be cancelled
     between them. */
  char preparing[32];
  bool prepare_ok;
  query q;
} conn;

typedef struct {
  conn *c;
} conn_state;

/* The largest statement cache, as the url's statement_cache allows (postgres/url.agc). */
#define MAX_CACHE 10000
/* The DEALLOCATEs wait until this many statements are let go, so that a cache that turns over pays one round trip for
   many. */
#define CHORE_BATCH 16
/* The bytes that a value costs besides its text or bytea, for the byte cap of a batch. */
#define VALUE_COST 16
/* The most that a short call copies: bigger parameters, or a bigger row, go to the compute pool. A short call also
   turns at most QUICK_ROWS rows and QUICK_BYTES bytes into values, whatever batch_rows and batch_bytes say. */
#define QUICK_BYTES 262144
#define QUICK_ROWS 1000

static uint64_t hash_text(const char *s, size_t n) {
  uint64_t h = 14695981039346656037ull;
  for (size_t i = 0; i < n; i++) h = (h ^ (unsigned char)s[i]) * 1099511628211ull;
  return h;
}

static int find_entry(conn *c, const char *sql, size_t len, uint64_t hash) {
  for (int i = 0; i < c->capacity; i++) {
    entry *e = &c->entries[i];
    if (e->sql && e->hash == hash && e->len == len && memcmp(e->sql, sql, len) == 0) return i;
  }
  return -1;
}

/* Keeps the name for the next CHORE; out of memory, the server keeps the statement until the session ends. */
static void drop_name(conn *c, const char *name) {
  dropped *d = &c->gone;
  if (d->size == d->capacity) {
    int grown = d->capacity ? d->capacity * 2 : CHORE_BATCH;
    void *more = grown > d->capacity ? realloc(d->names, (size_t)grown * sizeof *d->names) : NULL;
    if (!more) return;
    d->names = more;
    d->capacity = grown;
  }
  memcpy(d->names[d->size++], name, sizeof d->names[0]);
}

static void forget(conn *c, int slot, bool on_server) {
  entry *e = &c->entries[slot];
  if (on_server) drop_name(c, e->name);
  free(e->sql);
  free(e->text);
  *e = (entry){0};
}

/* Lets go of every cached statement: a statement changed the schema, and a cached plan may not fit it any more. */
static void forget_all(conn *c) {
  for (int i = 0; i < c->capacity; i++)
    if (c->entries[i].sql) forget(c, i, true);
}

/* Lets go of every cached statement and of the names that wait for a CHORE: the server dropped them all. A CHORE
   that named one would fail at it and leave the names after it on the server. */
static void forget_dropped(conn *c) {
  for (int i = 0; i < c->capacity; i++)
    if (c->entries[i].sql) forget(c, i, false);
  c->gone.size = 0;
}

/* Caches a statement that the server prepared as NAME, in a free slot or the one used least long ago (evicted). */
static void insert(conn *c, const char *sql, size_t len, uint64_t hash, const char *text, const char *name,
                   int count) {
  if (c->capacity == 0) return;
  int slot = -1;
  for (int i = 0; i < c->capacity && slot < 0; i++)
    if (!c->entries[i].sql) slot = i;
  if (slot < 0) {
    slot = 0;
    for (int i = 1; i < c->capacity; i++)
      if (c->entries[i].used < c->entries[slot].used) slot = i;
    forget(c, slot, true);
    c->evictions++;
  }
  char *copy = malloc(len ? len : 1);
  char *text_copy = malloc(strlen(text) + 1);
  if (!copy || !text_copy) {
    /* Out of memory: the statement stays on the server under its name, and goes at the next CHORE. */
    free(copy);
    free(text_copy);
    drop_name(c, name);
    return;
  }
  memcpy(copy, sql, len);
  strcpy(text_copy, text);
  entry *e = &c->entries[slot];
  *e = (entry){copy, len, hash, text_copy, {0}, count, ++c->tick};
  memcpy(e->name, name, sizeof e->name);
}

static void conn_free(void *state) {
  conn *c = ((conn_state *)state)->c;
  if (!c) return;
  /* PQfinish sends a Terminate message on the non-blocking socket, which never waits, and closes it; the server ends
     a statement that still runs at its next write to the closed socket. */
  pq.finish(c->pg);
  for (int i = 0; i < c->capacity; i++) {
    free(c->entries[i].sql);
    free(c->entries[i].text);
  }
  free(c->entries);
  free(c->gone.names);
  query_reset(&c->q);
  lock_destroy(&c->lock);
  free(c);
}

/* Frees the query once its last step is made: the result can be big. */
static void end_query(query *q) {
  query_reset(q);
  q->phase = P_DONE;
}

/* ---- Terms. ---- */

enum { VALUE, PLAN, OPTIONS, STEP, CACHE_STATS };
enum { V_NULL, V_INT, V_FLOAT, V_TEXT, V_BLOB, V_BOOL };
enum { CONN };
enum { PL_KNOWN, PL_TEXT, PL_COUNT, PL_CACHE, PL_FLUSH, PL_FORGOT, PL_KEEP, PLAN_FIELDS };
enum { O_ROWS, O_BYTES };
/* What `Step.state` asks of the adapter. */
enum { S_READ = 1, S_WRITE, S_ROWS, S_DONE, S_FAILED, S_PLAN, S_CANCEL, S_BIG_START, S_BIG };

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

/* A String of the bytes, each byte that is not UTF-8 replaced by U+FFFD: a SQL_ASCII database sends its bytes as they
   are, whatever the client encoding. */
static an_term text(an_env *env, const char *data, size_t len) {
  const unsigned char *s = (const unsigned char *)(data ? data : "");
  size_t i = 0, step;
  while (i < len && (step = utf8_char(s + i, len - i)) != 0) i += step;
  if (i == len) return an_string(env, (const char *)s, len);
  if (len > (SIZE_MAX - 1) / 3) return an_raise(env, "postgres: a text is too long");
  char *out = malloc(len * 3 + 1);
  if (!out) return an_raise(env, "postgres: out of memory");
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

/* `postgres error: <message>`, the message of libpq without the white space around it. */
static void fail_with(char *out, size_t size, const char *message) {
  const char *m = message ? message : "";
  while (*m == ' ' || (*m >= '\t' && *m <= '\r')) m++;
  size_t n = strlen(m);
  while (n > 0 && (m[n - 1] == ' ' || (m[n - 1] >= '\t' && m[n - 1] <= '\r'))) n--;
  snprintf(out, size, "postgres error: %.*s", (int)(n < 900 ? n : 900), m);
}

static void fail_conn(query *cur, conn *c) {
  if (!cur->failure[0]) fail_with(cur->failure, sizeof cur->failure, pq.error_message(c->pg));
}

/* The failure of a result as the FFI adapter words it: the SQLSTATE and the primary message of the server, or the
   message of libpq for one that has no SQLSTATE (a lost connection). */
static void fail_result(query *cur, conn *c, const PGresult *res) {
  if (cur->failure[0]) return;
  const char *code = pq.result_error_field(res, PG_DIAG_SQLSTATE);
  const char *message = pq.result_error_field(res, PG_DIAG_MESSAGE_PRIMARY);
  if (!code || !code[0]) {
    fail_conn(cur, c);
    return;
  }
  /* 0A000 is "feature not supported" too: only the one of the plan cache is about the statement's result type. */
  const char *routine = pq.result_error_field(res, PG_DIAG_SOURCE_FUNCTION);
  cur->replan = strcmp(code, "0A000") == 0 && routine && strcmp(routine, "RevalidateCachedQuery") == 0;
  snprintf(cur->failure, sizeof cur->failure, "postgres error %s: %s", code, message ? message : "");
}

static an_term make_step(an_env *env, conn *c, int state, const char *failure, an_term rows, int64_t changes,
                         const char *tag) {
  an_term fields[6] = {
    an_int(env, state), an_int(env, pq.socket(c->pg)), text0(env, failure),
    rows,               an_int(env, changes),            text0(env, tag),
  };
  return an_struct(env, STEP, fields);
}

static an_term no_rows(an_env *env) { return an_list(env, NULL, 0); }

static an_term step_state(an_env *env, conn *c, int state) {
  return make_step(env, c, state, "", no_rows(env), 0, "");
}

/* ---- Binding. ---- */

/* The float in the shortest digits that read back the same, as Float#to_s writes it (the server parses the text
   exactly), and the server's spellings of the infinities and NaN. The VM never calls setlocale, so the decimal point
   is a dot. */
static int float_text(double x, char *out, size_t size) {
  if (isnan(x)) return snprintf(out, size, "NaN");
  if (isinf(x)) return snprintf(out, size, x < 0 ? "-Infinity" : "Infinity");
  int n = 0;
  for (int digits = 15; digits <= 17; digits++) {
    n = snprintf(out, size, "%.*g", digits, x);
    if (strtod(out, NULL) == x) break;
  }
  return n;
}

/* Puts PARAMS (a List[Value]) into the text format of the server: an Int, a Float, a Bool (`t`, `f`), a Text as it
   is, a Blob in the hex form of bytea (`\x00ff`). False with the failure in OUT, or with *OVER when they take more
   than LIMIT bytes. */
static bool bind_all(an_env *env, an_term list, size_t limit, params *p, bool *over, char *out, size_t size) {
  an_list_cursor walk;
  size_t n;
  an_term item;
  if (!an_list_cursor_begin(env, list, &walk, &n)) {
    snprintf(out, size, "postgres error: the parameters are not a list");
    return false;
  }
  if (n > 65535) {
    /* The most that the protocol carries; the count check of the caller comes first. */
    snprintf(out, size, "postgres error: more than 65535 parameters");
    return false;
  }
  /* A first walk sizes the buffer: a number takes at most 32 bytes, a text its bytes, a blob 2 per byte and 2 more. */
  size_t total = 0;
  while (an_list_next(env, &walk, &item)) {
    uint32_t variant;
    an_term payload;
    const char *data;
    const uint8_t *bytes;
    size_t len = 0;
    if (!an_get_variant(env, item, VALUE, &variant)) variant = UINT32_MAX;
    bool is_text = variant == V_TEXT && an_get_payload(env, item, VALUE, 0, &payload) &&
                   an_get_string(env, payload, &data, &len);
    bool is_blob = !is_text && variant == V_BLOB && an_get_payload(env, item, VALUE, 0, &payload) &&
                   an_get_bytes(env, payload, &bytes, &len);
    size_t need = is_text ? len + 1 : is_blob ? 2 * len + 3 : 33;
    if (len > SIZE_MAX / 4 || need > SIZE_MAX / 2 - total) {
      snprintf(out, size, "postgres error: a parameter is too long");
      return false;
    }
    total += need;
  }
  if (total > limit) {
    *over = true;
    return false;
  }
  p->count = (int)n;
  p->buffer = malloc(total ? total : 1);
  p->values = calloc(n ? n : 1, sizeof *p->values);
  if (!p->buffer || !p->values) {
    clear_params(p);
    snprintf(out, size, "postgres error: out of memory");
    return false;
  }
  static const char HEX[] = "0123456789abcdef";
  char *at = p->buffer;
  (void)an_list_cursor_begin(env, list, &walk, &n);
  for (size_t i = 0; an_list_next(env, &walk, &item); i++) {
    uint32_t variant;
    an_term payload;
    int64_t whole;
    double x;
    bool flag;
    const char *data;
    const uint8_t *bytes;
    size_t len;
    bool good = false;
    if (!an_get_variant(env, item, VALUE, &variant)) variant = UINT32_MAX;
    if (variant == V_NULL) {
      p->values[i] = NULL;
      continue;
    }
    if (variant != UINT32_MAX && an_get_payload(env, item, VALUE, 0, &payload)) {
      p->values[i] = at;
      if (variant == V_INT && an_get_int(env, payload, &whole)) {
        at += snprintf(at, 33, "%" PRId64, whole) + 1;
        good = true;
      } else if (variant == V_FLOAT && an_get_float(env, payload, &x)) {
        at += float_text(x, at, 33) + 1;
        good = true;
      } else if (variant == V_BOOL && an_get_bool(env, payload, &flag)) {
        memcpy(at, flag ? "t" : "f", 2);
        at += 2;
        good = true;
      } else if (variant == V_TEXT && an_get_string(env, payload, &data, &len)) {
        if (len > 0 && memchr(data, '\0', len)) {
          clear_params(p);
          snprintf(out, size, "postgres error: a text parameter contains a NUL character");
          return false;
        }
        if (len > 0) memcpy(at, data, len);
        at[len] = '\0';
        at += len + 1;
        good = true;
      } else if (variant == V_BLOB && an_get_bytes(env, payload, &bytes, &len)) {
        *at++ = '\\';
        *at++ = 'x';
        for (size_t k = 0; k < len; k++) {
          *at++ = HEX[bytes[k] >> 4];
          *at++ = HEX[bytes[k] & 15];
        }
        *at++ = '\0';
        good = true;
      }
    }
    if (!good) {
      clear_params(p);
      snprintf(out, size, "postgres error: parameter %zu is not a Value", i + 1);
      return false;
    }
  }
  return true;
}

/* ---- Reading. ---- */

/* The value of column COL of row ROW; adds its size to *BYTES. */
static an_term read_value(an_env *env, const PGresult *res, int row, int col, Oid oid, int64_t *bytes) {
  *bytes += VALUE_COST;
  if (pq.getisnull(res, row, col)) return an_enum(env, VALUE, V_NULL, NULL);
  const char *cell = pq.getvalue(res, row, col);
  int len = pq.getlength(res, row, col);
  an_term payload;
  switch (oid) {
  case INT2_OID:
  case INT4_OID:
  case INT8_OID:
    payload = an_int(env, strtoll(cell, NULL, 10));
    return an_enum(env, VALUE, V_INT, &payload);
  case FLOAT4_OID:
  case FLOAT8_OID:
    /* The server writes the shortest digits that read back exactly, and Infinity, -Infinity and NaN, which strtod
       reads too. */
    payload = an_float(env, strtod(cell, NULL));
    return an_enum(env, VALUE, V_FLOAT, &payload);
  case BOOL_OID:
    payload = an_bool(env, cell[0] == 't');
    return an_enum(env, VALUE, V_BOOL, &payload);
  case BYTEA_OID: {
    /* The hex form, or the older escape form of `bytea_output = escape`. */
    size_t n = 0;
    unsigned char *raw = pq.unescape_bytea((const unsigned char *)cell, &n);
    if (!raw) return an_raise(env, "postgres: out of memory");
    *bytes += (int64_t)n;
    payload = an_bytes(env, raw, n);
    pq.freemem(raw);
    return an_enum(env, VALUE, V_BLOB, &payload);
  }
  default:
    *bytes += len;
    payload = text(env, cell, (size_t)len);
    return an_enum(env, VALUE, V_TEXT, &payload);
  }
}

/* The columns of a row with names made once per call. Terms live only in C locals (the collector scans the stack, not
   malloc memory), so they are arrays on the stack; a wider row makes its names again for each row. */
#define MAX_NAMES 64

typedef struct {
  int n;
  Oid types[MAX_NAMES];
  an_term names[MAX_NAMES];
  an_term values[MAX_NAMES];
} columns;

static an_term read_row(an_env *env, const PGresult *res, int row, columns *cols, int64_t *bytes) {
  if (cols->n <= MAX_NAMES) {
    for (int col = 0; col < cols->n; col++)
      cols->values[col] = read_value(env, res, row, col, cols->types[col], bytes);
    return an_map_from(env, cols->names, cols->values, (size_t)cols->n);
  }
  an_term map = an_map_from(env, NULL, NULL, 0);
  for (int col = 0; col < cols->n; col++) {
    an_term name = text0(env, pq.fname(res, col));
    map = an_map_put(env, map, name, read_value(env, res, row, col, pq.ftype(res, col), bytes));
  }
  return map;
}

static int compare_names(const void *a, const void *b) {
  return strcmp(*(const char *const *)a, *(const char *const *)b);
}

/* False with the failure in CUR when two columns of the result have one name. A narrow result compares each pair; a
   wide one (up to 1664 columns) sorts the names, so that a short call stays short. */
static bool check_names(query *cur, const PGresult *res) {
  int n = pq.nfields(res);
  const char *twice = NULL;
  if (n <= 32) {
    for (int i = 0; i < n && !twice; i++)
      for (int j = i + 1; j < n && !twice; j++)
        if (strcmp(pq.fname(res, i), pq.fname(res, j)) == 0) twice = pq.fname(res, i);
  } else {
    const char **names = malloc((size_t)n * sizeof *names);
    if (!names) {
      snprintf(cur->failure, sizeof cur->failure, "postgres error: out of memory");
      return false;
    }
    for (int i = 0; i < n; i++) names[i] = pq.fname(res, i);
    qsort(names, (size_t)n, sizeof *names, compare_names);
    for (int i = 1; i < n && !twice; i++)
      if (strcmp(names[i - 1], names[i]) == 0) twice = names[i];
    free(names);
  }
  if (!twice) return true;
  snprintf(cur->failure, sizeof cur->failure,
           "postgres error: the result has the column %.900s twice, alias one of them", twice);
  return false;
}

/* The rows an INSERT, UPDATE, DELETE or MERGE changed; anything else changed none. */
static int64_t changed_rows(PGresult *res) {
  static const char *const counting[] = {"INSERT ", "UPDATE ", "DELETE ", "MERGE "};
  const char *tag = pq.cmd_status(res);
  bool counts = false;
  for (size_t i = 0; i < sizeof counting / sizeof counting[0] && tag; i++)
    counts = counts || strncmp(tag, counting[i], strlen(counting[i])) == 0;
  const char *tuples = counts ? pq.cmd_tuples(res) : NULL;
  return tuples && tuples[0] ? strtoll(tuples, NULL, 10) : 0;
}

/* ---- The phases. ---- */

enum { PUMP_RESULT, PUMP_END, PUMP_READ, PUMP_WRITE, PUMP_LOST };

/* Moves the query on without waiting: flushes what libpq has to send, reads what has come, leaves a COPY that a
   statement started, and gives the next result (*RES, PUMP_RESULT), the end of the query's results (PUMP_END), what
   to wait for (PUMP_READ, PUMP_WRITE), or a lost connection (PUMP_LOST, with the failure in CUR). PQgetResult is
   called only when PQisBusy says that it will not wait. */
static int pump(conn *c, query *cur, PGresult **res) {
  *res = NULL;
  for (;;) {
    if (c->flushing) {
      int sent = pq.flush(c->pg);
      if (sent < 0) {
        fail_conn(cur, c);
        return PUMP_LOST;
      }
      if (sent > 0) {
        /* The server may wait for this side to read before it reads more: take in what has come meanwhile. */
        if (!pq.consume_input(c->pg)) {
          fail_conn(cur, c);
          return PUMP_LOST;
        }
        return PUMP_WRITE;
      }
      c->flushing = false;
    }
    if (c->copy == COPY_IN) {
      int ended = pq.put_copy_end(c->pg, "COPY is not supported");
      if (ended < 0) {
        fail_conn(cur, c);
        return PUMP_LOST;
      }
      if (ended == 0) return PUMP_WRITE;
      c->copy = COPY_NONE;
      c->flushing = true;
      continue;
    }
    if (!pq.consume_input(c->pg)) {
      fail_conn(cur, c);
      return PUMP_LOST;
    }
    if (c->copy == COPY_OUT) {
      char *data = NULL;
      int got = pq.get_copy_data(c->pg, &data, 1);
      if (data) pq.freemem(data);
      if (got > 0) continue;
      if (got == 0) return PUMP_READ;
      if (got == -2) {
        fail_conn(cur, c);
        return PUMP_LOST;
      }
      c->copy = COPY_NONE;
    }
    if (pq.is_busy(c->pg)) return pq.status(c->pg) == CONNECTION_BAD ? (fail_conn(cur, c), PUMP_LOST) : PUMP_READ;
    PGresult *r = pq.get_result(c->pg);
    if (!r) return PUMP_END;
    int status = pq.result_status(r);
    if (status == PGRES_COPY_OUT || status == PGRES_COPY_IN || status == PGRES_COPY_BOTH) {
      if (!cur->failure[0]) snprintf(cur->failure, sizeof cur->failure, "postgres error: COPY is not supported");
      c->copy = status == PGRES_COPY_IN ? COPY_IN : COPY_OUT;
      pq.clear(r);
      continue;
    }
    *res = r;
    return PUMP_RESULT;
  }
}

/* Sends what the phase sends, with the failure in CUR when libpq refuses it (a lost connection). */
static bool sent(conn *c, query *cur, int ok) {
  if (!ok) {
    fail_conn(cur, c);
    return false;
  }
  c->inflight = true;
  c->flushing = true;
  return true;
}

/* The DEALLOCATEs of the statements let go, in one simple query (one round trip). Only when no transaction is open:
   a failure there would abort the user's transaction; outside one, it only ends the implicit transaction of the
   batch. */
static bool send_chore(conn *c, query *cur) {
  dropped *d = &c->gone;
  if (d->size < CHORE_BATCH || pq.transaction_status(c->pg) != PQTRANS_IDLE) return false;
  size_t size = (size_t)d->size * (sizeof d->names[0] + 12) + 1;
  char *sql = malloc(size);
  if (!sql) return false;
  size_t at = 0;
  for (int i = 0; i < d->size; i++) at += (size_t)snprintf(sql + at, size - at, "DEALLOCATE %s;", d->names[i]);
  d->size = 0;
  bool ok = sent(c, cur, pq.send_query(c->pg, sql));
  free(sql);
  return ok;
}

/* Whether the next send carries the parameters (all but a PREPARE). */
static bool sends_params(conn *c, query *cur) {
  return cur->slot >= 0 || cur->prepared || !(cur->cache && c->capacity > 0);
}

/* Sends the statement: by its cached name, by the name a PREPARE just gave it (`prepared`, when the cache had no room
   for it), as a PREPARE of a new name, or by its text when it is not cached. */
static bool send_statement(conn *c, query *cur) {
  cur->idle = pq.transaction_status(c->pg) == PQTRANS_IDLE;
  const char *const *values = (const char *const *)cur->bound.values;
  if (cur->slot >= 0 || cur->prepared) {
    const char *name = cur->prepared ? cur->name : c->entries[cur->slot].name;
    if (!cur->prepared) c->entries[cur->slot].used = ++c->tick;
    cur->phase = P_EXEC;
    return sent(c, cur, pq.send_query_prepared(c->pg, name, cur->bound.count, values, NULL, NULL, 0));
  }
  if (cur->cache && c->capacity > 0) {
    snprintf(cur->name, sizeof cur->name, "agentica_%" PRIu64, ++c->serial);
    cur->phase = P_PREPARE;
    if (!sent(c, cur, pq.send_prepare(c->pg, cur->name, cur->text, 0, NULL))) return false;
    memcpy(c->preparing, cur->name, sizeof c->preparing);
    c->prepare_ok = false;
    return true;
  }
  cur->phase = P_EXEC;
  return sent(c, cur, pq.send_query_params(c->pg, cur->text, cur->bound.count, NULL, values, NULL, NULL, 0));
}

/* Whether a failure of a cached statement is one that a new prepare fixes: its result type changed with its table
   (0A000 of the plan cache), or the server does not hold it (26000, after a DISCARD or a DEALLOCATE of the user). */
static bool stale(const query *cur, bool *on_server) {
  *on_server = cur->replan;
  return cur->replan || strncmp(cur->failure, "postgres error 26000:", 21) == 0;
}

/* The bytes of row ROW as the byte cap counts them, without reading it. */
static int64_t row_size(const PGresult *res, int row, int n) {
  int64_t size = 0;
  for (int col = 0; col < n; col++) size += VALUE_COST + pq.getlength(res, row, col);
  return size;
}

/* The rows of the result from CUR->row, up to the caps; the step DONE at its end, ROWS before, and BIG from a short
   call that met a row too big for it. */
static an_term rows_step(an_env *env, conn *c, query *cur, int64_t max_rows, int64_t max_bytes) {
  an_list_builder rows;
  PGresult *res = cur->res;
  int total = res && cur->keep ? pq.ntuples(res) : 0;
  int64_t count = 0, bytes = 0;
  if (!cur->dirty) {
    /* A short call holds the scheduler while it runs. */
    if (max_rows > QUICK_ROWS) max_rows = QUICK_ROWS;
    if (max_bytes > QUICK_BYTES) max_bytes = QUICK_BYTES;
  }
  an_list_begin(env, &rows, 0);
  if (total > cur->row) {
    columns cols;
    cols.n = pq.nfields(res);
    if (cols.n <= MAX_NAMES)
      for (int col = 0; col < cols.n; col++) {
        cols.names[col] = text0(env, pq.fname(res, col));
        cols.types[col] = pq.ftype(res, col);
      }
    while (cur->row < total && count < max_rows && bytes < max_bytes) {
      if (!cur->dirty && row_size(res, cur->row, cols.n) > QUICK_BYTES) break;
      an_list_push(env, &rows, read_row(env, res, cur->row, &cols, &bytes));
      cur->row++;
      count++;
    }
  }
  an_term list = an_list_end(env, &rows);
  if (cur->row < total) return make_step(env, c, count == 0 ? S_BIG : S_ROWS, "", list, 0, "");
  int64_t changes = res ? changed_rows(res) : 0;
  const char *tag = res ? pq.cmd_status(res) : "";
  an_term done = make_step(env, c, S_DONE, "", list, changes, tag);
  end_query(cur);
  return done;
}

static an_term failed_step(an_env *env, conn *c, query *cur) {
  an_term failed = make_step(env, c, S_FAILED, cur->failure, no_rows(env), 0, "");
  end_query(cur);
  return failed;
}

/* Runs the phases of CUR until it must wait, has rows to give, or ends. */
static an_term advance(an_env *env, conn *c, query *cur, int64_t max_rows, int64_t max_bytes) {
  for (;;) {
    switch (cur->phase) {
    case P_START:
      cur->phase = c->inflight ? P_DRAIN : P_CHORE;
      continue;
    case P_CHORE:
      cur->phase = send_chore(c, cur) ? P_CHORE_WAIT : P_SEND;
      if (cur->failure[0]) return failed_step(env, c, cur);
      continue;
    case P_SEND:
      /* Big parameters are copied into libpq's buffer on the compute pool. */
      if (cur->big && !cur->dirty && sends_params(c, cur)) return step_state(env, c, S_BIG);
      if (!send_statement(c, cur)) return failed_step(env, c, cur);
      continue;
    case P_ROWS:
      return rows_step(env, c, cur, max_rows, max_bytes);
    case P_DONE:
      return an_raise(env, "postgres: the query is finished");
    default:
      break;
    }
    /* A phase that reads results: DRAIN, CHORE_WAIT, PREPARE and EXEC. */
    PGresult *r;
    int got = pump(c, cur, &r);
    if (got == PUMP_READ || got == PUMP_WRITE) {
      if (cur->phase == P_DRAIN && !cur->cancelled) {
        /* The query of a cancelled task still runs: ask the server to stop it, once (a compute call). */
        cur->cancelled = true;
        return step_state(env, c, S_CANCEL);
      }
      return step_state(env, c, got == PUMP_READ ? S_READ : S_WRITE);
    }
    if (got == PUMP_LOST) {
      c->inflight = false;
      c->flushing = false;
      c->copy = COPY_NONE;
      c->preparing[0] = '\0';
      return failed_step(env, c, cur);
    }
    if (got == PUMP_RESULT) {
      int status = pq.result_status(r);
      bool good = status == PGRES_COMMAND_OK || status == PGRES_TUPLES_OK;
      if (c->preparing[0] && status == PGRES_COMMAND_OK) c->prepare_ok = true;
      if (cur->phase == P_EXEC && good && !cur->res && !cur->failure[0]) {
        cur->res = r;
        continue;
      }
      if (cur->phase == P_EXEC && status == PGRES_EMPTY_QUERY && !cur->failure[0])
        snprintf(cur->failure, sizeof cur->failure, "postgres error: the sql has no statement");
      else if ((cur->phase == P_EXEC || cur->phase == P_PREPARE) && !good)
        fail_result(cur, c, r);
      pq.clear(r);
      continue;
    }
    /* PUMP_END: the phase is over and the connection is idle again. */
    c->inflight = false;
    if (cur->phase == P_DRAIN) {
      /* The failures of the query drained belong to the task that sent it; this one starts clean. A statement that
         it prepared and never cached goes at a CHORE; one whose PREPARE failed left none, and a DEALLOCATE of it
         would fail the CHORE. */
      cur->failure[0] = '\0';
      if (c->preparing[0] && c->prepare_ok) drop_name(c, c->preparing);
      c->preparing[0] = '\0';
      cur->phase = cur->drain_only ? P_DONE : P_CHORE;
      if (cur->drain_only) return step_state(env, c, S_DONE);
    } else if (cur->phase == P_CHORE_WAIT) {
      cur->failure[0] = '\0';
      cur->phase = P_SEND;
    } else if (cur->phase == P_PREPARE) {
      c->preparing[0] = '\0';
      if (cur->failure[0]) return failed_step(env, c, cur);
      insert(c, cur->sql, cur->len, cur->hash, cur->text, cur->name, cur->count);
      cur->slot = find_entry(c, cur->sql, cur->len, cur->hash);
      /* Out of memory, the cache has no room: the statement runs by the name it was prepared under, which insert
         left for a CHORE. */
      cur->prepared = cur->slot < 0;
      cur->phase = P_SEND;
      continue;
    } else {
      bool on_server;
      if (cur->failure[0] && cur->hit && cur->slot >= 0 && stale(cur, &on_server)) {
        forget(c, cur->slot, on_server);
        cur->slot = -1;
        if (cur->idle && !cur->retried) {
          /* Nothing ran (the server refused it before it ran), and no transaction was open: prepare it again. */
          cur->retried = true;
          cur->hit = false;
          cur->replan = false;
          cur->failure[0] = '\0';
          cur->phase = P_SEND;
          continue;
        }
      }
      if (cur->failure[0]) return failed_step(env, c, cur);
      if (!cur->res) {
        snprintf(cur->failure, sizeof cur->failure, "postgres error: the server gave no result");
        return failed_step(env, c, cur);
      }
      if (cur->keep && pq.result_status(cur->res) == PGRES_TUPLES_OK && !check_names(cur, cur->res))
        return failed_step(env, c, cur);
      if (cur->flush) forget_all(c);
      if (cur->forgot) forget_dropped(c);
      cur->phase = P_ROWS;
    }
  }
}

/* ---- The functions of the module. ---- */

static conn *conn_of(an_env *env, an_term t) {
  conn_state *s;
  if (!an_get_resource(env, t, CONN, (void **)&s) || !s->c) return NULL;
  return s->c;
}

static bool read_options(an_env *env, an_term t, int64_t *rows, int64_t *bytes) {
  an_term f[2];
  return an_get_field(env, t, OPTIONS, O_ROWS, &f[0]) && an_get_field(env, t, OPTIONS, O_BYTES, &f[1]) &&
         an_get_int(env, f[0], rows) && an_get_int(env, f[1], bytes) && *rows > 0 && *bytes > 0;
}

/* Takes the lock of the connection for one call; false (and the call fails) when another call holds it, which the
   adapter's mutex rules out. */
static bool enter(an_env *env, conn *c) {
  if (lock_try(&c->lock)) return true;
  (void)an_raise(env, "postgres: two calls ran on one connection at once");
  return false;
}

/* connect(conninfo, cache): a connection in non-blocking mode with a statement cache of CACHE statements (0: none),
   its client encoding UTF8. */
static an_term fn_connect(an_env *env, int argc, const an_term *argv) {
  const char *info;
  size_t len;
  int64_t capacity;
  char message[1024];
  (void)argc;
  if (!an_get_string(env, argv[0], &info, &len) || memchr(info, '\0', len)) return an_badarg(env, 0);
  if (!an_get_int(env, argv[1], &capacity) || capacity < 0 || capacity > MAX_CACHE) return an_badarg(env, 1);
  if (!library_ready()) {
    int n = snprintf(message, sizeof message, "postgres error: cannot load the libpq library: %s", load_error);
    return an_error(env, message, n > 0 ? (size_t)n : 0);
  }
  char *text_info = malloc(len + 1);
  conn *c = calloc(1, sizeof *c);
  entry *entries = calloc((size_t)(capacity ? capacity : 1), sizeof *entries);
  if (!text_info || !c || !entries) {
    free(text_info);
    free(c);
    free(entries);
    return an_raise(env, "postgres: out of memory");
  }
  memcpy(text_info, info, len);
  text_info[len] = '\0';
  PGconn *pg = pq.connectdb(text_info);
  free(text_info);
  const char *why = NULL;
  if (!pg) why = "out of memory";
  /* Text results are read as UTF-8 whatever the server or the environment default to. */
  else if (pq.status(pg) != CONNECTION_OK || pq.set_client_encoding(pg, "UTF8") != 0 || pq.set_nonblocking(pg, 1) != 0)
    why = pq.error_message(pg);
  if (why) {
    fail_with(message, sizeof message, why);
    if (pg) pq.finish(pg);
    free(c);
    free(entries);
    return an_error(env, message, strlen(message));
  }
  lock_init(&c->lock);
  c->pg = pg;
  c->entries = entries;
  c->capacity = (int)capacity;
  c->q.slot = -1;
  c->q.phase = P_DONE;
  an_term out;
  conn_state *s = an_resource_new(env, CONN, &out);
  if (!s) {
    pq.finish(pg);
    free(entries);
    lock_destroy(&c->lock);
    free(c);
    return out;
  }
  s->c = c;
  return an_ok(env, out);
}

/* start(conn, sql, params, plan, options): runs SQL. With a Plan that is not `known`, only a cached statement
   runs; any other comes back as PLAN, and the adapter calls again with the translated sql and what it read of it.
   Parameters of more than QUICK_BYTES in all come back as BIG_START from the short call, and `start_big` (the same
   function, on the compute pool) takes them: copying them takes a while. */
static an_term start(an_env *env, const an_term *argv, bool dirty) {
  const char *sql;
  size_t len;
  int64_t rows, bytes;
  an_term f[PLAN_FIELDS];
  bool known, cache, flush, forgot, keep;
  int64_t count;
  const char *translated = NULL;
  size_t translated_len = 0;
  conn *c = conn_of(env, argv[0]);
  if (!c) return an_badarg(env, 0);
  if (!an_get_string(env, argv[1], &sql, &len)) return an_badarg(env, 1);
  for (uint32_t i = 0; i < PLAN_FIELDS; i++)
    if (!an_get_field(env, argv[3], PLAN, i, &f[i])) return an_badarg(env, 3);
  if (!an_get_bool(env, f[PL_KNOWN], &known) || !an_get_string(env, f[PL_TEXT], &translated, &translated_len) ||
      !an_get_int(env, f[PL_COUNT], &count) || !an_get_bool(env, f[PL_CACHE], &cache) ||
      !an_get_bool(env, f[PL_FLUSH], &flush) || !an_get_bool(env, f[PL_FORGOT], &forgot) ||
      !an_get_bool(env, f[PL_KEEP], &keep) || count < 0 || count > 65535)
    return an_badarg(env, 3);
  if (!read_options(env, argv[4], &rows, &bytes)) return an_badarg(env, 4);
  if (!enter(env, c)) return an_void(env);
  uint64_t hash = hash_text(sql, len);
  int slot = find_entry(c, sql, len, hash);
  if (slot < 0 && !known) {
    lock_drop(&c->lock);
    return step_state(env, c, S_PLAN);
  }
  /* The parameters are checked and copied before the query changes: a short call gives big ones to `start_big`. */
  params bound = {0};
  char failure[sizeof c->q.failure] = "";
  bool over = false;
  if (slot >= 0) count = c->entries[slot].count;
  an_list_cursor walk;
  size_t given = 0;
  if (!an_list_cursor_begin(env, argv[2], &walk, &given)) {
    lock_drop(&c->lock);
    return an_badarg(env, 2);
  }
  if (given != (size_t)count)
    snprintf(failure, sizeof failure, "postgres error: the sql has %d %s, got %zu", (int)count,
             count == 1 ? "parameter" : "parameters", given);
  else
    (void)bind_all(env, argv[2], dirty ? SIZE_MAX : QUICK_BYTES, &bound, &over, failure, sizeof failure);
  if (over) {
    lock_drop(&c->lock);
    return step_state(env, c, S_BIG_START);
  }
  /* What a cancelled task left of its query goes; its results on the connection are drained (P_START). */
  query *cur = &c->q;
  query_reset(cur);
  cur->bound = bound;
  cur->keep = keep;
  cur->cache = cache || slot >= 0;
  cur->flush = flush;
  cur->forgot = forgot;
  cur->slot = slot;
  cur->hit = slot >= 0;
  cur->count = (int)count;
  cur->len = len;
  cur->hash = hash;
  const char *text_of = slot >= 0 ? c->entries[slot].text : translated;
  size_t text_len = slot >= 0 ? strlen(text_of) : translated_len;
  cur->sql = malloc(len ? len : 1);
  cur->text = malloc(text_len + 1);
  if (!cur->sql || !cur->text) {
    end_query(cur);
    lock_drop(&c->lock);
    return an_raise(env, "postgres: out of memory");
  }
  memcpy(cur->sql, sql, len);
  memcpy(cur->text, text_of, text_len);
  cur->text[text_len] = '\0';
  if (slot >= 0)
    c->hits++;
  else if (cache)
    c->misses++;
  an_term out;
  if (failure[0]) {
    memcpy(cur->failure, failure, sizeof failure);
    out = failed_step(env, c, cur);
  } else {
    cur->phase = P_START;
    cur->dirty = dirty;
    /* Only big parameters come to the dirty call (BIG_START). */
    cur->big = dirty;
    out = advance(env, c, cur, rows, bytes);
  }
  lock_drop(&c->lock);
  return out;
}

static an_term fn_start(an_env *env, int argc, const an_term *argv) {
  (void)argc;
  return start(env, argv, false);
}

static an_term fn_start_big(an_env *env, int argc, const an_term *argv) {
  (void)argc;
  return start(env, argv, true);
}

/* resume(conn, options): goes on with the query after a wait, or gives its next rows. A row of more than QUICK_BYTES,
   or big parameters to send, come back as BIG from the short call, and `resume_big` (on the compute pool) goes on. */
static an_term resume(an_env *env, const an_term *argv, bool dirty) {
  int64_t rows, bytes;
  conn *c = conn_of(env, argv[0]);
  if (!c) return an_badarg(env, 0);
  if (!read_options(env, argv[1], &rows, &bytes)) return an_badarg(env, 1);
  if (!enter(env, c)) return an_void(env);
  c->q.dirty = dirty;
  an_term out = advance(env, c, &c->q, rows, bytes);
  lock_drop(&c->lock);
  return out;
}

static an_term fn_resume(an_env *env, int argc, const an_term *argv) {
  (void)argc;
  return resume(env, argv, false);
}

static an_term fn_resume_big(an_env *env, int argc, const an_term *argv) {
  (void)argc;
  return resume(env, argv, true);
}

/* drain(conn): a query that only reads what a cancelled one left, so that the state of the connection can be read
   (the adapter's in_transaction?). */
static an_term fn_drain(an_env *env, int argc, const an_term *argv) {
  (void)argc;
  conn *c = conn_of(env, argv[0]);
  if (!c) return an_badarg(env, 0);
  if (!enter(env, c)) return an_void(env);
  query *cur = &c->q;
  query_reset(cur);
  cur->drain_only = true;
  cur->phase = c->inflight ? P_DRAIN : P_DONE;
  an_term out = cur->phase == P_DONE ? step_state(env, c, S_DONE) : advance(env, c, cur, 1, 1);
  lock_drop(&c->lock);
  return out;
}

/* left?(conn): whether a cancelled task left a query on the connection. */
static an_term fn_left(an_env *env, int argc, const an_term *argv) {
  (void)argc;
  conn *c = conn_of(env, argv[0]);
  if (!c) return an_badarg(env, 0);
  if (!enter(env, c)) return an_void(env);
  bool left = c->inflight;
  lock_drop(&c->lock);
  return an_bool(env, left);
}

static void sleep_ms(int ms) {
#if defined(_WIN32)
  Sleep((DWORD)ms);
#else
  struct timespec pause = {0, (long)ms * 1000000L};
  (void)nanosleep(&pause, NULL);
#endif
}

/* Milliseconds of a clock that only goes forward; a sleep of 1 ms takes about 15 ms on Windows, so turns of a loop
   are no clock. */
static uint64_t now_ms(void) {
#if defined(_WIN32)
  return (uint64_t)GetTickCount64();
#else
  struct timespec t;
  if (clock_gettime(CLOCK_MONOTONIC, &t) != 0) return 0;
  return (uint64_t)t.tv_sec * 1000u + (uint64_t)t.tv_nsec / 1000000u;
#endif
}

/* Sends the cancel request with libpq 17's PQcancelStart and PQcancelPoll, and gives up after CANCEL_WAIT_MS: a
   server that does not answer would hold a thread of the compute pool. It polls every millisecond instead of waiting
   on the socket, which keeps it the same on every system; it runs only after a task was cancelled in a query. */
#define CANCEL_WAIT_MS 5000

static void cancel_polled(PGconn *pg) {
  PGcancelConn *cc = pq_cancel.create(pg);
  if (!cc) return;
  if (pq_cancel.start(cc)) {
    /* The count of turns bounds the loop too, should the clock fail: each turn sleeps at least a millisecond. */
    uint64_t started = now_ms();
    for (int turn = 0; turn < CANCEL_WAIT_MS && now_ms() - started < CANCEL_WAIT_MS; turn++) {
      int state = pq_cancel.poll(cc);
      if (state == PGRES_POLLING_OK || state == PGRES_POLLING_FAILED) break;
      sleep_ms(1);
    }
  }
  pq_cancel.finish(cc);
}

/* cancel(conn): asks the server to stop the query that a cancelled task left on the connection (a new connection to
   the server, so on the compute pool). It does nothing when no query was left or another call holds the connection
   (a compute call of a cancelled task), and fails silently: the drain then waits for the statement to end. Before libpq 17 it is
   PQcancel, whose connect has no time limit of its own (the system's, about two minutes for a host that does not
   answer); the server is one that this connection reached, so that is rare. */
static an_term fn_cancel(an_env *env, int argc, const an_term *argv) {
  char why[256];
  (void)argc;
  conn *c = conn_of(env, argv[0]);
  if (!c) return an_badarg(env, 0);
  if (!lock_try(&c->lock)) return an_void(env);
  if (!c->inflight) {
    lock_drop(&c->lock);
    return an_void(env);
  }
  if (pq_cancel.create) {
    cancel_polled(c->pg);
  } else {
    PGcancel *handle = pq.get_cancel(c->pg);
    if (handle) {
      (void)pq.cancel(handle, why, (int)sizeof why);
      pq.free_cancel(handle);
    }
  }
  lock_drop(&c->lock);
  return an_void(env);
}

/* status(conn): PQstatus and PQtransactionStatus, as status * 16 + transaction status. */
static an_term fn_status(an_env *env, int argc, const an_term *argv) {
  (void)argc;
  conn *c = conn_of(env, argv[0]);
  if (!c) return an_badarg(env, 0);
  if (!enter(env, c)) return an_void(env);
  int both = pq.status(c->pg) * 16 + pq.transaction_status(c->pg);
  lock_drop(&c->lock);
  return an_int(env, both);
}

/* cache_stats(conn): what the statement cache holds and has done. */
static an_term fn_cache_stats(an_env *env, int argc, const an_term *argv) {
  (void)argc;
  conn *c = conn_of(env, argv[0]);
  if (!c) return an_badarg(env, 0);
  if (!enter(env, c)) return an_void(env);
  int64_t size = 0;
  for (int i = 0; i < c->capacity; i++) size += c->entries[i].sql != NULL;
  an_term fields[5] = {an_int(env, size), an_int(env, c->capacity), an_int(env, (int64_t)c->hits),
                       an_int(env, (int64_t)c->misses), an_int(env, (int64_t)c->evictions)};
  lock_drop(&c->lock);
  return an_struct(env, CACHE_STATS, fields);
}

static const an_type types[] = {
  {"Value", AN_ENUM, "Null | Int(Int) | Float(Float) | Text(String) | Blob(Bytes) | Bool(Bool)"},
  {"Plan", AN_STRUCT, "known: Bool, sql: String, count: Int, cache: Bool, flush: Bool, forgot: Bool, keep: Bool"},
  {"Options", AN_STRUCT, "rows: Int, bytes: Int"},
  {"Step", AN_STRUCT,
   "state: Int, fd: Int, failure: String, rows: List[Map[String, Value]], changes: Int, tag: String"},
  {"CacheStats", AN_STRUCT, "size: Int, capacity: Int, hits: Int, misses: Int, evictions: Int"},
};

static const an_resource_type resources[] = {
  {"Conn", sizeof(conn_state), conn_free},
};

static const an_function functions[] = {
  {"connect", "(String, Int) -> Result[Conn]", fn_connect, AN_DIRTY},
  {"start", "(Conn, String, List[Value], Plan, Options) -> Step", fn_start, AN_SHORT},
  {"start_big", "(Conn, String, List[Value], Plan, Options) -> Step", fn_start_big, AN_DIRTY},
  {"resume", "(Conn, Options) -> Step", fn_resume, AN_SHORT},
  {"resume_big", "(Conn, Options) -> Step", fn_resume_big, AN_DIRTY},
  {"drain", "(Conn) -> Step", fn_drain, AN_SHORT},
  {"left?", "(Conn) -> Bool", fn_left, AN_SHORT},
  {"cancel", "(Conn) -> Void", fn_cancel, AN_DIRTY},
  {"status", "(Conn) -> Int", fn_status, AN_SHORT},
  {"cache_stats", "(Conn) -> CacheStats", fn_cache_stats, AN_SHORT},
};

AN_MODULE_TABLES("db_postgres", functions, AN_COUNT(functions), types, AN_COUNT(types), resources,
                 AN_COUNT(resources), NULL)
