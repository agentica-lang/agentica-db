# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- `pool/`, a generic pool of resources and a package of its own (`import Pool from "pkg/pool/pool"`, installed alone
  with `subdir = "pool"`, no native library); the repository is now a workspace. `Pool.start`, `Pool.with`,
  `Pool.close` with a drain, `Pool.timeout?`: callers wait in line, the resource of a body that crashes or runs past
  `lease_ms` is checked in or ended and replaced, up to `max_overflow` more resources are made in a spike (ended after `overflow_idle_ms` of idleness), and idle
  resources are pinged and replaced by `max_age_ms` and `idle_ms`. See the Pool guide.
- `Migrate` (`import Migrate from "pkg/db/migrate"`): ordered migrations, each a version and sql statements or a
  function over the connection, applied by `Migrate.up` in one transaction each and recorded in a `schema_migrations`
  table with a checksum. A second run applies nothing; a changed, missing or out-of-order migration is an error. It
  runs on SQLite, PostgreSQL and MySQL.
- SQLite urls take the parameters `journal_mode`, `foreign_keys`, `busy_timeout` and `fts5=required`
  (`sqlite:app.db?journal_mode=delete&foreign_keys=off`); `fts5=required` makes `open` fail when the system SQLite has
  no FTS5. A name that starts with `file:` is a SQLite URI and goes to SQLite as it is (`file:app.db?mode=ro`,
  `file::memory:?cache=shared`); the URI flag is on for every build.

### Changed

- **Breaking:** a SQLite connection now opens with `journal_mode=wal` and `foreign_keys=on` (SQLite's own defaults
  were a rollback journal and foreign keys off). A file database stays in WAL mode once opened. Add
  `?journal_mode=delete&foreign_keys=off` to the url for the old behavior. The default `busy_timeout` stays 5000 ms. A
  WAL that a read-only database refuses is skipped when the url did not name a journal mode.
- **Breaking:** a `?` in a SQLite path now starts the parameters, so `a?b.db`, `q.db?` and the Windows `\\?\C:\...`
  prefix are no longer file names (`sqlite:file:a%3fb.db` is). A parameter that is not known is an error.
- CI now tests with Agentica 0.23.0 (pinned by sha256 on every OS). The package still needs Agentica 0.18.0 or later;
  `examples/users.agc` needs a newer one: it reads the `Bytes` body of `HttpRequest` and writes the `Bytes` body of
  `HttpResponse`, which came with the 0.19.0 series. The library itself uses no HTTP type.
- A SQLite statement that finds the database locked by another connection (or a table of a shared cache) waits by
  sleeping in its task and trying again, up to `busy_timeout` (default 5000 ms), and not inside SQLite: concurrent
  write transactions succeed with `AGENTICA_SCHEDULERS=1` or `2`, where they failed with `database is locked`.
  SQLite's own busy timeout is now 0, so `PRAGMA busy_timeout` shows 0.
  A write in a transaction that began with a plain `BEGIN` and has read is not waited for and fails at once with
  `database is locked` (SQLite 3.34 or later), so it cannot stall the other connection's `COMMIT`.
- **Breaking:** `Sqlite.open` gives a `Sqlite.Connection` (a record with the handle and the busy timeout), and the
  payload of `Db.Connection.Sqlite` is that type; `Sqlite.Handle` is no longer exported. `Db.open` is unchanged.

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

[unreleased]: https://github.com/agentica-lang/agentica-db/compare/0.3.0...HEAD
[0.3.0]: https://github.com/agentica-lang/agentica-db/compare/0.2.0...0.3.0
[0.2.0]: https://github.com/agentica-lang/agentica-db/compare/0.1.0...0.2.0
[0.1.0]: https://github.com/agentica-lang/agentica-db/releases/tag/0.1.0
