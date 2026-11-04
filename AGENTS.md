# agentica-db

One database API for Agentica (`db.agc`, `value.agc`) and one adapter per database (`sqlite.agc` with its url reader
`sqlite_url.agc` and its lock rule `sqlite_lock.agc`, `postgres.agc` with its placeholder scanner `postgres_sql.agc`
and its url reader `postgres_url.agc` (it takes `timeout_ms` out of the url before libpq sees it), `mysql.agc` with
its statement scanner `mysql_sql.agc` and its url reader `mysql_url.agc`), all through the C FFI. No C code of ours.
`milliseconds.agc` reads the `timeout_ms` and `busy_timeout` numbers of their url readers. `orm.agc` is a typed layer
over `Db` (plain structs in and out, always bound `?` parameters) with
`orm/codec.agc` (row to Json for `JSON.codec`), `orm/build.agc` (the sql of the query builder) and `orm/dialect.agc`
(identifier names and quotes); it takes a `Db.Connection` and never touches an adapter. `examples/users.agc` is a
runnable web-handler style example of the Orm; `specs/examples.feature` runs it and checks its output. `migrate.agc` is
the migrations runner (`Migrate.up`), also over `Db`, with `specs/migrations.feature`.
`db_pool.agc` is `DbPool`, a pool of `Db` connections on the generic pool of `pool/` (`pkg/pool/pool`, declared in
`[dependencies]`); `specs/pooling.feature` drives it through the `pool_*` ops of `specs/driver.agc`.

The repository is a workspace (`[workspace]` in `agentica.toml`): `pool/` is a member, a generic pool of resources
(`pool/pool.agc`, `import Pool from "pkg/pool/pool"`) with its own `agentica.toml`, no native library, no import of
`db`, and its own `specs/` and `test/`. A package of the repository that uses it
declares `subdir = "pool"` like any user, and the workspace reads it from its folder.

## Commands

- Binary: the release pinned in `.github/workflows/ci.yml` (`AGENTICA_VERSION`, with its sha256). Download it
  under `.tools/` (gitignored), never `/tmp`. A version bump changes `AGENTICA_VERSION`, `AGENTICA_SHA256` and the
  three `sha256` of the `sqlite` matrix (macOS and Windows), all from the SHA256SUMS of the Agentica release.
- `make check` (`agentica check *.agc orm examples specs test`: every `.agc` file of the package),
  `agentica fmt --check *.agc orm examples specs test` (CI runs it; `agentica fmt` on the same paths fixes it), then
  `agentica test`: the features of `specs/` (it finds `specs/steps.agc` by itself) and
  the unit tests of `test/`. SQLite needs no server. `--only TEXT` keeps the scenarios and tests whose name contains
  `TEXT`.
- The pool member has the same three commands in its folder (`cd pool`: `agentica check *.agc specs test`,
  `agentica fmt --check *.agc specs test`, `agentica test`); `make check` runs the check. Its features use a fake
  resource (`pool/specs/driver.agc`), so they need no server.
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
  site: `library/io-and-system/native/wrapping`). An adapter has the same functions as `db.agc`:
  `open`, `close`, `query`, `execute` (both take a last `timeout_ms`, -1 for the connection's), `in_transaction?` and
  `healthy?`. `db.agc` dispatches on `Connection`; `transaction` stays in `db.agc`.
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
  `transactions`) and by `orm*.feature` for the Orm (its driver ops build the struct `Person` of `specs/driver.agc`,
  with an `Optional` age, or `Partial`, the same with a `JsonField` age), each scenario an outline over an `adapter`
  column (`sqlite`, `postgres`, `mysql`); what only one adapter promises is in `sqlite.feature`, `postgres.feature` or
  `mysql.feature`. The sql of a common scenario runs on all three: `create temporary table`, `varchar(50)` where a
  column is unique, no `cast(? as integer)`, a CTE and not a temporary table where a statement reads one table twice. A
  new behavior is a scenario first. A value written must read back unchanged.
- The steps are in `specs/steps.agc`, few and generic (`a "sqlite" database`, `I execute "sql" with:` and a table of
  typed params, `the query "sql" returns:` and a table, `it fails with "prefix"`). They drive `Db` through
  `specs/driver.agc`, a program under test that holds the connection (a step program cannot keep a connection between
  steps), with the requests of `specs/protocol.agc` and the typed cells of `specs/cells.agc`. A table cell is a
  `Value` as text: `Int 31`, `Float -0.25`, `Text ana`, `Blob 0,1,255`, `Bool true`, `Null`, `Repeat 5000 Blob 7`;
  `[NUL]`, `[LF]`, `[TAB]`, `[VT]`, `[FF]`, `[CR]` and `[SP]` stand for characters a cell cannot hold. In a step text,
  `[URL]` is the url of the server of the adapter in the scenario, PostgreSQL or MySQL (`[URL]&name=value` adds a url
  parameter), `[SERVER]` is it without its scheme, `[ADDRESS]` is its host and port only, `[SCRATCH]` is a folder
  under `tmp/`, `[SLOW]` is a statement of the adapter that runs for many seconds and `[WORK]` one that works for about
  half a second and gives the row `n = 1` (`specs/timeouts.feature`). A feature that uses a marker says so in its
  description. A step has a budget of one million VM steps, so a `Repeat` cell of more than about 40000 items stops
  the driver.
- Add a step only when no step can say it. Lines of 119 characters at most, except a step line that holds a long sql.
- A statement that fails must be checked by the next `Then` (`it fails with ...`): the driver refuses any new request
  while the last failure is unchecked, so a failing setup step fails the scenario. The last step of a scenario is a
  `Then`, since nothing comes after it to refuse.
- Scenario names are unique: put a column of the Examples in the title of an outline with several rows.
- `test/*_test.agc` is only for the edge cases of a pure helper that needs no connection and that a scenario would say
  badly: the scanners (`test/postgres_sql_test.agc`, `test/mysql_sql_test.agc`), the url readers
  (`test/mysql_url_test.agc`, `test/postgres_url_test.agc`, `test/sqlite_url_test.agc`), the timeout messages
  (`test/db_test.agc`), the lock rule of SQLite (`test/sqlite_lock_test.agc`)
  and the identifier check of the Orm (`test/orm_dialect_test.agc`). Anything that opens a connection is a scenario. A
  behavior is proven once: a common scenario is an outline with one row per adapter that the behavior applies to, not
  one per variant of the input, and a case a unit test proves is not repeated in a feature, except the one integration
  row per adapter that shows the helper is wired in (a bad url, a NUL in the sql).
- Ruby forms first (`start_with?`, `each`, `Value.Text(...)`); style: `agentica-code-guidelines` of the Agentica
  repository. Lines are at most 119 characters.
- Every user-visible change adds a line under `## [Unreleased]` of `CHANGELOG.md`.
- A line that is only `end` is followed by an empty line, except before another `end`, `else`, `elsif`, a closing `)`
  or `]`, or the end of the file (`[style] blank_line_after_end` in `agentica.toml` makes `agentica check` enforce
  it).
