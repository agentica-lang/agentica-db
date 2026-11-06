# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- SQLite keeps the prepared statements of a connection by their sql, up to `statement_cache` (a url parameter): a
  repeated query skips the prepare, a hop to the compute pool, and the least recently used statement is finalized when
  the cache is full. The default is 128 for the connections of a `DbPool` and 0 for `Db.open`, because the end of a
  task does not finalize statements and SQLite would keep the file of an unclosed connection open until the program
  ends: close a connection that you open with `statement_cache` above 0. `Db.close` finalizes the statements, also
  those of a call that was cancelled. `Db.open_pooled` is `Db.open` with the pool default.
  `examples/sqlite_bench.agc` measures the cost of a query and of a row.

## [0.5.0] - 2026-11-06

Needs Agentica 0.25.0 or later.

### Changed

- **Breaking:** `Orm.schema(table, codec)` takes the codec of the struct, `Orm.schema("users", User.codec)`, and reads
  the members from `codec.members`; the `members` argument and `JSON.codec(User)` are gone. The package needs Agentica
  0.25.0 or later, which has `T.codec` and `Codec[T]` in place of `JSON.codec(T)` and `JSON.Codec[T]`.
- The `pool` dependency of `src/db` is pinned by the tag `0.4.0` and no longer by a commit.

## [0.4.0] - 2026-11-06

### Added

- `src/pool/`, a generic pool of resources and a package of its own (`import Pool from "pkg/pool/pool"`, installed
  alone with `subdir = "src/pool"`, no native library); the repository is now a workspace. `Pool.start`, `Pool.with`,
  `Pool.close` with a drain, `Pool.timeout?`: callers wait in line, the resource of a body that crashes or runs past
  `lease_ms` is checked in or ended and replaced, up to `max_overflow` more resources are made in a spike (ended after `overflow_idle_ms` of idleness), and idle
  resources are pinged and replaced by `max_age_ms` and `idle_ms`. See the Pool guide.
- `DbPool` (`import DbPool from "pkg/db/db_pool"`), a pool of database connections on the generic pool:
  `DbPool.start`, `DbPool.with` (the block gets a `Db.Connection`, so `Db`, `Orm` and `Migrate` work in it),
  `DbPool.close`, `DbPool.timeout?`. A transaction left open is rolled back when the connection comes back, a block
  that crashes or runs past `lease_ms` costs its connection, and idle connections are pinged. Sizes: 4 for SQLite, 10
  for PostgreSQL and MySQL, `max_overflow` for spikes; a private in-memory SQLite database allows one connection. See
  the Connection pool guide.
- `Db.connected?(conn)` (no round trip): whether the connection is open and the client library still has its link.
- `Migrate` (`import Migrate from "pkg/db/migrate"`): ordered migrations, each a version and sql statements or a
  function over the connection, applied by `Migrate.up` in one transaction each and recorded in a `schema_migrations`
  table with a checksum. A second run applies nothing; a changed, missing or out-of-order migration is an error. It
  runs on SQLite, PostgreSQL and MySQL. The Migrations guide lays them out one file per migration, with a test for a
  file that is missing from the list.
- SQLite urls take the parameters `journal_mode`, `foreign_keys`, `busy_timeout` and `fts5=required`
  (`sqlite:app.db?journal_mode=delete&foreign_keys=off`); `fts5=required` makes `open` fail when the system SQLite has
  no FTS5. A name that starts with `file:` is a SQLite URI and goes to SQLite as it is (`file:app.db?mode=ro`,
  `file::memory:?cache=shared`); the URI flag is on for every build.
