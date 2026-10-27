# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- `Db` API over a `Connection`: `open`, `query`, `execute`, `transaction`, `close`, with `Value` parameters bound
  to `?` placeholders.
- SQLite adapter through the system libsqlite3 (`sqlite:PATH`, `sqlite::memory:`).
- PostgreSQL adapter through the system libpq (`postgres://` and `postgresql://` urls), with SQLSTATE error codes.
- MySQL and MariaDB adapter through the system libmariadb (`mysql://` and `mariadb://` urls), with prepared
  statements, server error codes and TLS through `ssl_mode` (`verify` needs `ssl_ca`). Tested with MariaDB 11 and
  MySQL 8.4.
- The behavior of the API is specified as Gherkin features in `specs/`, run by `agentica test`;
  the unit and integration tests they replace are removed.
- `agentica.toml` sets `[style] blank_line_after_end`, so `agentica check` enforces the empty line after a bare `end`.
- `Db` re-exports `Value` and `Row`: `import Db from "pkg/db/db"` is enough, and `Db.Value.Text(...)` replaces the
  import of `value`.
- The PostgreSQL and MySQL connections are native resources freed by `PQfinish` and `mysql_close`: the end of the
  task that opened one closes it, as for SQLite, and so does the end of `main`. `Db.close` still works, and a use after
  it is still `postgres error: the connection is closed` (`mysql error: ...` for MySQL).
- A native library that is missing is an `error` from `open` (`<adapter> error: cannot load ...`), not a stop of the
  program.
- SQLite binds a text with its length, so a text with a NUL is stored and read back whole (PostgreSQL and MySQL still
  refuse it).
- Needs Agentica 0.12.0 (CI and README).
