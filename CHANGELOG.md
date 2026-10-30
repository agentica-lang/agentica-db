# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

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

[unreleased]: https://github.com/agentica-lang/agentica-db/compare/0.1.0...HEAD
[0.1.0]: https://github.com/agentica-lang/agentica-db/releases/tag/0.1.0