- `timeout_ms` for every database: a url parameter (none by default) and a last argument of `Db.query` and
  `Db.execute` (`-1` takes the connection's, `0` has none). SQLite interrupts the statement and stops the wait for a
  lock (`sqlite error 9`), PostgreSQL sets `statement_timeout` (`57014`), MySQL sets `max_execution_time` for a SELECT
  (`3024`) and MariaDB `max_statement_time` (`1969`), with the client read and write timeouts as a backstop.
  `Db.timeout?(message)` recognizes these failures.
- `Db.in_transaction?(conn)` (no round trip) and `Db.healthy?(conn)` for the three databases.

### Changed

- SQLite reads rows with fewer VM steps: a step that gives a row no longer reads the clock or runs the lock rules (they
  run only when a step finds a lock), and the columns of a row are read in one loop. The `busy_timeout` window now starts
  at the first refusal, so the time a call queued for the compute pool before it no longer counts; `timeout_ms` is
  unchanged. The public API and the errors are the same.
- SQLite prepares each statement once: `Db.query` and `Db.execute` used to parse the sql twice (a probe to refuse a
  second statement, then the statement itself). A run of 10,000 selects takes about a fifth less time.
- **Breaking:** the packages moved to `src/db` and `src/pool`, and the root of the repository is only a workspace.
  A project that depends on `db` must name the folder: `db = { git = "https://github.com/agentica-lang/agentica-db",
  tag = "TAG", subdir = "src/db" }` (or `agentica add db https://github.com/agentica-lang/agentica-db --tag TAG
  --subdir src/db`), with `TAG` a release after 0.3.0 (0.3.0 and earlier keep the package at the root and take no
  `subdir`). The imports do not change (`pkg/db/db`, `pkg/db/db_pool`, `pkg/db/orm`, `pkg/db/migrate`), nor does
  the API. Inside `src/db`, the adapters moved to the folders `sqlite/`, `postgres/` and `mysql/` and `value.agc`
  and `milliseconds.agc` to `support/`; a project that imported those files directly (`pkg/db/sqlite`,
  `pkg/db/value`) must use the new paths.
- **Breaking:** `Postgres.Handle` and `Mysql.Handle` in `Db.Connection` are now the records `Postgres.Connection` and
  `Mysql.Connection` (the handle with the timeout of the connection and, for MySQL, the flavor of the server). Code that
  only passes the `Db.Connection` around is not affected.
- **Breaking:** a SQLite connection now opens with `journal_mode=wal` and `foreign_keys=on` (SQLite's own defaults
  were a rollback journal and foreign keys off). A file database stays in WAL mode once opened. Add
  `?journal_mode=delete&foreign_keys=off` to the url for the old behavior. The default `busy_timeout` stays 5000 ms. A
  WAL that a read-only database refuses is skipped when the url did not name a journal mode.
- **Breaking (default change):** a SQLite connection now also opens with the pragmas of Rails 8: `synchronous=normal`
  when the database is in WAL mode (SQLite's own `full` in any other mode), `mmap_size=134217728`, `cache_size=2000`
  (pages) and `journal_size_limit=67108864`. `synchronous=normal` in WAL does not sync the WAL file at each commit, so
  a power loss or an OS crash (not a crash of the process) can lose the last commits, but never corrupts the database.
  Add `?synchronous=full` to the url for the old durability, and `?mmap_size=0&cache_size=-2000&journal_size_limit=-1`
  for SQLite's own values of the others. The new url parameters are `synchronous` (`off`, `normal`, `full`, `extra`),
  `mmap_size`, `cache_size` and `journal_size_limit`; a bad value is a `sqlite error: ...`. `Db.transaction` already
  began with `BEGIN IMMEDIATE`, which is unchanged.
- **Breaking:** a `?` in a SQLite path now starts the parameters, so `a?b.db`, `q.db?` and the Windows `\\?\C:\...`
  prefix are no longer file names (`sqlite:file:a%3fb.db` is). A parameter that is not known is an error.
- CI now tests with Agentica 0.24.4 (pinned by sha256 on every OS), four test files at once. The package still needs
  Agentica 0.18.0 or later; `examples/users.agc` needs a newer one: it reads the `Bytes` body of `HttpRequest` and
  writes the `Bytes` body of `HttpResponse`, which came with the 0.19.0 series. The library itself uses no HTTP
  type.
- A SQLite statement that finds the database locked by another connection (or a table of a shared cache) waits by
  sleeping in its task and trying again, up to `busy_timeout` (default 5000 ms), and not inside SQLite: concurrent
  write transactions succeed with `AGENTICA_SCHEDULERS=1` or `2`, where they failed with `database is locked`.
  SQLite's own busy timeout is now 0, so `PRAGMA busy_timeout` shows 0.
  A write in a transaction that began with a plain `BEGIN` and has read is not waited for and fails at once with
  `database is locked` (SQLite 3.34 or later), so it cannot stall the other connection's `COMMIT`.
- **Breaking:** `Sqlite.open` gives a `Sqlite.Connection` (a record with the handle and the busy timeout), and the
  payload of `Db.Connection.Sqlite` is that type; `Sqlite.Handle` is no longer exported. `Db.open` is unchanged.

### Fixed

- `Db.transaction` no longer sends a ROLLBACK to a connection that is not in a transaction any more, so a SQLite write
  that times out inside one gives the timeout error alone, without `rollback failed: ... no transaction is active`.

## [0.3.0] - 2026-10-30

### Changed

- **Breaking:** needs Agentica 0.18.0 or later.
- **Breaking:** `Orm.find` and `Orm.one` give a builtin `Optional[T]` (`some(row)` or `none`); `Orm.Option` is gone.
- An Orm field can be an `Optional[T]` for a column that can be NULL: NULL reads as `none` and `none` writes a NULL.
  `JsonField[T]` stays for a column that may also be absent (not selected, or left alone by a write).
- The Orm error for a NULL in a field that cannot hold one says `NULL in a field that is not Optional or JsonField`.
- An Orm schema whose primary key is an `Optional` or a `JsonField` is a schema error: a NULL key would match no row.

## [0.2.0] - 2026-10-30

### Changed

- **Breaking:** needs Agentica 0.17.0 or later.
- **Breaking:** `Value.Blob` holds `Bytes` instead of `List[Int]`; a blob is read and bound without a list copy.
- CI runs the SQLite suite on macOS and Windows.

## [0.1.0] - 2026-10-29

First release. Needs Agentica 0.16.0 or later.

### Added

- `Db`: `open`, `query`, `execute`, `transaction[R]` and `close` over a `Connection`, with `Value` parameters bound to
  `?` placeholders. `Db` re-exports `Value` and `Row`.
- SQLite (`sqlite:PATH`, `sqlite::memory:`) through the system libsqlite3; a text with a NUL is stored whole.
- PostgreSQL (`postgres://`, `postgresql://`) through the system libpq, with SQLSTATE error codes.
- MySQL and MariaDB (`mysql://`, `mariadb://`) through the system libmariadb, with prepared statements, server error
  codes and TLS through `ssl_mode`. Tested with MariaDB 11 and MySQL 8.4.
- A connection is closed by `Db.close`, at the end of the task that opened it, or when `main` returns. A missing
  native library is an `error` from `open`.
- `Orm`, a small typed layer: `schema`, `check`, `query` and `query_as` read rows into plain structs; `insert`,
  `update`, `delete` and `patch` write them; `find` and a query builder (`from`, `where`, `where_eq`, `where_in`,
  `order_by`, `order_by_desc`, `limit`, `offset`, then `all`, `one`, `count`, `update_all`, `delete_all`). A column
  that is not in the schema is an error before any sql runs. `update_all` and `delete_all` refuse a query with no
  condition (`Orm.where(q, "1 = 1", [])` means every row).
- `Orm.classify(error_text)` gives an `Orm.Error` to `case` on (`BadRequest`, `Conflict`, `NotDecodable`, `Schema`,
  `Database`); a unique or foreign-key violation of any database is a `Conflict`.
- `examples/users.agc`: a web-handler style users API on the Orm, run by CI against SQLite.
- The behavior is specified as Gherkin features in `specs/`, run by `agentica test`; `make check` checks every file.
- A documentation site: https://agentica-lang.github.io/agentica-db/.

[unreleased]: https://github.com/agentica-lang/agentica-db/compare/0.5.0...HEAD
[0.5.0]: https://github.com/agentica-lang/agentica-db/compare/0.4.0...0.5.0
[0.4.0]: https://github.com/agentica-lang/agentica-db/compare/0.3.0...0.4.0
[0.3.0]: https://github.com/agentica-lang/agentica-db/compare/0.2.0...0.3.0
[0.2.0]: https://github.com/agentica-lang/agentica-db/compare/0.1.0...0.2.0
[0.1.0]: https://github.com/agentica-lang/agentica-db/releases/tag/0.1.0
