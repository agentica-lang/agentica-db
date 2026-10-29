---
title: Transactions
weight: 4
description: Db.transaction commits when the block gives ok and rolls back when it gives error.
---

`Db.transaction(conn) do |tx| ... end` runs the block between the `BEGIN` and the `COMMIT` of the database. It gives a `Result[R]`, where `R` is the type of the block's `ok` value.

- The block gives `ok(value)`: the transaction commits and the call gives `ok(value)`.
- The block gives `error(message)`, or the commit fails: the transaction rolls back and the call gives that error. If the rollback fails too, its message is added after a semicolon.

Use the `tx` the block receives, not the outer connection, for the statements of the transaction.

```agentica
import Db from "pkg/db/db"

def save(conn: Db.Connection, name: String) -> Result[Int]
  return Db.execute(conn, "insert into users (name) values (?)", [Db.Value.Text(name)])
end

def count(conn: Db.Connection) -> Result[Int]
  rows = try Db.query(conn, "select count(*) as n from users", [])
  case rows[0]["n"]
    Db.Value.Int(n) -> return ok(n)
    _ -> return error("no count")
  end
end

def run() -> Result[Void]
  conn = try Db.open("sqlite::memory:")
  try Db.execute(conn, "create table users (name text not null unique)", [])
  saved = try Db.transaction(conn) do |tx|
    save(tx, "Ana")
  end

  puts(saved)
  failed = Db.transaction(conn) do |tx|
    try save(tx, "Bob")
    try save(tx, "Ana")
    ok()
  end

  puts(failed.ok?)
  puts(try count(conn))
  Db.close(conn)
  return ok()
end

def main() -> Void
  case run()
    ok(_) -> puts("done")
    error(message) -> IO.warn(message)
  end
end
```

```output
1
false
1
done
```

The second transaction saves "Bob" and then fails on the duplicate "Ana", so "Bob" is rolled back too.

## Rules

- Transactions do not nest. On PostgreSQL a second `BEGIN` is `postgres error 25001`, and on MySQL it is `mysql error: a transaction is already in progress`.
- A runtime error (a halt) inside the block stops the task and leaves the transaction open. Closing the connection rolls it back, which the end of the task does.
- On PostgreSQL a statement that fails aborts the transaction. A `COMMIT` after that would roll back without an error, so the package turns it into `postgres error 25P02`, and `transaction` gives that error.
- On MySQL a statement that fails does not abort the transaction, but `Db.transaction` rolls back because the block returned the error. A DDL statement (`create table`, `drop table`) commits the transaction before it runs, as MySQL does.
- SQLite starts with `BEGIN IMMEDIATE`, which needs write access to the database. A read-only database cannot open a transaction.
- A block whose only result is `error(...)` does not infer `R`. Give it a type: `failed: Result[Void] = error("x")`, then return `failed`.
