/*
 * The native MySQL and MariaDB driver of agentica-db: an Agentica native module (agentica_native.h) over the system
 * MariaDB Connector/C (libmariadb.so.3, the library that the FFI adapter names), which it opens itself at the first
 * `connect`, so building it needs only a C compiler. The declarations below are the C API of Connector/C 3.x.
 *
 * `connect` and `cancel` are compute calls (they resolve names, shake hands and block); every other call is short. The
 * connection has MYSQL_OPT_NONBLOCK, and a query runs through the non-blocking calls of the library (`_start`, then
 * `_cont` once the socket is ready): when one would wait, the call gives the socket back (`Step.state` READ or WRITE),
 * the adapter (mysql/native.agc) parks its task with Native.wait_readable or wait_writable, and `resume` polls the
 * socket and goes on. The phases of a query:
 *   - CLOSE: the statements that the cache let go are closed (COM_STMT_CLOSE has no reply, so it costs no wait);
 *   - SEND, PREPARED: a statement that the cache does not hold is prepared;
 *   - EXEC, EXECUTED, STORED: it runs with its parameters bound, and a result is stored whole by the library;
 *   - ROWS: each call turns up to the caps of rows and bytes into Agentica values;
 *   - MORE: the results after the first (a CALL) are read and dropped;
 *   - TEXT: a statement that the server does not prepare (error 1295) and has no parameters runs as text.
 * The values are read with the buffer types of the FFI adapter, so the library converts them the same way.
 *
 * The non-blocking calls of the library run on a stack of their own (a coroutine). The collector of the VM stops a
 * thread with a signal and scans its stack from where the thread is, which on that stack is the wrong memory; blocking
 * the signals instead can hang every thread (the library may wait on a lock, of malloc say, that a thread the
 * collector already stopped holds). The safe way is to run each such call as blocked for the collector
 * (GC_do_blocking), which the native API gives from version 1.3 as an_blocking (agentica-lang/agentica#1193). Every
 * `_start` and `_cont` goes through `on_library_stack`, and until it runs them under an_blocking, `connect` refuses
 * (STACK_SWITCH_SAFE) and the adapter runs the FFI driver. The driver opens libmariadb.so.3, a Linux name: elsewhere
 * `connect` fails the same way.
 *
 * Calls on one connection are made one at a time: the adapter holds a Native.Mutex of the connection for the whole
 * query, and `enter` below only refuses a call that would break that rule. A task cancelled in the middle of a query
 * leaves it on the connection (`inflight`); the next query reads it to its end first (`drain`), after a KILL QUERY
 * sent on a connection of its own (CANCEL, a compute call with timeouts). The free function of the connection never
 * waits: with a query left on it, it shuts the socket down before `mysql_close`, whose goodbye then fails at once.
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
#if defined(__linux__)
#include <poll.h>
#include <sys/socket.h>
#endif

#include <errno.h>
#include <inttypes.h>
#include <limits.h>
#include <math.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "agentica_native.h"

/* The C API of MariaDB Connector/C 3.x (mysql.h, mariadb_com.h, mariadb_stmt.h). */
typedef struct st_mysql MYSQL;
typedef struct st_mysql_stmt MYSQL_STMT;
typedef struct st_mysql_res MYSQL_RES;
typedef char **MYSQL_ROW;
typedef char my_bool;

/* MYSQL_BIND, in the order of mariadb_stmt.h; the library's own pointers are void pointers here, of the same size. */
typedef struct {
  unsigned long *length;
  my_bool *is_null;
  void *buffer;
  my_bool *error;
  unsigned char *row_ptr;
  void *store_param_func;
  void *fetch_result;
  void *skip_result;
  unsigned long buffer_length;
  unsigned long offset;
  unsigned long length_value;
  unsigned int flags;
  unsigned int pack_length;
  int buffer_type;
  my_bool error_value;
  my_bool is_unsigned;
  my_bool long_data_used;
  my_bool is_null_value;
  void *extension;
} MYSQL_BIND;

/* MYSQL_FIELD, in the order of mariadb_com.h. */
typedef struct {
  char *name, *org_name, *table, *org_table, *db, *catalog, *def;
  unsigned long length;
  unsigned long max_length;
  unsigned int name_length, org_name_length, table_length, org_table_length, db_length, catalog_length, def_length;
  unsigned int flags;
  unsigned int decimals;
  unsigned int charsetnr;
  int type;
  void *extension;
} MYSQL_FIELD;

#if defined(__LP64__)
_Static_assert(sizeof(MYSQL_BIND) == 112 && sizeof(MYSQL_FIELD) == 128, "the layouts of Connector/C 3.x");
#endif

enum {
  /* enum mysql_option */
  OPT_CONNECT_TIMEOUT = 0,
  OPT_LOCAL_INFILE = 8,
  OPT_READ_TIMEOUT = 11,
  OPT_WRITE_TIMEOUT = 12,
  OPT_SSL_VERIFY_SERVER_CERT = 21,
  OPT_SSL_CA = 27,
  OPT_SSL_ENFORCE = 38,
  OPT_NONBLOCK = 6000,
  /* enum mariadb_value, and its bit SERVER_STATUS_IN_TRANS */
  INFO_SERVER_STATUS = 30,
  STATUS_IN_TRANS = 1,
  CLIENT_FOUND_ROWS = 2,
  ATTR_UPDATE_MAX_LENGTH = 0,
  EV_READ = 1,
  EV_WRITE = 2,
  EV_EXCEPT = 4,
  EV_TIMEOUT = 8,
  FETCH_NO_DATA = 100,
  FETCH_TRUNCATED = 101,
  UNSUPPORTED_PREPARE = 1295,
  NEW_METADATA = 2057,
  UNSIGNED_FLAG = 32,
  BINARY_CHARSET = 63,
};

/* enum_field_types */
enum {
  TYPE_TINY = 1,
  TYPE_SHORT = 2,
  TYPE_LONG = 3,
  TYPE_FLOAT = 4,
  TYPE_DOUBLE = 5,
  TYPE_NULL = 6,
  TYPE_LONGLONG = 8,
  TYPE_INT24 = 9,
  TYPE_YEAR = 13,
  TYPE_VARCHAR = 15,
  TYPE_BIT = 16,
  TYPE_JSON = 245,
  TYPE_TINY_BLOB = 249,
  TYPE_MEDIUM_BLOB = 250,
  TYPE_LONG_BLOB = 251,
  TYPE_BLOB = 252,
  TYPE_VAR_STRING = 253,
  TYPE_STRING = 254,
  TYPE_GEOMETRY = 255,
};

typedef struct {
  int (*library_init)(int, char **, char **);
  MYSQL *(*init)(MYSQL *);
  int (*options)(MYSQL *, int, const void *);
  MYSQL *(*real_connect)(MYSQL *, const char *, const char *, const char *, const char *, unsigned int, const char *,
                         unsigned long);
  int (*set_character_set)(MYSQL *, const char *);
  void (*close)(MYSQL *);
  unsigned int (*errno_of)(MYSQL *);
  const char *(*error)(MYSQL *);
  int (*get_socket)(MYSQL *);
  const char *(*get_server_info)(MYSQL *);
  unsigned long (*thread_id)(MYSQL *);
  unsigned int (*get_timeout_value_ms)(const MYSQL *);
  my_bool (*get_info)(MYSQL *, int, void *);
  int (*real_query)(MYSQL *, const char *, unsigned long);
  int (*real_query_start)(int *, MYSQL *, const char *, unsigned long);
  int (*real_query_cont)(int *, MYSQL *, int);
  int (*store_result_start)(MYSQL_RES **, MYSQL *);
  int (*store_result_cont)(MYSQL_RES **, MYSQL *, int);
  unsigned int (*field_count)(MYSQL *);
  unsigned long long (*affected_rows)(MYSQL *);
  MYSQL_ROW (*fetch_row)(MYSQL_RES *);
  unsigned long *(*fetch_lengths)(MYSQL_RES *);
  my_bool (*more_results)(MYSQL *);
  int (*next_result_start)(int *, MYSQL *);
  int (*next_result_cont)(int *, MYSQL *, int);
  void (*free_result)(MYSQL_RES *);
  unsigned int (*num_fields)(MYSQL_RES *);
  MYSQL_FIELD *(*fetch_field_direct)(MYSQL_RES *, unsigned int);
  MYSQL_STMT *(*stmt_init)(MYSQL *);
  int (*stmt_prepare_start)(int *, MYSQL_STMT *, const char *, unsigned long);
  int (*stmt_prepare_cont)(int *, MYSQL_STMT *, int);
  unsigned long (*stmt_param_count)(MYSQL_STMT *);
  my_bool (*stmt_bind_param)(MYSQL_STMT *, MYSQL_BIND *);
  int (*stmt_execute_start)(int *, MYSQL_STMT *);
  int (*stmt_execute_cont)(int *, MYSQL_STMT *, int);
  my_bool (*stmt_attr_set)(MYSQL_STMT *, int, const void *);
  int (*stmt_store_result_start)(int *, MYSQL_STMT *);
  int (*stmt_store_result_cont)(int *, MYSQL_STMT *, int);
  unsigned int (*stmt_field_count)(MYSQL_STMT *);
  unsigned long long (*stmt_affected_rows)(MYSQL_STMT *);
  MYSQL_RES *(*stmt_result_metadata)(MYSQL_STMT *);
  my_bool (*stmt_bind_result)(MYSQL_STMT *, MYSQL_BIND *);
  int (*stmt_fetch)(MYSQL_STMT *);
  unsigned int (*stmt_errno)(MYSQL_STMT *);
  const char *(*stmt_error)(MYSQL_STMT *);
  my_bool (*stmt_free_result)(MYSQL_STMT *);
  int (*stmt_free_result_start)(my_bool *, MYSQL_STMT *);
  int (*stmt_free_result_cont)(my_bool *, MYSQL_STMT *, int);
  my_bool (*stmt_more_results)(MYSQL_STMT *);
  int (*stmt_next_result_start)(int *, MYSQL_STMT *);
  int (*stmt_next_result_cont)(int *, MYSQL_STMT *, int);
  my_bool (*stmt_close)(MYSQL_STMT *);
  int (*stmt_close_start)(my_bool *, MYSQL_STMT *);
  int (*stmt_close_cont)(my_bool *, MYSQL_STMT *, int);
} my_api;

