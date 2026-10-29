---
title: Testing
weight: 13
description: Test your code against in-memory SQLite, and run the tests of agentica-db.
---

## Your code

Write a function that takes a `Db.Connection` instead of opening one. A test then passes a `sqlite::memory:` connection: it needs no server, it is private to the test, and it vanishes when it closes.

```agentica
import Db from "pkg/db/db"

def adults(conn: Db.Connection, min_age: Int) -> Result[Int]
  rows = try Db.query(conn, "select name from users where age >= ?", [Db.Value.Int(min_age)])
  return ok(rows.size)
end

def main() -> Void
  conn = Db.open("sqlite::memory:").unwrap!
  Db.execute(conn, "create table users (name text not null, age integer)", []).unwrap!
  Db.execute(conn, "insert into users (name, age) values ('Ana', 31), ('Bob', 17)", []).unwrap!
  puts(adults(conn, 18).unwrap!)
  Db.close(conn)
end
```

```output
1
```

SQLite is not PostgreSQL or MySQL, so keep the sql portable (`?` placeholders, `create temporary table`, no vendor functions) if the same code runs on another database in production, and run your own suite against that database in CI too.

## The tests of agentica-db

The behavior of the API is written as Gherkin scenarios in `specs/`, and `agentica test` runs them. Read them as the specification. The features hold the contract that every adapter meets (opening, values, queries, errors, transactions) as outlines with one row per database, and the Orm has its own features. Only the edge cases of the pure helpers, the sql scanners, the url reader and the identifier check, have unit tests in `test/`.

```sh
make check
agentica test
```

`make check` runs `agentica check` on every `.agc` file. `agentica test` runs the features and the unit tests.

- SQLite needs no server. Without a PostgreSQL or MySQL server run only the SQLite scenarios, which have "on sqlite" in their name: `agentica test --only "on sqlite"`.
- The PostgreSQL scenarios read `AGENTICA_DB_POSTGRES_URL`, and the MySQL ones read `AGENTICA_DB_MYSQL_URL`. Without the variable they fail: no scenario is skipped.
- The scenarios use temporary tables, so they leave nothing behind.

A local server for each, with Docker:

```sh
docker run -d --rm --name agentica-db-pg -e POSTGRES_PASSWORD=pw -p 127.0.0.1:55432:5432 postgres:17
AGENTICA_DB_POSTGRES_URL='postgres://postgres:pw@127.0.0.1:55432/postgres?sslmode=disable' agentica test
docker stop agentica-db-pg

docker run -d --rm --name agentica-db-mysql -e MARIADB_ROOT_PASSWORD=pw -p 127.0.0.1:53306:3306 mariadb:11
AGENTICA_DB_MYSQL_URL='mysql://root:pw@127.0.0.1:53306/mysql' agentica test
docker stop agentica-db-mysql
```

The MySQL url has an address and not `localhost`, because the client library takes `localhost` for the local socket. CI runs the whole suite against MariaDB 11 and MySQL 8.4, since the two servers differ. On macOS (arm64 and x86_64) and Windows it runs the SQLite scenarios only, with `agentica test --only "on sqlite"`, because a service container needs Linux.

The site samples are checked too: `make site-samples` runs `agentica check` on every `agentica` block of this site, and runs the ones that show their output.
