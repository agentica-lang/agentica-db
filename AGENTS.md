# agentica-db

One database API for Agentica and one adapter per database, through the C FFI, and for SQLite and PostgreSQL also a
native module of ours (`src/db/native/`, the only C code of the repository, which Agentica builds at the first run; the
FFI driver stays for a run without the built library). The repository
is a workspace (`[workspace]` in the root `agentica.toml`, which only names the members) with two packages in `src/`:

```text
src/db/        package "db" (agentica.toml: the [native.*] tables, [style], the dependency on pool; agentica.lock)
  db.agc       Db: the one API, calls the functions of a Connection (support/connection.agc: a record of the
               functions of one open connection, made by a Driver)
  sqlite.agc, postgres.agc, mysql.agc
               the drivers (`Sqlite.driver()`, ...) that Db.open and DbPool.Options take, each over its adapter: a
               program builds the native modules of the drivers it imports only; sqlite.agc also has the SQLite side
               of a pool (the line of writers, the WAL checkpointer)
  db_pool.agc  DbPool, a pool of Db connections on the generic pool (the `pool` package of agentica-lang/packages,
               `pkg/pool/pool`, in [dependencies]);
               specs/pooling.feature drives it through the pool_* ops of specs/driver.agc
  orm.agc      a typed layer over Db (plain structs in and out, always bound ? parameters); it takes a
               Db.Connection and never touches an adapter
  migrate.agc  the migrations runner (Migrate.up), also over Db
  sqlite/      sqlite.agc (the adapter: picks a driver, the settings, timeouts), native.agc (the driver over the
               native module), ffi.agc (the driver over extern calls), wait.agc (the wait for a lock, shared),
               url.agc (the parameters of the url), lock.agc (the lock rule)
  native/      db_sqlite.c and db_postgres.c, the native modules ([native.db_sqlite] and [native.db_postgres]
               build): each opens the system library itself (dlopen), so a build needs only a C compiler;
               specs/statement_cache.feature, specs/sqlite_writes.feature (short writes, the checkpointer of a
               pool) and specs/postgres_native.feature (tag @native)
  postgres/    postgres.agc (the adapter: picks a driver, timeouts), native.agc (the driver over the native module),
               ffi.agc (the driver over extern calls), statement.agc (the checks both drivers make), sql.agc (the
               placeholder scanner), url.agc (it takes the parameters of the adapter out of the url before libpq
               sees it)
  mysql/       mysql.agc (the adapter: picks a driver, timeouts), ffi.agc (the driver over extern calls),
               statement.agc (what a driver reads of a verb), sql.agc (the statement scanner), url.agc
  orm/         build.agc (the sql of the query builder), codec.agc (row to JSON.Value for T.codec), dialect.agc
               (identifier names and quotes), errors.agc
  support/     value.agc (Value, Row; db.agc re-exports them), connection.agc (Connection, Driver, CacheStats and
               the pool types; db.agc re-exports them), milliseconds.agc (the timeout_ms and
               busy_timeout numbers of the url readers)
  examples/    users.agc, a runnable web-handler style example of the Orm; migrate_layout.agc, with migrations.agc
               and migrations/ (one file per migration), the layout of the Migrations guide;
               specs/examples.feature runs both
  specs/ test/ the features and the unit tests of the package
src/properties/ package "properties": the property-based tests (prop), not published. It depends on db as a
               workspace member, so what users of `pkg/db/db` download does not include prop.
               value_gens.agc (generators of the typed cells), store.agc (a row through SQLite, PostgreSQL or MySQL
               against what the database holds), pool_model.agc (random sequences on a pool of fake resources),
               sqlite_scanners.agc (the statement scanners of the native SQLite driver); test/ has the properties
site/ tools/   the documentation site (Hugo) and the check of its samples
```