static my_api my;

#define SYM(NAME, FIELD) {NAME, offsetof(my_api, FIELD)}
static const struct {
  const char *name;
  size_t offset;
} SYMBOLS[] = {
  SYM("mysql_server_init", library_init),
  SYM("mysql_init", init),
  SYM("mysql_options", options),
  SYM("mysql_real_connect", real_connect),
  SYM("mysql_set_character_set", set_character_set),
  SYM("mysql_close", close),
  SYM("mysql_errno", errno_of),
  SYM("mysql_error", error),
  SYM("mysql_get_socket", get_socket),
  SYM("mysql_get_server_info", get_server_info),
  SYM("mysql_thread_id", thread_id),
  SYM("mysql_get_timeout_value_ms", get_timeout_value_ms),
  SYM("mariadb_get_info", get_info),
  SYM("mysql_real_query", real_query),
  SYM("mysql_real_query_start", real_query_start),
  SYM("mysql_real_query_cont", real_query_cont),
  SYM("mysql_store_result_start", store_result_start),
  SYM("mysql_store_result_cont", store_result_cont),
  SYM("mysql_field_count", field_count),
  SYM("mysql_affected_rows", affected_rows),
  SYM("mysql_fetch_row", fetch_row),
  SYM("mysql_fetch_lengths", fetch_lengths),
  SYM("mysql_more_results", more_results),
  SYM("mysql_next_result_start", next_result_start),
  SYM("mysql_next_result_cont", next_result_cont),
  SYM("mysql_free_result", free_result),
  SYM("mysql_num_fields", num_fields),
  SYM("mysql_fetch_field_direct", fetch_field_direct),
  SYM("mysql_stmt_init", stmt_init),
  SYM("mysql_stmt_prepare_start", stmt_prepare_start),
  SYM("mysql_stmt_prepare_cont", stmt_prepare_cont),
  SYM("mysql_stmt_param_count", stmt_param_count),
  SYM("mysql_stmt_bind_param", stmt_bind_param),
  SYM("mysql_stmt_execute_start", stmt_execute_start),
  SYM("mysql_stmt_execute_cont", stmt_execute_cont),
  SYM("mysql_stmt_attr_set", stmt_attr_set),
  SYM("mysql_stmt_store_result_start", stmt_store_result_start),
  SYM("mysql_stmt_store_result_cont", stmt_store_result_cont),
  SYM("mysql_stmt_field_count", stmt_field_count),
  SYM("mysql_stmt_affected_rows", stmt_affected_rows),
  SYM("mysql_stmt_result_metadata", stmt_result_metadata),
  SYM("mysql_stmt_bind_result", stmt_bind_result),
  SYM("mysql_stmt_fetch", stmt_fetch),
  SYM("mysql_stmt_errno", stmt_errno),
  SYM("mysql_stmt_error", stmt_error),
  SYM("mysql_stmt_free_result", stmt_free_result),
  SYM("mysql_stmt_free_result_start", stmt_free_result_start),
  SYM("mysql_stmt_free_result_cont", stmt_free_result_cont),
  SYM("mysql_stmt_more_results", stmt_more_results),
  SYM("mysql_stmt_next_result_start", stmt_next_result_start),
  SYM("mysql_stmt_next_result_cont", stmt_next_result_cont),
  SYM("mysql_stmt_close", stmt_close),
  SYM("mysql_stmt_close_start", stmt_close_start),
  SYM("mysql_stmt_close_cont", stmt_close_cont),
};
#define SYMBOL_COUNT (sizeof SYMBOLS / sizeof SYMBOLS[0])
/* load_symbols fills `my` field by field: SYMBOLS must name every field, and each field is a function pointer. */
_Static_assert(sizeof(my_api) == SYMBOL_COUNT * sizeof(void (*)(void)), "SYMBOLS names every field of my_api");

/* ---- The system: the library loader, a lock, a clock, the socket. ---- */

/* Why the library did not open, written once under load_once (Linux); empty when it opened. */
static char load_message[512];

#if defined(_WIN32)
typedef SRWLOCK lock_t;
static void lock_init(lock_t *l) { InitializeSRWLock(l); }
static bool lock_try(lock_t *l) { return TryAcquireSRWLockExclusive(l) != 0; }
static void lock_drop(lock_t *l) { ReleaseSRWLockExclusive(l); }
static void lock_destroy(lock_t *l) { (void)l; }
static uint64_t now_ms(void) { return (uint64_t)GetTickCount64(); }
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
static uint64_t now_ms(void) {
  struct timespec t;
  if (clock_gettime(CLOCK_MONOTONIC, &t) != 0) return 0;
  return (uint64_t)t.tv_sec * 1000u + (uint64_t)t.tv_nsec / 1000000u;
}
#endif

#if defined(__linux__)
static void *library;
static pthread_once_t load_once = PTHREAD_ONCE_INIT;

/* Opens the library and fills `my`, once per run; load_message says why when it failed. dlopen never searches the
   working directory for a bare name on Linux. */
static void load_symbols(void) {
  library = dlopen("libmariadb.so.3", RTLD_NOW | RTLD_LOCAL);
  if (!library) {
    const char *why = dlerror();
    snprintf(load_message, sizeof load_message, "%s", why ? why : "libmariadb.so.3");
    return;
  }
  for (size_t i = 0; i < SYMBOL_COUNT; i++) {
    void *p = dlsym(library, SYMBOLS[i].name);
    if (!p) {
      snprintf(load_message, sizeof load_message, "the library has no %s", SYMBOLS[i].name);
      return;
    }
    /* POSIX gives a function's address as an object pointer; every field is a function pointer. */
    memcpy((char *)&my + SYMBOLS[i].offset, &p, sizeof p);
  }
  /* mysql_init sets the library up on its first call, which is not safe for two threads at once. */
  if (my.library_init(0, NULL, NULL) != 0) snprintf(load_message, sizeof load_message, "mysql_server_init failed");
}

/* NULL once the library is open, else why it is not. */
static const char *library_error(void) {
  if (pthread_once(&load_once, load_symbols) != 0) abort();
  return load_message[0] ? load_message : NULL;
}

/* The events of WAIT that the socket has now, without waiting: an error or a hang-up counts as every one of them, so
   that the library meets it. */
static int ready_events(int fd, int wait) {
  if (fd < 0) return wait & (EV_READ | EV_WRITE | EV_EXCEPT);
  struct pollfd p = {fd, 0, 0};
  if (wait & EV_READ) p.events |= POLLIN;
  if (wait & EV_WRITE) p.events |= POLLOUT;
  if (wait & EV_EXCEPT) p.events |= POLLPRI;
  int n;
  do {
    n = poll(&p, 1, 0);
  } while (n < 0 && errno == EINTR);
  if (n <= 0) return 0;
  if (p.revents & (POLLERR | POLLHUP | POLLNVAL)) return wait & (EV_READ | EV_WRITE | EV_EXCEPT);
  return ((p.revents & POLLIN) ? EV_READ : 0) | ((p.revents & POLLOUT) ? EV_WRITE : 0) |
         ((p.revents & POLLPRI) ? EV_EXCEPT : 0);
}

static void shut_socket(int fd) {
  if (fd >= 0) (void)shutdown(fd, SHUT_RDWR);
}
#else
/* Elsewhere the library has another name, and the driver is not tried (see the top). */
static const char *library_error(void) { return "the native MySQL driver runs on Linux only"; }
static int ready_events(int fd, int wait) {
  (void)fd;
  return wait;
}
static void shut_socket(int fd) { (void)fd; }
#endif

/* ---- Connections and their statement cache. ---- */

/* A cached statement: the sql that the adapter got, the prepared statement, the count of its parameters, and whether
   `execute` counts the rows it changed. */
typedef struct {
  char *sql;
  size_t len;
  uint64_t hash;
  MYSQL_STMT *stmt;
  int count;
  bool counts;
  uint64_t used;
} entry;

enum { OP_NONE, OP_PREPARE, OP_EXECUTE, OP_STORE, OP_NEXT, OP_CLOSE, OP_FREE, OP_QUERY, OP_TEXT_STORE, OP_TEXT_NEXT };

enum {
  P_START,
  P_CLOSE,
  P_SEND,
  P_PREPARED,
  P_EXEC,
  P_EXECUTED,
  P_FREED,
  P_STORED,
  P_ROWS,
  P_MORE,
  P_NEXTED,
  P_TEXT,
  P_TEXT_SENT,
  P_TEXT_STORED,
  P_TEXT_MORE,
  P_TEXT_NEXTED,
  P_FINISH,
  P_DONE,
};

/* What is read from a column (as the FFI adapter reads it), which sets the buffer that is bound to it. */
enum { K_INT, K_FLOAT, K_TEXT, K_BLOB, K_UNSIGNED };

/* The bound parameters: BINDS point into BUFFER. */
typedef struct {
  int count;
  MYSQL_BIND *binds;
  char *buffer;
} params;

/* The columns of a result and the cells of its current row. A prepared statement binds a buffer to each column
   (DATA, BINDS); a text result points CELLS at the row of the library. META holds the names. */
typedef struct {
  int n;
  bool text, wide;
  MYSQL_RES *meta;
  int *kinds;
  unsigned long *sizes;
  char **cells;
  unsigned long *lengths;
  my_bool *nulls;
  MYSQL_BIND *binds;
  char *data;
} result;

