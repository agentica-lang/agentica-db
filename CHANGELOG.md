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
- The PostgreSQL connection is a native resource freed by `PQfinish`: the end of the task that opened it closes it,
  as for SQLite. `Db.close` still works, and a use after it is still `postgres error: the connection is closed`.
- Needs Agentica 0.11.0 (CI and README).
