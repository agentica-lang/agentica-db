---
title: agentica-db
description: A database package for Agentica. One API for SQLite, PostgreSQL and MySQL or MariaDB, and a small typed ORM.
---

agentica-db is a database package for [Agentica](https://agentica-lang.github.io/agentica/). One API, `Db`, opens SQLite, PostgreSQL and MySQL or MariaDB, runs queries with bound parameters, and runs transactions. A small layer on top, `Orm`, reads rows into plain structs.

Each database is reached through its system client library, by the C FFI. The package has no C code of its own.

Add it to the `agentica.toml` of your project:

```toml
[dependencies]
db = { git = "https://github.com/agentica-lang/agentica-db", tag = "0.1.0" }
```

Or run `agentica add db https://github.com/agentica-lang/agentica-db --tag 0.1.0`. [Getting started](/getting-started/) has the details.

A first program, on a private in-memory SQLite database:

```agentica
import Db from "pkg/db/db"

def main() -> Void
  conn = Db.open("sqlite::memory:").unwrap!
  Db.execute(conn, "create table users (name text not null, age integer)", []).unwrap!
  Db.execute(conn, "insert into users (name, age) values (?, ?)", [Db.Value.Text("Ana"), Db.Value.Int(31)]).unwrap!
  rows = Db.query(conn, "select name, age from users where age > ?", [Db.Value.Int(28)]).unwrap!
  puts(rows)
  Db.close(conn)
end
```

```output
[{"name": Value.Text("Ana"), "age": Value.Int(31)}]
```

- [Getting started](/getting-started/) installs the package and shows the system libraries it needs.
- The [guide](/guide/) has a page for each part: connecting, queries, values, transactions, the three databases, the ORM and testing.
- The source and the changelog are [on GitHub](https://github.com/agentica-lang/agentica-db).

Not yet: migrations, a connection pool and preloading of related rows.

agentica-db needs Agentica 0.16.0 or later, and is under the Apache License 2.0.