A user's import path is the file path inside the package, so `import Db from "pkg/db/db"` loads `src/db/db.agc`: the
dependency says `subdir = "src/db"`. Moving a file other than the modules at the root of `src/db` (`db`, `db_pool`,
`orm`, `migrate`, `sqlite`, `postgres`, `mysql`) does not change the documented imports of users; moving one of those
does. The pool is not in
this repository: `src/db` and `src/properties` depend on the `pool` package of agentica-lang/packages at a tag
(`pool-X.Y.Z`, `subdir = "pool"`), and both name the same tag (one name stands for one source in a build). To move to a
new release of it, change the tag in both manifests and run `agentica update pool` in both folders.

## Commands

- Binary: developing and testing the package needs Agentica 0.31.0 or later and a C compiler
  (`cc`, or `CC`); the minimum for a project that uses the package is the one in the README. Download a release
  under `.tools/` (gitignored), never `/tmp`. CI builds Agentica at the commit `AGENTICA_COMMIT` of
  `.github/workflows/ci.yml`, the one of the tag 0.31.0 (`.github/actions/agentica`); a version bump sets it
  to the commit of the new tag.
- SQLite runs on the native driver when its module builds; `AGENTICA_DB_SQLITE_DRIVER=ffi agentica test --only "on
  sqlite" --tags "not @native"` runs the SQLite scenarios on the FFI driver. PostgreSQL the same, with
  `AGENTICA_DB_POSTGRES_DRIVER=ffi`. CI runs every scenario of both on both drivers (`native`, then `ffi` with `--tags
  "not @native"`; MySQL and MariaDB have the FFI driver only until #77), naming the driver in the variable so that a
  run cannot fall back to the other one; `specs/driver_choice.feature` fails when the connection runs another driver
  than the variable names. A C change: C11, every return code of the library checked, every statement, result and
  connection freed exactly once, also on the error paths; a free function never waits (no lock that a call holds, no
  socket I/O that can block).
- Run these in `src/db` (the package folder; at the root only `make check`, `agentica check` and `agentica fmt --check
  src` work, and `agentica test` there fails with `CHECK-BDD-EMPTY`; `agentica test` finds `specs/steps.agc` by
  itself). `agentica install` first (it writes the pool package of the lock into `deps/`, gitignored). `make check`
  (from the root) runs it and `agentica check *.agc sqlite postgres mysql support orm examples specs test` there, which
  is every `.agc` file of the package. `make fmt-check` (from the root, as CI) runs `agentica fmt --check` on the same
  paths (`agentica fmt` fixes them), then `agentica test`: the features of `specs/` and the unit tests of `test/`.
  SQLite needs no server. `--only TEXT` keeps the scenarios and tests whose name contains `TEXT`. CI runs
  `agentica test --jobs 4` (four scenarios at once, also of one file), so a scenario must not share a path, a port or a
  table with another: `[SCRATCH]` is a folder of its own for each scenario, and a scenario on a server names its own
  tables or makes them temporary.
- The properties package has the same commands in `src/properties` (`agentica install` first, which fetches prop and
  pool into `deps/`; then `agentica check *.agc test`, `agentica fmt --check *.agc test` and `agentica test`). A
  property is a `test_` function of `test/*_test.agc` that calls `Prop.check` or one of its laws (`Prop.oracle`, ...)
  with 100 runs (the pool ones 40, since a case takes real time); a failure prints the seed and the shrunk case, and
  `Prop.Config(seed: some(N))` or `agentica --seed N test` replays it. `test/values_test.agc` is the one that runs on
  both drivers (CI runs it with each variable); the scanners read the statement cache of the native SQLite driver, so
  they run on the native run only. Names of the SQLite properties have "on sqlite" like the scenarios. A test has a
  budget of about 2.5 million VM steps and 30 seconds, and a generated value costs about 200 steps for each item, so
  keep sizes small and split a property before raising its runs. A counterexample that a property finds becomes a
  scenario of `src/db/specs` (the cells it prints are the cells of the tables) before the fix.
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
- An adapter keeps its `extern` block private (below the `private` line, since a block is public or private as a
  whole) and makes public only the wrapper: the FFI drivers name their resource `RawHandle` and give `Handle` as a
  type alias, with a public wrapper for each raw call that `sqlite.agc` makes (SQLite's drivers also have a few more
  public calls; `sqlite.agc` alone is the adapter) (`wrapping` guide of the Agentica site:
  `library/io-and-system/native/wrapping`). An adapter has the same functions as `db.agc`:
  `open`, `close`, `query`, `execute` (both take a last `timeout_ms`, -1 for the connection's), `in_transaction?`,
  `connected?` and `healthy?` (SQLite also has `interrupt`, for the pool only). Its driver (`sqlite.agc`,
  `postgres.agc`, `mysql.agc` at the root) wraps them in a `Connection` record; `db.agc` calls the record and imports
  no adapter, so a program builds only the native modules of the drivers it imports; `transaction` stays in `db.agc`.
  `db.agc` also re-exports `Value` and `Row` of `support/value.agc` (`export V.Value`), so a user imports `Db` only.
  The connection of each adapter is a native resource (`sqlite3_close_v2`, `PQfinish`, `mysql_close`): the end of the
  task or of `main` closes it, and `Native.closed?` turns a use after `close` into an error (SQLite keeps the runtime
  error). `open` calls `Native.load` before touching the library, so a missing library is an `error`.
- Placeholders are `?` in the API. An adapter translates them (`$1` for PostgreSQL; MySQL takes `?` natively) and
  always binds (`mysql_stmt_*` for MySQL); no value is ever spliced into sql.
- A failure is `error(message)` in one of two shapes: an engine failure `<adapter> error <code>: <message>`, a
  bad input `<adapter> error: <message>`; the module's own `db error: <message>`. A bad input is an error, not a
  halt.
- An adapter exports its own `BEGIN_SQL`; its driver puts it in `Connection.begin_sql`, which `transaction` uses.
- Tests are BDD-first (the paths below are in `src/db`): behavior is a Gherkin scenario in `specs/*.feature`, run by
  `agentica test`, not a test file. The contract every adapter must meet is in the common features (`opening`,
  `values`, `queries`, `errors`, `transactions`) and by `orm*.feature` for the Orm (its driver ops build the struct
  `Person` of `specs/driver.agc`, with an `Optional` age, or `Partial`, the same with a `JSON.Field` age), each scenario
  an outline over an `adapter` column (`sqlite`, `postgres`, `mysql`); what only one adapter promises is in
  `sqlite.feature`, `postgres.feature` or `mysql.feature`. The sql of a common scenario runs on all three:
  `create temporary table`, `varchar(50)` where a column is unique, no `cast(? as integer)`, a CTE and not a temporary
  table where a statement reads one table twice. A new behavior is a scenario first. A value written must read back
  unchanged.
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
  and the identifier check of the Orm (`test/orm_dialect_test.agc`), and `test/migrations_layout_test.agc` (it opens no
  connection: it checks the list of `examples/migrations.agc` against its folder, as the guide teaches). Anything that
  opens a connection is a scenario. A behavior is proven once: a common scenario is an outline with one row per
  adapter that the behavior applies to, not one per variant of the input, and a case a unit test proves is not
  repeated in a feature, except the one integration row per adapter that shows the helper is wired in (a bad url, a
  NUL in the sql).
- Ruby forms first (`start_with?`, `each`, `Value.Text(...)`); style: `agentica-code-guidelines` of the Agentica
  repository. Lines are at most 119 characters.
- Every user-visible change adds a line under `## [Unreleased]` of `CHANGELOG.md`.
- At a release, replace the `TAG` placeholder of the install lines (README.md, site/content/_index.md,
  site/content/getting-started.md) with the new tag.
- A line that is only `end` is followed by an empty line, except before another `end`, `else`, `elsif`, a closing `)`
  or `]`, or the end of the file (`[style] blank_line_after_end` in `agentica.toml` makes `agentica check` enforce
  it).
