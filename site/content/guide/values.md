---
title: Values
weight: 3
description: The Db.Value type for parameters and columns, and how each database maps to it.
---

`Db.Value` is the one type that crosses the database boundary, for parameters and for result columns. Each adapter turns a variant into the native type of its database.

| Variant | Holds |
|---|---|
| `Db.Value.Null` | NULL |
| `Db.Value.Int(Int)` | an integer |
| `Db.Value.Float(Float)` | a floating point number |
| `Db.Value.Text(String)` | text |
| `Db.Value.Blob(List[Int])` | bytes, each item in 0..255 |
| `Db.Value.Bool(Bool)` | true or false |

`Db` re-exports `Value` and `Row` of `value.agc`, so `import Db from "pkg/db/db"` is enough.

```agentica
import Db from "pkg/db/db"

def main() -> Void
  conn = Db.open("sqlite::memory:").unwrap!
  Db.execute(conn, "create table t (a integer, b real, c text, d blob, e integer)", []).unwrap!
  Db.execute(conn, "insert into t values (?, ?, ?, ?, ?)",
             [Db.Value.Int(7), Db.Value.Float(-0.25), Db.Value.Text("hé"), Db.Value.Blob([0, 1, 255]), Db.Value.Null]).unwrap!
  row = Db.query(conn, "select a, b, c, d, e from t", []).unwrap![0]
  puts(row["a"])
  puts(row["b"])
  puts(row["c"])
  puts(row["d"])
  puts(row["e"])
  Db.close(conn)
end
```

```output
Value.Int(7)
Value.Float(-0.25)
Value.Text("hé")
Value.Blob([0, 1, 255])
Value.Null
```

A value written reads back unchanged, with the exceptions below.

## Types without a variant

A database type with no `Value` variant comes back as `Db.Value.Text`: `numeric`, `date`, `timestamp`, `uuid` and `json` in PostgreSQL, and `decimal`, `date`, `time` and `datetime` in MySQL. A `Text` parameter goes into a column of those types (`'12.50'` into `numeric`).

## Booleans

SQLite has no boolean. `Db.Value.Bool` is stored as 0 or 1, and reads back as `Db.Value.Int`. MySQL does the same, since its `boolean` is a `tinyint(1)`. PostgreSQL has a real boolean and reads back a `Db.Value.Bool`.

## Floats

SQLite stores NaN as NULL. MySQL has no NaN or infinity, so a parameter that is one is a bad input. PostgreSQL keeps `NaN` and `Infinity`. A MySQL `float` column has 32 bits, so `0.1` reads back as `0.10000000149011612`: use `double` for exact decimals.

## Text

A NUL in a text is a bad input on PostgreSQL and MySQL. SQLite binds a text with its length, so a NUL is stored and read back whole.
