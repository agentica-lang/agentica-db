# agentica-db

One database API for Agentica (`db.agc`, `value.agc`) and one adapter per database (`sqlite.agc`, `postgres.agc`
with its placeholder scanner `postgres_sql.agc`), all through the C FFI. No C code of ours.

## Commands

- Binary: the release pinned in `.github/workflows/ci.yml` (`AGENTICA_VERSION`, with its sha256). Download it
  under `.tools/` (gitignored), never `/tmp`.
- `agentica check FILE.agc` for every `.agc` file, then `agentica test`. SQLite needs no server.
- The PostgreSQL tests (`test/postgres_test.agc`) need a server and libpq (`libpq5`) and read
  `AGENTICA_DB_POSTGRES_URL`; without it they are skipped (one passing test says so, and fails when `CI=true`).
  Locally: `docker run -d --rm --name agentica-db-pg -e POSTGRES_PASSWORD=pw -p 127.0.0.1:55432:5432 postgres:17`,
  then `AGENTICA_DB_POSTGRES_URL='postgres://postgres:pw@127.0.0.1:55432/postgres?sslmode=disable' agentica test`,
  and `docker stop agentica-db-pg` when done. Tests use temporary tables, so they leave nothing behind.

## Rules

- Search with `rg`.
- An adapter keeps its `extern` block private and exports only the wrapper (`wrapping` guide of the Agentica
  site: `library/io-and-system/native/wrapping`). An adapter has the same four functions as `db.agc`:
  `open`, `close`, `query`, `execute`. `db.agc` dispatches on `Connection`; `transaction` stays in `db.agc`.
- Placeholders are `?` in the API. An adapter translates them (`$1` for PostgreSQL) and always binds; no value is
  ever spliced into sql.
- A failure is `error(message)` in one of two shapes: an engine failure `<adapter> error <code>: <message>`, a
  bad input `<adapter> error: <message>`; the module's own `db error: <message>`. A bad input is an error, not a
  halt.
- An adapter exports its own `BEGIN_SQL`; `transaction` in `db.agc` uses it.
- Tests check behavior through `Db`, in `test/*_test.agc`. A value written must read back unchanged. What every
  adapter must do is in `test/shared.agc` (`Shared.cases(flavor)`); an adapter's own tests go in its file.
- Ruby forms first (`start_with?`, `each`, `Value.Text(...)`); style: `agentica-code-guidelines` of the Agentica
  repository. Lines are at most 119 characters.
- Every user-visible change adds a line under `## [Unreleased]` of `CHANGELOG.md`.
