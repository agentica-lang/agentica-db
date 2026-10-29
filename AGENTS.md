# agentica-db

One database API for Agentica (`db.agc`, `value.agc`) and one adapter per database (`sqlite.agc`, `postgres.agc`
with its placeholder scanner `postgres_sql.agc`, `mysql.agc` with its statement scanner `mysql_sql.agc` and its url
reader `mysql_url.agc`), all through the C FFI. No C code of ours. `orm.agc` is a typed layer over `Db` (plain structs
in and out, always bound `?` parameters) with `orm/codec.agc` (row to Json for `JSON.codec`), `orm/build.agc` (the
sql of the query builder) and `orm/dialect.agc` (identifier names and quotes); it takes a `Db.Connection` and never
touches an adapter. `examples/users.agc` is a runnable web-handler style example of the Orm; `specs/examples.feature`
runs it and checks its output.

## Commands

- Binary: the release pinned in `.github/workflows/ci.yml` (`AGENTICA_VERSION`, with its sha256). Download it
  under `.tools/` (gitignored), never `/tmp`. A version bump changes `AGENTICA_VERSION`, `AGENTICA_SHA256` and the
  three `sha256` of the `sqlite` matrix (macOS and Windows), all from the SHA256SUMS of the Agentica release.
- `make check` (`agentica check` on every `.agc` file, so `orm/`, `examples/`, `specs/` and `test/` too), then
  `agentica test`: the features of `specs/` (it finds `specs/steps.agc` by itself) and
  the unit tests of `test/`. SQLite needs no server. `--only TEXT` keeps the scenarios and tests whose name contains
  `TEXT`.
- The PostgreSQL scenarios need a server and libpq (`libpq5`) and read `AGENTICA_DB_POSTGRES_URL`; the MySQL ones need
  a server and libmariadb (`libmariadb3`) and read `AGENTICA_DB_MYSQL_URL`. Without the variable they fail, locally
  and in CI: there is no skipped scenario. Without a server run only the SQLite ones:
  `agentica test --only "on sqlite"` (every SQLite scenario has "on sqlite" in its name).
  Locally: `docker run -d --rm --name agentica-db-pg -e POSTGRES_PASSWORD=pw -p 127.0.0.1:55432:5432 postgres:17`,
  then `AGENTICA_DB_POSTGRES_URL='postgres://postgres:pw@127.0.0.1:55432/postgres?sslmode=disable' agentica test`,
  and `docker stop agentica-db-pg` when done. For MySQL:
  `docker run -d --rm --name agentica-db-mysql -e MARIADB_ROOT_PASSWORD=pw -p 127.0.0.1:53306:3306 mariadb:11`, then
  `AGENTICA_DB_MYSQL_URL='mysql://root:pw@127.0.0.1:53306/mysql'` (an address, never `localhost`: the client library
  takes that for the local socket), and `docker stop agentica-db-mysql` when done. Run the whole suite against MySQL
  too (CI does): `-e MYSQL_ROOT_PASSWORD=pw ... mysql:8.4` on another port. The two servers differ (MySQL does not
  prepare `START TRANSACTION`), so a MySQL change passes on both. Scenarios use temporary tables, so
  they leave nothing behind.
- The documentation site is in `site/` (Hugo; `site/DESIGN.md` says how it differs from the Agentica site):
  `make site` builds it (needs Hugo and Dart Sass, see `.github/workflows/pages.yml`), `make site-samples` checks
  every `agentica` block of `site/content/` with `agentica check` (and runs the ones followed by an `output` block).
  A page of `site/content/` never starts with a `# ` heading (the layout prints the title) and keeps one line per
  paragraph or list item. A change to the API updates its page.

## Rules

- Search with `rg`.
- An adapter keeps its `extern` block private and exports only the wrapper (`wrapping` guide of the Agentica
  site: `library/io-and-system/native/wrapping`). An adapter has the same four functions as `db.agc`:
  `open`, `close`, `query`, `execute`. `db.agc` dispatches on `Connection`; `transaction` stays in `db.agc`.
  `db.agc` also re-exports `Value` and `Row` of `value.agc` (`export V.Value`), so a user imports `Db` only. The
  connection of each adapter is a native resource (`sqlite3_close_v2`, `PQfinish`, `mysql_close`): the end of the task
  or of `main` closes it, and `Native.closed?` turns a use after `close` into an error (SQLite keeps the runtime
  error). `open` calls `Native.load` before touching the library, so a missing library is an `error`.
