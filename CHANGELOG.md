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
- The MySQL connection is a native resource freed by `mysql_close`: the end of the task that opened it closes it, as
  for SQLite and PostgreSQL (before, only `Db.close` did). Open the connection in the task that keeps it (usually
  `main`), or hand it over with `Task.spawn_owning(&f, conn)`. `Db.close` still works, and a use after it is still
  `mysql error: the connection is closed`.
- A connection still open when `main` returns is closed (Agentica 0.12.0 frees the native resources at the end of the
  run); for SQLite and PostgreSQL, which already closed at the end of their task, this is the only new part.
- A native library that is missing is an `error` from `open` (`<adapter> error: cannot load ...`), not a stop of the
  program.
- SQLite binds a text with its length, so a text with a NUL is stored and read back whole (PostgreSQL and MySQL still
  refuse it).
- `Db.transaction` is generic: `transaction[R](conn, body)` gives the `R` of the block's `ok` when the transaction
  commits (`Result[R]`); an `error` still rolls back. A block that returns `ok()` works as before. A block whose only
  result is `error(...)` no longer infers `R`: give it a type (`failed: Result[Void] = error("x")`, then return
  `failed`).
- Needs Agentica 0.14.0 (CI and README).