/* The query that runs on a connection, from `start` to its end. OP is the call of the library that waits for the
   socket (WAIT, and DEADLINE when the library has a timeout), and PHASE what comes after it. STMT is the cache's
   (`slot`) or the query's own (`owned`, closed at its end). A query with DISCARD is one that a cancelled task left: it
   is read to its end and sends nothing new. SPOILED marks a statement that failed after its execute: the library may
   then read the socket for rows that never come at its next execute, so the cache lets it go at the end of the query.
   RETRIED: the statement ran again once after its table changed. */
typedef struct {
  int phase, op, wait;
  uint64_t deadline;
  bool keep, cache, flush, counts, owned, text, extra, discard, killed, dirty, big, pending, spoiled, retried;
  int ret, closes;
  my_bool closed, freed;
  MYSQL_RES *res;
  MYSQL_STMT *stmt, *closing;
  int slot;
  char *sql;
  size_t len;
  uint64_t hash;
  params bound;
  result out;
  int64_t changes;
  char failure[1024];
} query;

/* What `cancel` needs to reach the server again. */
typedef struct {
  char *host, *user, *password, *ca;
  int port, tls;
} login;

/* The C state of a connection. `lock` is held by each call for its whole length (one call at a time: see the top). */
typedef struct {
  lock_t lock;
  MYSQL *my;
  entry *entries;
  int capacity;
  MYSQL_STMT **closing;
  int closing_size, closing_capacity;
  uint64_t tick, hits, misses, evictions;
  bool inflight;
  login login;
  query q;
} conn;

typedef struct {
  conn *c;
} conn_state;

/* The largest statement cache, as the url's statement_cache allows (mysql/url.agc). */
#define MAX_CACHE 10000
/* The bytes that a value costs besides its text or bytes, for the byte cap of a batch. */
#define VALUE_COST 16
/* The most that a short call copies: bigger parameters, or a bigger row, go to the compute pool. A short call also
   turns at most QUICK_ROWS rows and QUICK_BYTES bytes into values, whatever batch_rows and batch_bytes say. */
#define QUICK_BYTES 262144
#define QUICK_ROWS 1000
/* A type that is not a string is read as text into a buffer of its display width, at most this many bytes, plus some
   room (a signed decimal, or a datetime with microseconds), as in the FFI adapter. */
#define TEXT_WIDTH_LIMIT 256
#define TEXT_ROOM 32
/* The most statements that one query closes before it runs: after a schema change lets a big cache go, the closes
   spread over the next queries instead of holding one short call. */
#define CLOSE_BATCH 32
/* The seconds that the connection of `cancel` may take to connect, and to send its KILL QUERY and read the reply. */
#define CANCEL_WAIT_S 5
/* Why `connect` refuses (see the top); the adapter says the same (mysql/native.agc). */
#define NEEDS_BLOCKING \
  "the native MySQL driver needs an_blocking of Agentica's native API 1.3 (agentica-lang/agentica#1193)"

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

/* Keeps STMT for the next CLOSE. Out of memory, it is closed at once with the blocking call, which only sends the
   few bytes of COM_STMT_CLOSE (no reply) on a connection that waits for no answer here, and frees the statement. */
static void close_later(conn *c, MYSQL_STMT *stmt) {
  if (c->closing_size == c->closing_capacity) {
    int grown = c->closing_capacity ? c->closing_capacity * 2 : 16;
    void *more = grown > c->closing_capacity ? realloc(c->closing, (size_t)grown * sizeof *c->closing) : NULL;
    if (!more) {
      (void)my.stmt_close(stmt);
      return;
    }
    c->closing = more;
    c->closing_capacity = grown;
  }
  c->closing[c->closing_size++] = stmt;
}

static void forget(conn *c, int slot) {
  entry *e = &c->entries[slot];
  close_later(c, e->stmt);
  free(e->sql);
  *e = (entry){0};
}

/* Caches the statement of the query, in a free slot or the one used least long ago (evicted). False when there was no
   memory for it: the query keeps the statement as its own. */
static bool insert(conn *c, query *q, int count) {
  int slot = -1;
  for (int i = 0; i < c->capacity && slot < 0; i++)
    if (!c->entries[i].sql) slot = i;
  if (slot < 0) {
    slot = 0;
    for (int i = 1; i < c->capacity; i++)
      if (c->entries[i].used < c->entries[slot].used) slot = i;
    forget(c, slot);
    c->evictions++;
  }
  char *copy = malloc(q->len ? q->len : 1);
  if (!copy) return false;
  memcpy(copy, q->sql, q->len);
  c->entries[slot] = (entry){copy, q->len, q->hash, q->stmt, count, q->counts, ++c->tick};
  q->slot = slot;
  return true;
}

static void clear_params(params *p) {
  free(p->binds);
  free(p->buffer);
  *p = (params){0};
}

/* Frees the columns; a stored result of a statement goes with mysql_stmt_free_result, which never reads the socket
   once the result is stored. */
static void clear_result(result *r) {
  if (r->meta) my.free_result(r->meta);
  free(r->kinds);
  free(r->sizes);
  free(r->cells);
  free(r->lengths);
  free(r->nulls);
  free(r->binds);
  free(r->data);
  *r = (result){0};
}

static void query_reset(query *q) {
  clear_result(&q->out);
  if (q->res) my.free_result(q->res);
  clear_params(&q->bound);
  free(q->sql);
  *q = (query){0};
  q->slot = -1;
  q->phase = P_DONE;
}

/* Ends the query of the connection: its own statement, or a cached one that is spoiled, goes to the next CLOSE. */
static void end_query(conn *c, query *q) {
  if (q->owned && q->stmt) close_later(c, q->stmt);
  if (q->spoiled && q->slot >= 0 && c->entries[q->slot].stmt == q->stmt) forget(c, q->slot);
  query_reset(q);
  c->inflight = false;
}

/* The password is wiped before its memory goes (volatile, so the stores are not dropped as dead). */
static void free_login(login *l) {
  if (l->password)
    for (volatile char *p = l->password; *p; p++) *p = 0;
  free(l->host);
  free(l->user);
  free(l->password);
  free(l->ca);
  *l = (login){0};
}

static void conn_free(void *state) {
  conn *c = ((conn_state *)state)->c;
  if (!c) return;
  /* The results of the query go while the connection they came from is still there. */
  MYSQL_STMT *own = c->q.owned ? c->q.stmt : NULL;
  query_reset(&c->q);
  /* A query left on the connection may be in the middle of a packet: with the socket shut down, the goodbye of
     mysql_close fails at once instead of waiting. An idle socket takes the goodbye without waiting. */
  if (c->inflight) shut_socket(my.get_socket(c->my));
  /* mysql_close detaches the statements, so their mysql_stmt_close below only frees memory. A statement whose close
     waits to write (the query's `closing`) is let go: the library already took it off the connection, and only its
     own `_cont` can end it, which would switch stacks here, in a free function that has no env for an_blocking. It
     is one statement's client memory, once per connection freed in that state. */
  my.close(c->my);
  for (int i = 0; i < c->capacity; i++) {
    if (c->entries[i].stmt) (void)my.stmt_close(c->entries[i].stmt);
    free(c->entries[i].sql);
  }
  for (int i = 0; i < c->closing_size; i++) (void)my.stmt_close(c->closing[i]);
  if (own) (void)my.stmt_close(own);
  free(c->entries);
  free(c->closing);
  free_login(&c->login);
  lock_destroy(&c->lock);
  free(c);
}

/* ---- Terms. ---- */

enum { VALUE, PLAN, OPTIONS, STEP, CACHE_STATS, LOGIN };
enum { V_NULL, V_INT, V_FLOAT, V_TEXT, V_BLOB, V_BOOL };
enum { CONN };
enum { PL_KNOWN, PL_CACHE, PL_FLUSH, PL_COUNTS, PL_KEEP, PLAN_FIELDS };
enum { O_ROWS, O_BYTES };
enum { L_HOST, L_PORT, L_USER, L_PASSWORD, L_DATABASE, L_TIMEOUT, L_TIMEOUT_MS, L_TLS, L_CA, LOGIN_FIELDS };
enum { TLS_DEFAULT, TLS_REQUIRED, TLS_VERIFY };
/* What `Step.state` asks of the adapter. */
enum { S_READ = 1, S_WRITE, S_ROWS, S_DONE, S_FAILED, S_PLAN, S_CANCEL, S_BIG_START, S_BIG, S_LEFT };

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

/* A String of the bytes, each byte that is not UTF-8 replaced by U+FFFD (a column in another character set than the
   connection's can send any byte). */