- Placeholders are `?` in the API. An adapter translates them (`$1` for PostgreSQL; MySQL takes `?` natively) and
  always binds (`mysql_stmt_*` for MySQL); no value is ever spliced into sql.
- A failure is `error(message)` in one of two shapes: an engine failure `<adapter> error <code>: <message>`, a
  bad input `<adapter> error: <message>`; the module's own `db error: <message>`. A bad input is an error, not a
  halt.
- An adapter exports its own `BEGIN_SQL`; `transaction` in `db.agc` uses it.
- Tests are BDD-first: behavior is a Gherkin scenario in `specs/*.feature`, run by `agentica test`, not a test file.
  The contract every adapter must meet is in the common features (`opening`, `values`, `queries`, `errors`,
  `transactions`) and by `orm*.feature` for the Orm (its driver ops build the struct `Person` of
  `specs/driver.agc`), each scenario an outline over an `adapter` column (`sqlite`, `postgres`, `mysql`); what only one
  adapter promises is in `sqlite.feature`, `postgres.feature` or `mysql.feature`. The sql of a common scenario runs on
  all three: `create temporary table`, `varchar(50)` where a column is unique, no `cast(? as integer)`, a CTE and
  not a temporary table where a statement reads one table twice. A new behavior is a scenario first. A value written
  must read back unchanged.
- The steps are in `specs/steps.agc`, few and generic (`a "sqlite" database`, `I execute "sql" with:` and a table of
  typed params, `the query "sql" returns:` and a table, `it fails with "prefix"`). They drive `Db` through
  `specs/driver.agc`, a program under test that holds the connection (a step program cannot keep a connection between
  steps), with the requests of `specs/protocol.agc` and the typed cells of `specs/cells.agc`. A table cell is a
  `Value` as text: `Int 31`, `Float -0.25`, `Text ana`, `Blob 0,1,255`, `Bool true`, `Null`, `Repeat 5000 Blob 7`;
  `[NUL]`, `[LF]`, `[TAB]`, `[VT]`, `[FF]`, `[CR]` and `[SP]` stand for characters a cell cannot hold. In a step text,
  `[URL]` is the url of the server of the adapter in the scenario, PostgreSQL or MySQL (`[URL]&name=value` adds a url
  parameter), `[SERVER]` is it without its scheme, `[ADDRESS]` is its host and port only, and `[SCRATCH]` is a folder
  under `tmp/`. A feature that uses a marker says so in its description. A step has a budget of one million VM steps,
  so a `Repeat` cell of more than about 40000 items stops the driver.
- Add a step only when no step can say it. Lines of 119 characters at most, except a step line that holds a long sql.
- A statement that fails must be checked by the next `Then` (`it fails with ...`): the driver refuses any new request
  while the last failure is unchecked, so a failing setup step fails the scenario. The last step of a scenario is a
  `Then`, since nothing comes after it to refuse.
- Scenario names are unique: put a column of the Examples in the title of an outline with several rows.
- `test/*_test.agc` is only for the edge cases of a pure helper that needs no connection and that a scenario would
  say badly: the scanners (`test/postgres_sql_test.agc`, `test/mysql_sql_test.agc`), the url reader
  (`test/mysql_url_test.agc`) and the identifier check of the Orm (`test/orm_dialect_test.agc`). Anything that opens a
  connection is a scenario. A behavior is proven once: a common scenario is an outline with one row per adapter that
  the behavior applies to, not one per variant of the input, and a case a unit test proves is not repeated in a
  feature, except the one integration row per adapter that shows the helper is wired in (a bad url, a NUL in the sql).
- Ruby forms first (`start_with?`, `each`, `Value.Text(...)`); style: `agentica-code-guidelines` of the Agentica
  repository. Lines are at most 119 characters.
- Every user-visible change adds a line under `## [Unreleased]` of `CHANGELOG.md`.
- A line that is only `end` is followed by an empty line, except before another `end`, `else`, `elsif`, a closing `)`
  or `]`, or the end of the file (`[style] blank_line_after_end` in `agentica.toml` makes `agentica check` enforce
  it).
