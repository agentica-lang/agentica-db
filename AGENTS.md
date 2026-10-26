# agentica-db

One database API for Agentica (`db.agc`, `value.agc`) and one adapter per database (`sqlite.agc`, `postgres.agc`
with its placeholder scanner `postgres_sql.agc`), all through the C FFI. No C code of ours.

## Commands

- Binary: the release pinned in `.github/workflows/ci.yml` (`AGENTICA_VERSION`, with its sha256). Download it
  under `.tools/` (gitignored), never `/tmp`.
- `for file in *.agc specs/*.agc test/*.agc; do agentica check "$file"; done`, then
  `agentica test --steps specs/steps.agc`: the features of `specs/` and the unit tests of `test/`. Always give
  `--steps`: without it every step is undefined. SQLite needs no server. `--only TEXT` keeps the scenarios and tests
  whose name contains `TEXT`.
- The PostgreSQL scenarios need a server and libpq (`libpq5`) and read `AGENTICA_DB_POSTGRES_URL`. Without it they
  fail, locally and in CI: there is no skipped scenario. Without a server run only the SQLite ones:
  `agentica test --steps specs/steps.agc --only "on sqlite"` (every SQLite scenario has "on sqlite" in its name).
  Locally: `docker run -d --rm --name agentica-db-pg -e POSTGRES_PASSWORD=pw -p 127.0.0.1:55432:5432 postgres:17`,
  then `AGENTICA_DB_POSTGRES_URL='postgres://postgres:pw@127.0.0.1:55432/postgres?sslmode=disable' agentica test
  --steps specs/steps.agc`, and `docker stop agentica-db-pg` when done. Scenarios use temporary tables, so they
  leave nothing behind.

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
- Tests are BDD-first: behavior is a Gherkin scenario in `specs/*.feature`, run by `agentica test`, not a test file.
  The contract every adapter must meet is in the common features (`opening`, `values`, `queries`, `errors`,
  `transactions`), each scenario an outline over an `adapter` column (`sqlite`, `postgres`); what only one adapter
  promises is in `sqlite.feature` or `postgres.feature`. A new behavior is a scenario first. A value written must
  read back unchanged.
- The steps are in `specs/steps.agc`, few and generic (`a "sqlite" database`, `I execute "sql" with:` and a table of
  typed params, `the query "sql" returns:` and a table, `it fails with "prefix"`). They drive `Db` through
  `specs/driver.agc`, a program under test that holds the connection (a step program cannot keep a connection between
  steps), with the requests of `specs/protocol.agc` and the typed cells of `specs/cells.agc`. A table cell is a
  `Value` as text: `Int 31`, `Float -0.25`, `Text ana`, `Blob 0,1,255`, `Bool true`, `Null`, `Repeat 5000 Blob 7`;
  `[NUL]`, `[LF]`, `[TAB]`, `[VT]`, `[FF]`, `[CR]` and `[SP]` stand for characters a cell cannot hold. In a step text,
  `[URL]` is the PostgreSQL url (`[URL]&name=value` adds a libpq parameter), `[SERVER]` is it without its scheme, and
  `[SCRATCH]` is a folder under `tmp/`. A feature that uses a marker says so in its description.
- Add a step only when no step can say it. Lines of 119 characters at most, except a step line that holds a long sql.
- A statement that fails must be checked by the next `Then` (`it fails with ...`): the driver refuses any new request
  while the last failure is unchecked, so a failing setup step fails the scenario.
- Scenario names are unique: put a column of the Examples in the title of an outline with several rows.
- `test/*_test.agc` is only for a pure helper that needs no connection: the placeholder scanner
  (`test/postgres_sql_test.agc`). Anything that opens a connection is a scenario.
- Ruby forms first (`start_with?`, `each`, `Value.Text(...)`); style: `agentica-code-guidelines` of the Agentica
  repository. Lines are at most 119 characters.
- Every user-visible change adds a line under `## [Unreleased]` of `CHANGELOG.md`.
- A line that is only `end` is followed by an empty line, except before another `end`, `else`, `elsif`, a closing `)`
  or `]`, or the end of the file (all the `.agc` files follow it).