static an_term text(an_env *env, const char *data, size_t len) {
  const unsigned char *s = (const unsigned char *)(data ? data : "");
  size_t i = 0, step;
  while (i < len && (step = utf8_char(s + i, len - i)) != 0) i += step;
  if (i == len) return an_string(env, (const char *)s, len);
  if (len > (SIZE_MAX - 1) / 3) return an_raise(env, "mysql: a text is too long");
  char *out = malloc(len * 3 + 1);
  if (!out) return an_raise(env, "mysql: out of memory");
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

/* `mysql error <code>: <message>`, or `mysql error: <message>` without a code, the message without the white space
   around it (as the FFI adapter words it). */
static void failure_of(char *out, size_t size, unsigned code, const char *message) {
  const char *m = message ? message : "";
  while (*m == ' ' || (*m >= '\t' && *m <= '\r')) m++;
  size_t n = strlen(m);
  while (n > 0 && (m[n - 1] == ' ' || (m[n - 1] >= '\t' && m[n - 1] <= '\r'))) n--;
  int shown = (int)(n < 900 ? n : 900);
  if (code == 0)
    snprintf(out, size, "mysql error: %.*s", shown, m);
  else
    snprintf(out, size, "mysql error %u: %.*s", code, shown, m);
}

static void fail_stmt(query *q) {
  if (!q->failure[0]) failure_of(q->failure, sizeof q->failure, my.stmt_errno(q->stmt), my.stmt_error(q->stmt));
}

static void fail_conn(query *q, conn *c) {
  if (!q->failure[0]) failure_of(q->failure, sizeof q->failure, my.errno_of(c->my), my.error(c->my));
}

static void fail_text(query *q, const char *message) {
  if (!q->failure[0]) snprintf(q->failure, sizeof q->failure, "mysql error: %s", message);
}

static an_term make_step(an_env *env, conn *c, int state, const char *failure, an_term rows, int64_t changes) {
  an_term fields[5] = {an_int(env, state), an_int(env, my.get_socket(c->my)), text0(env, failure), rows,
                       an_int(env, changes)};
  return an_struct(env, STEP, fields);
}

static an_term no_rows(an_env *env) { return an_list(env, NULL, 0); }

static an_term step_state(an_env *env, conn *c, int state) { return make_step(env, c, state, "", no_rows(env), 0); }

/* ---- Binding. ---- */

/* Puts PARAMS (a List[Value]) into binds as the FFI adapter binds them: an Int or a Bool as a longlong, a Float as a
   double, a Text as a var string, a Blob as a blob, a Null as NULL. False with the failure in OUT, or with *OVER when
   they take more than LIMIT bytes. */
static bool bind_all(an_env *env, an_term list, size_t limit, params *p, bool *over, char *out, size_t size) {
  an_list_cursor walk;
  size_t n;
  an_term item;
  if (!an_list_cursor_begin(env, list, &walk, &n)) {
    snprintf(out, size, "mysql error: the parameters are not a list");
    return false;
  }
  if (n > 65535) {
    /* The most that the protocol carries. */
    snprintf(out, size, "mysql error: more than 65535 parameters");
    return false;
  }
  /* A first walk sizes the buffer: a number takes 8 bytes, a text or a blob its bytes. */
  size_t total = 0;
  while (an_list_next(env, &walk, &item)) {
    uint32_t variant;
    an_term payload;
    const char *data;
    const uint8_t *bytes;
    size_t len = 0;
    if (!an_get_variant(env, item, VALUE, &variant)) variant = UINT32_MAX;
    bool sized = (variant == V_TEXT && an_get_payload(env, item, VALUE, 0, &payload) &&
                  an_get_string(env, payload, &data, &len)) ||
                 (variant == V_BLOB && an_get_payload(env, item, VALUE, 0, &payload) &&
                  an_get_bytes(env, payload, &bytes, &len));
    if (!sized) len = 8;
    if (len > SIZE_MAX / 2 - total) {
      snprintf(out, size, "mysql error: a parameter is too long");
      return false;
    }
    total += len;
  }
  if (total > limit) {
    *over = true;
    return false;
  }
  p->count = (int)n;
  p->buffer = malloc(total ? total : 1);
  p->binds = calloc(n ? n : 1, sizeof *p->binds);
  if (!p->buffer || !p->binds) {
    clear_params(p);
    snprintf(out, size, "mysql error: out of memory");
    return false;
  }
  char *at = p->buffer;
  (void)an_list_cursor_begin(env, list, &walk, &n);
  for (size_t i = 0; an_list_next(env, &walk, &item); i++) {
    MYSQL_BIND *b = &p->binds[i];
    uint32_t variant;
    an_term payload;
    int64_t whole;
    double x;
    bool flag = false;
    const char *data;
    const uint8_t *bytes;
    size_t len;
    bool good = false;
    if (!an_get_variant(env, item, VALUE, &variant)) variant = UINT32_MAX;
    if (variant == V_NULL) {
      b->buffer_type = TYPE_NULL;
      continue;
    }
    if (variant != UINT32_MAX && an_get_payload(env, item, VALUE, 0, &payload)) {
      bool is_int = variant == V_INT && an_get_int(env, payload, &whole);
      if (is_int || (variant == V_BOOL && an_get_bool(env, payload, &flag))) {
        if (variant == V_BOOL) whole = flag ? 1 : 0;
        memcpy(at, &whole, 8);
        *b = (MYSQL_BIND){.buffer = at, .buffer_length = 8, .buffer_type = TYPE_LONGLONG};
        at += 8;
        good = true;
      } else if (variant == V_FLOAT && an_get_float(env, payload, &x)) {
        if (!isfinite(x)) {
          clear_params(p);
          snprintf(out, size, "mysql error: a float parameter is NaN or infinite, which MySQL cannot store");
          return false;
        }
        memcpy(at, &x, 8);
        *b = (MYSQL_BIND){.buffer = at, .buffer_length = 8, .buffer_type = TYPE_DOUBLE};
        at += 8;
        good = true;
      } else if (variant == V_TEXT && an_get_string(env, payload, &data, &len)) {
        if (len > 0 && memchr(data, '\0', len)) {
          clear_params(p);
          snprintf(out, size, "mysql error: a text parameter contains a NUL character");
          return false;
        }
        if (len > 0) memcpy(at, data, len);
        *b = (MYSQL_BIND){.buffer = at, .buffer_length = (unsigned long)len, .buffer_type = TYPE_VAR_STRING};
        at += len;
        good = true;
      } else if (variant == V_BLOB && an_get_bytes(env, payload, &bytes, &len)) {
        if (len > 0) memcpy(at, bytes, len);
        *b = (MYSQL_BIND){.buffer = at, .buffer_length = (unsigned long)len, .buffer_type = TYPE_BLOB};
        at += len;
        good = true;
      }
    }
    if (!good) {
      clear_params(p);
      snprintf(out, size, "mysql error: parameter %zu is not a Value", i + 1);
      return false;
    }
  }
  return true;
}

/* ---- Reading. ---- */

static bool int_type(int t) {
  return t == TYPE_TINY || t == TYPE_SHORT || t == TYPE_LONG || t == TYPE_NULL || t == TYPE_LONGLONG ||
         t == TYPE_INT24 || t == TYPE_YEAR;
}

/* Fields that hold text, or bytes when their character set is binary. */
static bool string_type(int t) {
  return t == TYPE_VARCHAR || t == TYPE_BIT || t == TYPE_JSON || (t >= TYPE_TINY_BLOB && t <= TYPE_GEOMETRY);
}

/* What to read from a column and how big a buffer holds its longest value: the column_of of the FFI adapter. */
static int kind_of(const MYSQL_FIELD *f, unsigned long *size) {
  unsigned long longest = f->max_length;
  if (f->type == TYPE_LONGLONG && (f->flags & UNSIGNED_FLAG)) {
    *size = TEXT_ROOM;
    return K_UNSIGNED;
  }
  if (int_type(f->type)) {
    *size = 8;
    return K_INT;
  }
  if (f->type == TYPE_FLOAT || f->type == TYPE_DOUBLE) {
    *size = 8;
    return K_FLOAT;
  }
  *size = longest;
  /* MySQL gives a json column the binary character set, but it holds text. */
  if (f->type == TYPE_JSON) return K_TEXT;
  if (string_type(f->type)) return f->charsetnr == BINARY_CHARSET ? K_BLOB : K_TEXT;
  unsigned long width = f->length < TEXT_WIDTH_LIMIT ? f->length : TEXT_WIDTH_LIMIT;
  *size = (longest > width ? longest : width) + TEXT_ROOM;
  return K_TEXT;
}

static int buffer_type_of(int kind) {
  return kind == K_INT ? TYPE_LONGLONG : kind == K_FLOAT ? TYPE_DOUBLE : kind == K_BLOB ? TYPE_BLOB : TYPE_STRING;
}

static int compare_names(const void *a, const void *b) {
  return strcmp(*(const char *const *)a, *(const char *const *)b);
}

/* False with the failure in Q when two columns of META have one name. A narrow result compares each pair; a wide one
   (up to 4096 columns) sorts the names, so that a short call stays short. */
static bool check_names(query *q, MYSQL_RES *meta, int n) {
  const char *twice = NULL;
  const char **names = malloc((size_t)(n ? n : 1) * sizeof *names);
  if (!names) {
    fail_text(q, "out of memory");
    return false;
  }
  for (int i = 0; i < n; i++) names[i] = my.fetch_field_direct(meta, (unsigned)i)->name;
  if (n <= 32) {
    for (int i = 0; i < n && !twice; i++)
      for (int j = i + 1; j < n && !twice; j++)
        if (strcmp(names[i], names[j]) == 0) twice = names[i];
  } else {
    qsort(names, (size_t)n, sizeof *names, compare_names);
    for (int i = 1; i < n && !twice; i++)
      if (strcmp(names[i - 1], names[i]) == 0) twice = names[i];
  }
  if (twice)
    snprintf(q->failure, sizeof q->failure, "mysql error: the result has the column %.900s twice, alias one of them",
             twice);
  free(names);
  return twice == NULL;
}

/* Reads the columns of META, the result of the statement (TEXT false: META is its metadata, and a buffer is bound to
   each column) or of a text query. False with the failure in Q. */
static bool describe(query *q, MYSQL_RES *meta, bool text_result) {
  result *r = &q->out;
  int n = (int)my.num_fields(meta);
  r->meta = text_result ? NULL : meta;
  r->text = text_result;
  r->n = n;
  if (!check_names(q, meta, n)) return false;
  size_t count = (size_t)(n ? n : 1);
  r->kinds = calloc(count, sizeof *r->kinds);
  r->sizes = calloc(count, sizeof *r->sizes);
  r->cells = calloc(count, sizeof *r->cells);
  r->lengths = calloc(count, sizeof *r->lengths);
  r->nulls = calloc(count, sizeof *r->nulls);
  if (!r->kinds || !r->sizes || !r->cells || !r->lengths || !r->nulls) {
    fail_text(q, "out of memory");
    return false;
  }
  size_t total = 0;
  for (int i = 0; i < n; i++) {
    r->kinds[i] = kind_of(my.fetch_field_direct(meta, (unsigned)i), &r->sizes[i]);
    size_t room = r->sizes[i] ? r->sizes[i] : 1;
    if (room > SIZE_MAX / 2 - total) {
      fail_text(q, "a result is too wide");
      return false;
    }
    total += room;
  }
  if (text_result) return true;
  /* A row that may be bigger than a short call copies is read on the compute pool: mysql_stmt_fetch copies it. */
  r->wide = total > QUICK_BYTES;
  r->binds = calloc(count, sizeof *r->binds);
  r->data = malloc(total ? total : 1);
  if (!r->binds || !r->data) {
    fail_text(q, "out of memory");
    return false;
  }
  size_t at = 0;
  for (int i = 0; i < n; i++) {
    r->cells[i] = r->data + at;
    r->binds[i] = (MYSQL_BIND){.length = &r->lengths[i],
                               .is_null = &r->nulls[i],
                               .buffer = r->cells[i],
                               .buffer_length = r->sizes[i],
                               .buffer_type = buffer_type_of(r->kinds[i])};
    at += r->sizes[i] ? r->sizes[i] : 1;
  }
  if (my.stmt_bind_result(q->stmt, r->binds)) {
    fail_stmt(q);
    return false;
  }
  return true;
}

/* Moves to the next row: 1 when there is one (its cells set), 0 at the end, -1 on a failure (in Q). */
static int next_row(query *q) {
  result *r = &q->out;
  if (r->text) {
    MYSQL_ROW row = my.fetch_row(q->res);
    if (!row) return 0;
    unsigned long *lengths = my.fetch_lengths(q->res);
    for (int i = 0; i < r->n; i++) {
      r->cells[i] = row[i];
      r->lengths[i] = lengths ? lengths[i] : 0;
      r->nulls[i] = row[i] == NULL;
    }
    return 1;
  }
  int got = my.stmt_fetch(q->stmt);
  if (got == FETCH_NO_DATA) return 0;
  if (got == 1) {
    fail_stmt(q);
    return -1;
  }
  bool truncated = got == FETCH_TRUNCATED;
  for (int i = 0; i < r->n && !truncated; i++) truncated = !r->nulls[i] && r->lengths[i] > r->sizes[i];
  if (truncated) {
    fail_text(q, "a value is longer than its buffer");
    return -1;
  }
  return 1;
}

/* The bytes of the current row as the byte cap counts them. */
static int64_t row_size(const result *r) {
  int64_t size = 0;
  for (int i = 0; i < r->n; i++) size += VALUE_COST + (int64_t)(r->nulls[i] ? 0 : r->lengths[i]);
  return size;
}

/* An Int when the digits fit one, else the digits as text (a bigint unsigned past the range of an Int). */
static an_term whole_value(an_env *env, const char *cell, size_t len) {
  char digits[32];
  an_term payload;
  if (len > 0 && len < sizeof digits) {
    memcpy(digits, cell, len);
    digits[len] = '\0';
    char *end;
    errno = 0;
    long long n = strtoll(digits, &end, 10);
    if (errno == 0 && *end == '\0' && (digits[0] == '-' || (digits[0] >= '0' && digits[0] <= '9'))) {
      payload = an_int(env, n);
      return an_enum(env, VALUE, V_INT, &payload);
    }
  }
  payload = text(env, cell, len);
  return an_enum(env, VALUE, V_TEXT, &payload);
}

/* The end of a run of digits from AT, or AT when there is none. */
static size_t digits_end(const char *cell, size_t len, size_t at) {
  while (at < len && cell[at] >= '0' && cell[at] <= '9') at++;
  return at;
}

/* A float of the text protocol where String#to_f reads one (a sign, digits, then an optional fraction of digits and
   an optional exponent); anything else stays text. */
static an_term float_value(an_env *env, const char *cell, size_t len) {
  char digits[64];
  an_term payload;
  size_t i = len > 0 && (cell[0] == '-' || cell[0] == '+') ? 1 : 0;
  size_t end = digits_end(cell, len, i);
  bool good = end > i;
  if (good && end < len && cell[end] == '.') {
    i = end + 1;
    end = digits_end(cell, len, i);
    good = end > i;
  }
  if (good && end < len && (cell[end] == 'e' || cell[end] == 'E')) {
    i = end + 1 < len && (cell[end + 1] == '-' || cell[end + 1] == '+') ? end + 2 : end + 1;
    end = digits_end(cell, len, i);
    good = end > i;
  }
  if (good && end == len && len < sizeof digits) {
    memcpy(digits, cell, len);
    digits[len] = '\0';
    payload = an_float(env, strtod(digits, NULL));
    return an_enum(env, VALUE, V_FLOAT, &payload);
  }
  payload = text(env, cell, len);
  return an_enum(env, VALUE, V_TEXT, &payload);
}

/* The value of column COL of the current row; adds its size to *BYTES. */
static an_term read_value(an_env *env, const result *r, int col, int64_t *bytes) {
  *bytes += VALUE_COST;
  if (r->nulls[col]) return an_enum(env, VALUE, V_NULL, NULL);
  const char *cell = r->cells[col];
  size_t len = r->lengths[col];
  an_term payload;
  int kind = r->kinds[col];
  *bytes += (int64_t)len;
  if (kind == K_BLOB) {
    payload = an_bytes(env, cell, len);
    return an_enum(env, VALUE, V_BLOB, &payload);
  }
  if (r->text && (kind == K_INT || kind == K_UNSIGNED)) return whole_value(env, cell, len);
  if (r->text && kind == K_FLOAT) return float_value(env, cell, len);
  if (kind == K_INT) {
    int64_t n;
    memcpy(&n, cell, 8);
    payload = an_int(env, n);
    return an_enum(env, VALUE, V_INT, &payload);
  }
  if (kind == K_FLOAT) {
    /* The 8 bytes of a double as they are: the sign of a zero and the exact digits survive. */
    double x;
    memcpy(&x, cell, 8);
    payload = an_float(env, x);
    return an_enum(env, VALUE, V_FLOAT, &payload);
  }
  if (kind == K_UNSIGNED) return whole_value(env, cell, len);
  payload = text(env, cell, len);
  return an_enum(env, VALUE, V_TEXT, &payload);
}

/* The columns of a row with names made once per call. Terms live only in C locals (the collector scans the stack, not
   malloc memory), so they are arrays on the stack; a wider row makes its names again for each row. */
#define MAX_NAMES 64

static MYSQL_RES *names_of(const query *q) { return q->out.text ? q->res : q->out.meta; }

static an_term read_row(an_env *env, const query *q, const an_term *names, int64_t *bytes) {
  const result *r = &q->out;
  if (r->n <= MAX_NAMES) {
    an_term values[MAX_NAMES];
    for (int col = 0; col < r->n; col++) values[col] = read_value(env, r, col, bytes);
    return an_map_from(env, names, values, (size_t)r->n);
  }
  an_term map = an_map_from(env, NULL, NULL, 0);
  for (int col = 0; col < r->n; col++) {
    an_term name = text0(env, my.fetch_field_direct(names_of(q), (unsigned)col)->name);
    map = an_map_put(env, map, name, read_value(env, r, col, bytes));
  }
  return map;
}

/* ---- The calls of the library that wait. ---- */

/* What one call of the library needs: the query, its connection and the events (0 for the `_start`); WAIT is what
   the call gives back. It lives in C memory: no term and no memory of the collector is touched on the library's
   stack. */
typedef struct {
  conn *c;
  query *q;
  int events, wait;
} op_args;

/* Calls the `_start` (events 0) or the `_cont` of the operation of the query: the events it waits for, 0 once the
   operation is over. */
static void op_run(void *arg) {
  op_args *a = arg;
  conn *c = a->c;
  query *q = a->q;
  int events = a->events, wait = 0;
  switch (q->op) {
  case OP_PREPARE:
    wait = events ? my.stmt_prepare_cont(&q->ret, q->stmt, events)
                  : my.stmt_prepare_start(&q->ret, q->stmt, q->sql, (unsigned long)q->len);
    break;
  case OP_EXECUTE:
    wait = events ? my.stmt_execute_cont(&q->ret, q->stmt, events) : my.stmt_execute_start(&q->ret, q->stmt);
    break;
  case OP_STORE:
    wait = events ? my.stmt_store_result_cont(&q->ret, q->stmt, events) : my.stmt_store_result_start(&q->ret, q->stmt);
    break;
  case OP_NEXT:
    wait = events ? my.stmt_next_result_cont(&q->ret, q->stmt, events) : my.stmt_next_result_start(&q->ret, q->stmt);
    break;
  case OP_CLOSE:
    wait = events ? my.stmt_close_cont(&q->closed, q->closing, events) : my.stmt_close_start(&q->closed, q->closing);
    break;
  case OP_FREE:
    wait = events ? my.stmt_free_result_cont(&q->freed, q->stmt, events)
                  : my.stmt_free_result_start(&q->freed, q->stmt);
    break;
  case OP_QUERY:
    wait = events ? my.real_query_cont(&q->ret, c->my, events)
                  : my.real_query_start(&q->ret, c->my, q->sql, (unsigned long)q->len);
    break;
  case OP_TEXT_STORE:
    wait = events ? my.store_result_cont(&q->res, c->my, events) : my.store_result_start(&q->res, c->my);
    break;
  case OP_TEXT_NEXT:
    wait = events ? my.next_result_cont(&q->ret, c->my, events) : my.next_result_start(&q->ret, c->my);
    break;
  default:
    break;
  }
  a->wait = wait;
}

/* STACK_SWITCH_SAFE: whether `on_library_stack` keeps the collector off the library's stack. It is 0 until this
   module runs FN under an_blocking(env, fn, arg) of the native API 1.3 (agentica-lang/agentica#1193), which marks the
   thread as blocked for the collector while FN runs, so a stop of the world neither signals it nor scans that stack.
   That change is this function and the constant; the rest of the module already keeps FN off terms and GC memory.

   A `_cont` may run on another thread than its `_start` (a dirty call starts it, a scheduler goes on with it, or the
   task moves to another scheduler). Connector/C keeps the state of a suspended call in its async context, with no
   thread-local data, and its socket loops (pvio_socket_read and _write) ask for errno after every recv and send,
   also after the yield, in the builds that this driver was checked with (Debian's libmariadb3), so a resumed call
   reads the errno of the thread it runs on. */
#define STACK_SWITCH_SAFE 0
static void on_library_stack(an_env *env, void (*fn)(void *), void *arg) {
  (void)env;
  fn(arg);
}

static int op_call(an_env *env, conn *c, query *q, int events) {
  op_args a = {c, q, events, 0};
  on_library_stack(env, op_run, &a);
  return a.wait;
}

static int op_settle(conn *c, query *q, int wait) {
  if (wait == 0) {
    q->op = OP_NONE;
    if (q->closing) q->closing = NULL;
    return 0;
  }
  q->wait = wait;
  q->deadline = (wait & EV_TIMEOUT) ? now_ms() + my.get_timeout_value_ms(c->my) : 0;
  return wait;
}

/* Starts OP: 0 when it is over at once, else the events it waits for. */
static int op_start(an_env *env, conn *c, query *q, int op) {
  q->op = op;
  return op_settle(c, q, op_call(env, c, q, 0));
}

/* Goes on with the operation that waits when its socket is ready or its timeout passed. */
static int op_resume(an_env *env, conn *c, query *q) {
  int events = ready_events(my.get_socket(c->my), q->wait);
  if (!events && q->deadline && now_ms() >= q->deadline) events = EV_TIMEOUT;
  if (!events) return q->wait;
  return op_settle(c, q, op_call(env, c, q, events));
}

/* What to wait for. A query that a cancelled task left asks for a KILL QUERY first, once. */
static an_term wait_step(an_env *env, conn *c, query *q) {
  if (q->discard && !q->killed) {
    q->killed = true;
    return step_state(env, c, S_CANCEL);
  }
  return step_state(env, c, (q->wait & EV_WRITE) ? S_WRITE : S_READ);
}

/* ---- The phases. ---- */

/* Ends the query: its own statement goes to the next CLOSE, and a statement that changed the schema lets the cache
   go, since a cached statement may no longer fit its tables. */
static an_term finish_query(an_env *env, conn *c, query *q, an_term rows) {
  bool failed = q->failure[0] && !q->discard;
  if (q->flush && !q->failure[0])
    for (int i = 0; i < c->capacity; i++)
      if (c->entries[i].sql) forget(c, i);
  an_term out = failed ? make_step(env, c, S_FAILED, q->failure, no_rows(env), 0)
                       : make_step(env, c, S_DONE, "", rows, q->changes);
  end_query(c, q);
  return out;
}

/* Frees the result whose rows were read, and tells whether more results follow it. */
static bool rows_over(conn *c, query *q) {
  if (q->out.text) {
    my.free_result(q->res);
    q->res = NULL;
  } else {
    (void)my.stmt_free_result(q->stmt);
  }
  bool text_result = q->out.text;
  clear_result(&q->out);
  q->pending = false;
  q->phase = text_result ? P_TEXT_MORE : P_MORE;
  return text_result ? my.more_results(c->my) : my.stmt_more_results(q->stmt);
}

/* The rows of the result from the current one, up to the caps. NULL in *DONE when the rows go on (the step ROWS or
   BIG), else the phase moved on. */
static an_term take_rows(an_env *env, conn *c, query *q, int64_t max_rows, int64_t max_bytes, bool *over) {
  result *r = &q->out;
  an_list_builder rows;
  int64_t count = 0, bytes = 0;
  *over = false;
  if (!q->dirty) {
    /* A short call holds the scheduler while it runs. */
    if (max_rows > QUICK_ROWS) max_rows = QUICK_ROWS;
    if (max_bytes > QUICK_BYTES) max_bytes = QUICK_BYTES;
    if (r->wide) return step_state(env, c, S_BIG);
  }
  an_term names[MAX_NAMES];
  if (r->n <= MAX_NAMES)
    for (int col = 0; col < r->n; col++)
      names[col] = text0(env, my.fetch_field_direct(names_of(q), (unsigned)col)->name);
  an_list_begin(env, &rows, 0);
  bool end = false;
  while (count < max_rows && bytes < max_bytes) {
    if (!q->pending) {
      int got = next_row(q);
      if (got <= 0) {
        end = true;
        break;
      }
      q->pending = true;
    }
    /* A big row of the text protocol waits for the compute pool. */
    if (!q->dirty && row_size(r) > QUICK_BYTES) break;
    an_list_push(env, &rows, read_row(env, q, names, &bytes));
    q->pending = false;
    count++;
  }
  an_term list = an_list_end(env, &rows);
  if (!end) return make_step(env, c, count == 0 ? S_BIG : S_ROWS, "", list, 0);
  *over = true;
  if (q->failure[0]) {
    (void)rows_over(c, q);
    return list;
  }
  if (!rows_over(c, q)) return finish_query(env, c, q, list);
  /* More results follow (a CALL): these rows go now, and the next call reads the rest. */
  *over = false;
  return make_step(env, c, S_ROWS, "", list, 0);
}

/* Runs the phases of Q until it must wait, has rows to give, or ends. */
static an_term advance(an_env *env, conn *c, query *q, int64_t max_rows, int64_t max_bytes) {
  for (;;) {
    if (q->op != OP_NONE && op_resume(env, c, q) != 0) return wait_step(env, c, q);
    switch (q->phase) {
    case P_START:
      q->phase = P_CLOSE;
      continue;
    case P_CLOSE:
      if (q->discard || c->closing_size == 0 || q->closes == CLOSE_BATCH) {
        q->phase = q->discard ? P_FINISH : P_SEND;
        continue;
      }
      q->closing = c->closing[--c->closing_size];
      q->closes++;
      if (op_start(env, c, q, OP_CLOSE)) return wait_step(env, c, q);
      continue;
    case P_SEND:
      if (q->discard) {
        q->phase = P_FINISH;
        continue;
      }
      if (q->slot >= 0) {
        q->stmt = c->entries[q->slot].stmt;
        c->entries[q->slot].used = ++c->tick;
        q->phase = P_EXEC;
        continue;
      }
      q->stmt = my.stmt_init(c->my);
      if (!q->stmt) {
        fail_text(q, "out of memory");
        q->phase = P_FINISH;
        continue;
      }
      q->owned = true;
      {
        /* The stored result then holds the longest value of each column, which sizes its buffer. */
        my_bool on = 1;
        if (my.stmt_attr_set(q->stmt, ATTR_UPDATE_MAX_LENGTH, &on)) {
          fail_stmt(q);
          q->phase = P_FINISH;
          continue;
        }
      }
      q->phase = P_PREPARED;
      if (op_start(env, c, q, OP_PREPARE)) return wait_step(env, c, q);
      continue;
    case P_PREPARED:
      if (q->ret != 0) {
        /* The server does not prepare it: one with nothing to bind runs as text (a statement that failed to prepare
           holds nothing on the server, and its close frees memory only). */
        bool text_only = my.stmt_errno(q->stmt) == UNSUPPORTED_PREPARE && q->bound.count == 0;
        if (!text_only || q->discard) fail_stmt(q);
        close_later(c, q->stmt);
        q->stmt = NULL;
        q->owned = false;
        q->phase = text_only && !q->discard ? P_TEXT : P_FINISH;
        continue;
      }
      if (q->discard) {
        q->phase = P_FINISH;
        continue;
      }
      {
        unsigned long wanted = my.stmt_param_count(q->stmt);
        if (wanted != (unsigned long)q->bound.count) {
          snprintf(q->failure, sizeof q->failure, "mysql error: the sql has %lu %s, got %d", wanted,
                   wanted == 1 ? "parameter" : "parameters", q->bound.count);
          q->phase = P_FINISH;
          continue;
        }
        /* A write with a result (INSERT ... RETURNING) is not cached: a cached statement meets 2057 after the server
           ran it, and a write is never run again (P_FREED), so it would fail after it wrote. */
        bool result_free_write = !q->counts || my.stmt_field_count(q->stmt) == 0;
        if (q->cache && result_free_write && c->capacity > 0 && insert(c, q, (int)wanted)) q->owned = false;
      }
      q->phase = P_EXEC;
      continue;
    case P_EXEC:
      if (q->discard) {
        q->phase = P_FINISH;
        continue;
      }
      if (q->slot >= 0 && c->entries[q->slot].count != q->bound.count) {
        int wanted = c->entries[q->slot].count;
        snprintf(q->failure, sizeof q->failure, "mysql error: the sql has %d %s, got %d", wanted,
                 wanted == 1 ? "parameter" : "parameters", q->bound.count);
        q->phase = P_FINISH;
        continue;
      }
      /* Big parameters are copied into the library's packet on the compute pool. */
      if (q->big && !q->dirty) return step_state(env, c, S_BIG);
      if (q->bound.count > 0 && my.stmt_bind_param(q->stmt, q->bound.binds)) {
        fail_stmt(q);
        q->phase = P_FINISH;
        continue;
      }
      q->phase = P_EXECUTED;
      if (op_start(env, c, q, OP_EXECUTE)) return wait_step(env, c, q);
      continue;
    case P_EXECUTED:
      if (q->ret != 0) {
        if (!q->extra) fail_stmt(q);
        q->phase = P_FINISH;
        if (my.stmt_errno(q->stmt) == NEW_METADATA) {
          /* Another connection changed a table of the statement: the server ran it, and its rows, with more or fewer
             columns than the prepare said, wait on the socket. They are read and dropped (the free reads the socket),
             and the statement goes. */
          q->spoiled = true;
          q->phase = P_FREED;
          if (op_start(env, c, q, OP_FREE)) return wait_step(env, c, q);
        }
        continue;
      }
      if (my.stmt_field_count(q->stmt) == 0) {
        if (!q->extra) q->changes = q->counts ? (int64_t)my.stmt_affected_rows(q->stmt) : 0;
        q->phase = P_MORE;
        continue;
      }
      q->phase = P_STORED;
      if (op_start(env, c, q, OP_STORE)) return wait_step(env, c, q);
      continue;
    case P_FREED:
      /* The server ran the statement before the library saw 2057. A cached statement that is not a write is prepared
         again and runs once more, as a first run; that runs twice what it does besides reading (a NEXTVAL, a stored
         function that writes). A statement of this query alone (prepared just now, or with statement_cache=0) and a
         write give the 2057: running them again could write twice. */
      q->phase = P_FINISH;
      if (q->freed || q->extra || q->discard || q->retried || q->owned || q->counts || q->slot < 0) continue;
      {
        const entry *e = &c->entries[q->slot];
        q->sql = malloc(e->len ? e->len : 1);
        if (!q->sql) continue;
        memcpy(q->sql, e->sql, e->len);
      }
      forget(c, q->slot);
      q->cache = true;
      c->misses++;
      q->stmt = NULL;
      q->spoiled = false;
      q->slot = -1;
      q->retried = true;
      q->failure[0] = 0;
      q->phase = P_SEND;
      continue;
    case P_STORED:
      /* A failed store leaves the statement waiting for rows that the free below gives up on (it does not read the
         socket then); a next execute would read the socket for them. */
      if (q->ret != 0) q->spoiled = true;
      if (q->ret != 0 && !q->extra) fail_stmt(q);
      if (!q->extra && !q->failure[0]) q->changes = q->counts ? (int64_t)my.stmt_affected_rows(q->stmt) : 0;
      if (q->keep && !q->extra && !q->failure[0] && !q->discard) {
        MYSQL_RES *meta = my.stmt_result_metadata(q->stmt);
        if (!meta) {
          fail_stmt(q);
        } else if (describe(q, meta, false)) {
          q->phase = P_ROWS;
          continue;
        }
      }
      (void)my.stmt_free_result(q->stmt);
      clear_result(&q->out);
      q->phase = P_MORE;
      continue;
    case P_ROWS:
      if (q->discard) {
        (void)rows_over(c, q);
        continue;
      }
      {
        bool over;
        an_term out = take_rows(env, c, q, max_rows, max_bytes, &over);
        if (!over || q->phase == P_DONE) return out;
        continue;
      }
    case P_MORE:
      if (q->stmt && my.stmt_more_results(q->stmt)) {
        q->extra = true;
        q->phase = P_NEXTED;
        if (op_start(env, c, q, OP_NEXT)) return wait_step(env, c, q);
        continue;
      }
      q->phase = P_FINISH;
      continue;
    case P_NEXTED:
      /* 0: one more result, -1: none, else a failure that comes after the answer and is dropped. */
      if (q->ret > 0) q->spoiled = true;
      q->phase = q->ret == 0 ? P_EXECUTED : P_FINISH;
      continue;
    case P_TEXT:
      if (q->discard) {
        q->phase = P_FINISH;
        continue;
      }
      q->text = true;
      q->phase = P_TEXT_SENT;
      if (op_start(env, c, q, OP_QUERY)) return wait_step(env, c, q);
      continue;
    case P_TEXT_SENT:
      if (q->ret != 0) {
        if (!q->extra) fail_conn(q, c);
        q->phase = P_FINISH;
        continue;
      }
      q->phase = P_TEXT_STORED;
      if (op_start(env, c, q, OP_TEXT_STORE)) return wait_step(env, c, q);
      continue;
    case P_TEXT_STORED:
      /* No result is a failure only when the statement should have had one. */
      if (!q->res && my.field_count(c->my) > 0) {
        if (!q->extra) fail_conn(q, c);
        q->phase = P_FINISH;
        continue;
      }
      if (!q->extra) q->changes = q->counts ? (int64_t)my.affected_rows(c->my) : 0;
      if (q->res && q->keep && !q->extra && !q->failure[0] && !q->discard) {
        if (describe(q, q->res, true)) {
          q->phase = P_ROWS;
          continue;
        }
      }
      if (q->res) my.free_result(q->res);
      q->res = NULL;
      clear_result(&q->out);
      q->phase = P_TEXT_MORE;
      continue;
    case P_TEXT_MORE:
      if (my.more_results(c->my)) {
        q->extra = true;
        q->phase = P_TEXT_NEXTED;
        if (op_start(env, c, q, OP_TEXT_NEXT)) return wait_step(env, c, q);
        continue;
      }
      q->phase = P_FINISH;
      continue;
    case P_TEXT_NEXTED:
      q->phase = q->ret == 0 ? P_TEXT_SENT : P_FINISH;
      continue;
    case P_FINISH:
      return finish_query(env, c, q, no_rows(env));
    default:
      return an_raise(env, "mysql: the query is finished");
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
  (void)an_raise(env, "mysql: two calls ran on one connection at once");
  return false;
}

/* A copy of a String field of a Login with a NUL at its end; NULL when it is not one, holds a NUL or memory is out. */
static char *login_text(an_env *env, an_term login_term, uint32_t field) {
  an_term t;
  const char *data;
  size_t len;
  if (!an_get_field(env, login_term, LOGIN, field, &t) || !an_get_string(env, t, &data, &len) ||
      (len > 0 && memchr(data, '\0', len)))
    return NULL;
  char *copy = malloc(len + 1);
  if (!copy) return NULL;
  if (len > 0) memcpy(copy, data, len);
  copy[len] = '\0';
  return copy;
}

static bool login_int(an_env *env, an_term login_term, uint32_t field, int64_t *n) {
  an_term t;
  return an_get_field(env, login_term, LOGIN, field, &t) && an_get_int(env, t, n);
}

static bool set_number(MYSQL *m, int option, unsigned int n) { return my.options(m, option, &n) == 0; }

static bool set_flag(MYSQL *m, int option) {
  my_bool on = 1;
  return my.options(m, option, &on) == 0;
}

/* The options of the FFI adapter before a connect: the connect timeout (0 keeps the library's), no LOCAL INFILE, the
   read and write timeouts (0: none), and the TLS mode. A refused option stops the connect (a TLS option that did
   nothing would connect without the check that was asked for); the message goes to OUT. */
static bool configure(MYSQL *m, const login *l, unsigned connect_s, unsigned io_s, char *out, size_t size) {
  if ((connect_s > 0 && !set_number(m, OPT_CONNECT_TIMEOUT, connect_s)) || !set_number(m, OPT_LOCAL_INFILE, 0) ||
      (io_s > 0 && (!set_number(m, OPT_READ_TIMEOUT, io_s) || !set_number(m, OPT_WRITE_TIMEOUT, io_s)))) {
    snprintf(out, size, "mysql error: the client library refused a connection option");
    return false;
  }
  if (l->tls == TLS_DEFAULT) return true;
  if (!set_flag(m, OPT_SSL_ENFORCE) || (l->tls == TLS_VERIFY && !set_flag(m, OPT_SSL_VERIFY_SERVER_CERT))) {
    snprintf(out, size, "mysql error: the client library refused a TLS option");
    return false;
  }
  if (l->tls == TLS_VERIFY && l->ca[0] && my.options(m, OPT_SSL_CA, l->ca) != 0) {
    snprintf(out, size, "mysql error: the client library refused the ssl_ca option");
    return false;
  }
  return true;
}

/* connect(login, cache): a connection with a statement cache of CACHE statements (0: none), its character set
   utf8mb4. The read and write timeouts of a url with timeout_ms are the backstop of the FFI adapter: the limit plus
   10 seconds, in whole seconds. */
static an_term fn_connect(an_env *env, int argc, const an_term *argv) {
  int64_t port, timeout, timeout_ms, tls, capacity;
  char message[1024];
  (void)argc;
  if (!login_int(env, argv[0], L_PORT, &port) || !login_int(env, argv[0], L_TIMEOUT, &timeout) ||
      !login_int(env, argv[0], L_TIMEOUT_MS, &timeout_ms) || !login_int(env, argv[0], L_TLS, &tls) || port < 0 ||
      port > 65535 || timeout < 0 || timeout > 99999 || timeout_ms < 0 || timeout_ms > 999999999 || tls < 0 || tls > 2)
    return an_badarg(env, 0);
  if (!an_get_int(env, argv[1], &capacity) || capacity < 0 || capacity > MAX_CACHE) return an_badarg(env, 1);
  if (!STACK_SWITCH_SAFE) {
    static const char off[] = "mysql error: " NEEDS_BLOCKING;
    return an_error(env, off, sizeof off - 1);
  }
  const char *why = library_error();
  if (why) {
    int n = snprintf(message, sizeof message, "mysql error: cannot load the client library: %s", why);
    return an_error(env, message, n > 0 ? (size_t)n : 0);
  }
  login l = {login_text(env, argv[0], L_HOST), login_text(env, argv[0], L_USER), login_text(env, argv[0], L_PASSWORD),
             login_text(env, argv[0], L_CA), (int)port, (int)tls};
  char *database = login_text(env, argv[0], L_DATABASE);
  conn *c = calloc(1, sizeof *c);
  entry *entries = calloc((size_t)(capacity ? capacity : 1), sizeof *entries);
  MYSQL *m = l.host && l.user && l.password && l.ca && database && c && entries ? my.init(NULL) : NULL;
  if (!m) {
    free_login(&l);
    free(database);
    free(c);
    free(entries);
    return an_raise(env, "mysql: out of memory");
  }
  unsigned backstop = timeout_ms > 0 ? (unsigned)((timeout_ms + 999) / 1000 + 10) : 0;
  bool ok = configure(m, &l, (unsigned)timeout, backstop, message, sizeof message);
  if (ok && my.options(m, OPT_NONBLOCK, NULL) != 0) {
    snprintf(message, sizeof message, "mysql error: the client library refused a connection option");
    ok = false;
  }
  /* The connect itself blocks (this is a compute call); the non-blocking calls are for the queries. */
  if (ok && (!my.real_connect(m, l.host, l.user, l.password, database, (unsigned)port, NULL, CLIENT_FOUND_ROWS) ||
             my.set_character_set(m, "utf8mb4") != 0)) {
    failure_of(message, sizeof message, my.errno_of(m), my.error(m));
    ok = false;
  }
  free(database);
  if (!ok) {
    my.close(m);
    free_login(&l);
    free(c);
    free(entries);
    return an_error(env, message, strlen(message));
  }
  lock_init(&c->lock);
  c->my = m;
  c->entries = entries;
  c->capacity = (int)capacity;
  c->login = l;
  query_reset(&c->q);
  an_term out;
  conn_state *s = an_resource_new(env, CONN, &out);
  if (!s) {
    conn_state gone = {c};
    conn_free(&gone);
    return out;
  }
  s->c = c;
  return an_ok(env, out);
}

/* start(conn, sql, params, plan, options): runs SQL. With a Plan that is not `known`, only a cached statement runs;
   any other comes back as PLAN, and the adapter calls again with what it read of the sql. A query that a cancelled
   task left comes back as LEFT: the adapter drains it and calls again. Parameters of more than QUICK_BYTES in all come
   back as BIG_START from the short call, and `start_big` (the same function, on the compute pool) takes them. */
static an_term start(an_env *env, const an_term *argv, bool dirty) {
  const char *sql;
  size_t len;
  int64_t rows, bytes;
  an_term f[PLAN_FIELDS];
  bool known, cache, flush, counts, keep;
  conn *c = conn_of(env, argv[0]);
  if (!c) return an_badarg(env, 0);
  if (!an_get_string(env, argv[1], &sql, &len)) return an_badarg(env, 1);
  for (uint32_t i = 0; i < PLAN_FIELDS; i++)
    if (!an_get_field(env, argv[3], PLAN, i, &f[i])) return an_badarg(env, 3);
  if (!an_get_bool(env, f[PL_KNOWN], &known) || !an_get_bool(env, f[PL_CACHE], &cache) ||
      !an_get_bool(env, f[PL_FLUSH], &flush) || !an_get_bool(env, f[PL_COUNTS], &counts) ||
      !an_get_bool(env, f[PL_KEEP], &keep))
    return an_badarg(env, 3);
  if (!read_options(env, argv[4], &rows, &bytes)) return an_badarg(env, 4);
  if (!enter(env, c)) return an_void(env);
  if (c->inflight) {
    lock_drop(&c->lock);
    return step_state(env, c, S_LEFT);
  }
  uint64_t hash = hash_text(sql, len);
  int slot = find_entry(c, sql, len, hash);
  if (slot < 0 && !known) {
    lock_drop(&c->lock);
    return step_state(env, c, S_PLAN);
  }
  params bound = {0};
  char failure[sizeof c->q.failure] = "";
  bool over = false;
  (void)bind_all(env, argv[2], dirty ? SIZE_MAX : QUICK_BYTES, &bound, &over, failure, sizeof failure);
  if (over) {
    lock_drop(&c->lock);
    return step_state(env, c, S_BIG_START);
  }
  query *q = &c->q;
  query_reset(q);
  c->inflight = true;
  q->bound = bound;
  q->keep = keep;
  q->slot = slot;
  q->cache = cache;
  q->flush = flush && slot < 0;
  q->counts = slot >= 0 ? c->entries[slot].counts : counts;
  q->len = len;
  q->hash = hash;
  if (slot >= 0) {
    c->hits++;
  } else {
    if (cache) c->misses++;
    /* The text of a statement to prepare, which the library reads until the prepare is over. */
    q->sql = malloc(len ? len : 1);
    if (!q->sql) {
      end_query(c, q);
      lock_drop(&c->lock);
      return an_raise(env, "mysql: out of memory");
    }
    memcpy(q->sql, sql, len);
  }
  an_term out;
  if (failure[0]) {
    memcpy(q->failure, failure, sizeof failure);
    out = finish_query(env, c, q, no_rows(env));
  } else {
    q->phase = P_START;
    q->dirty = dirty;
    /* Only big parameters come to the dirty call (BIG_START). */
    q->big = dirty;
    out = advance(env, c, q, rows, bytes);
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

/* resume(conn, options): goes on with the query after a wait, or gives its next rows. A row too big for a short call,
   or big parameters to send, come back as BIG, and `resume_big` (on the compute pool) goes on. */
static an_term resume(an_env *env, const an_term *argv, bool dirty) {
  int64_t rows, bytes;
  conn *c = conn_of(env, argv[0]);
  if (!c) return an_badarg(env, 0);
  if (!read_options(env, argv[1], &rows, &bytes)) return an_badarg(env, 1);
  if (!enter(env, c)) return an_void(env);
  an_term out;
  if (c->q.phase == P_DONE) {
    out = an_raise(env, "mysql: no query runs");
  } else {
    c->q.dirty = dirty;
    out = advance(env, c, &c->q, rows, bytes);
  }
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

/* drain(conn): reads the query that a cancelled task left to its end, dropping its rows and its failure. */
static an_term fn_drain(an_env *env, int argc, const an_term *argv) {
  (void)argc;
  conn *c = conn_of(env, argv[0]);
  if (!c) return an_badarg(env, 0);
  if (!enter(env, c)) return an_void(env);
  an_term out;
  if (!c->inflight) {
    out = step_state(env, c, S_DONE);
  } else {
    c->q.discard = true;
    c->q.dirty = false;
    out = advance(env, c, &c->q, 1, 1);
  }
  lock_drop(&c->lock);
  return out;
}

/* cancel(conn): stops the statement that runs on the connection with a KILL QUERY sent on a connection of its own (on
   the compute pool), which gives up after CANCEL_WAIT_S seconds to connect and as many to send it and read the reply.
   It fails silently: the drain then waits for the statement to end. The server resets the kill of a thread at its next
   command, so a kill that comes after the statement ended stops nothing. */
static an_term fn_cancel(an_env *env, int argc, const an_term *argv) {
  char ignored[256], sql[64];
  (void)argc;
  conn *c = conn_of(env, argv[0]);
  if (!c) return an_badarg(env, 0);
  if (!enter(env, c)) return an_void(env);
  MYSQL *k = my.init(NULL);
  if (k) {
    if (configure(k, &c->login, CANCEL_WAIT_S, CANCEL_WAIT_S, ignored, sizeof ignored) &&
        my.real_connect(k, c->login.host, c->login.user, c->login.password, NULL, (unsigned)c->login.port, NULL, 0)) {
      int n = snprintf(sql, sizeof sql, "KILL QUERY %lu", my.thread_id(c->my));
      (void)my.real_query(k, sql, (unsigned long)n);
    }
    my.close(k);
  }
  lock_drop(&c->lock);
  return an_void(env);
}

/* transaction_open?(conn): the server's flag of the last reply, as the FFI adapter reads it. */
static an_term fn_in_transaction(an_env *env, int argc, const an_term *argv) {
  (void)argc;
  conn *c = conn_of(env, argv[0]);
  if (!c) return an_badarg(env, 0);
  if (!enter(env, c)) return an_void(env);
  unsigned int status = 0;
  bool open = my.get_info(c->my, INFO_SERVER_STATUS, &status) == 0 && (status & STATUS_IN_TRANS);
  lock_drop(&c->lock);
  return an_bool(env, open);
}

/* link_up?(conn): whether the library still has its link to the server; it closes it when a call finds the server
   gone. */
static an_term fn_connected(an_env *env, int argc, const an_term *argv) {
  (void)argc;
  conn *c = conn_of(env, argv[0]);
  if (!c) return an_badarg(env, 0);
  if (!enter(env, c)) return an_void(env);
  bool up = my.get_socket(c->my) >= 0;
  lock_drop(&c->lock);
  return an_bool(env, up);
}

static an_term fn_server_info(an_env *env, int argc, const an_term *argv) {
  (void)argc;
  conn *c = conn_of(env, argv[0]);
  if (!c) return an_badarg(env, 0);
  if (!enter(env, c)) return an_void(env);
  an_term out = text0(env, my.get_server_info(c->my));
  lock_drop(&c->lock);
  return out;
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
  {"Plan", AN_STRUCT, "known: Bool, cache: Bool, flush: Bool, counts: Bool, keep: Bool"},
  {"Options", AN_STRUCT, "rows: Int, bytes: Int"},
  {"Step", AN_STRUCT, "state: Int, fd: Int, failure: String, rows: List[Map[String, Value]], changes: Int"},
  {"CacheStats", AN_STRUCT, "size: Int, capacity: Int, hits: Int, misses: Int, evictions: Int"},
  {"Login", AN_STRUCT,
   "host: String, port: Int, user: String, password: String, database: String, timeout: Int, timeout_ms: Int, "
   "tls: Int, ca: String"},
};

static const an_resource_type resources[] = {
  {"Conn", sizeof(conn_state), conn_free},
};

static const an_function functions[] = {
  {"connect", "(Login, Int) -> Result[Conn]", fn_connect, AN_DIRTY},
  {"start", "(Conn, String, List[Value], Plan, Options) -> Step", fn_start, AN_SHORT},
  {"start_big", "(Conn, String, List[Value], Plan, Options) -> Step", fn_start_big, AN_DIRTY},
  {"resume", "(Conn, Options) -> Step", fn_resume, AN_SHORT},
  {"resume_big", "(Conn, Options) -> Step", fn_resume_big, AN_DIRTY},
  {"drain", "(Conn) -> Step", fn_drain, AN_SHORT},
  {"cancel", "(Conn) -> Void", fn_cancel, AN_DIRTY},
  {"transaction_open?", "(Conn) -> Bool", fn_in_transaction, AN_SHORT},
  {"link_up?", "(Conn) -> Bool", fn_connected, AN_SHORT},
  {"server_info", "(Conn) -> String", fn_server_info, AN_SHORT},
  {"cache_stats", "(Conn) -> CacheStats", fn_cache_stats, AN_SHORT},
};

AN_MODULE_TABLES("db_mysql", functions, AN_COUNT(functions), types, AN_COUNT(types), resources, AN_COUNT(resources),
                 NULL)
