---
title: MySQL and MariaDB
weight: 7
description: Open a MySQL or MariaDB database through MariaDB Connector/C, the url, TLS, types and limits.
---

The MySQL adapter uses MariaDB Connector/C (`libmariadb.so.3`), which talks to MySQL and MariaDB servers. It is tested with MariaDB 11 and MySQL 8.4. `libmysqlclient` cannot take its place.

```agentica
import Db from "pkg/db/db"

def run() -> Result[Void]
  conn = try Db.open("mysql://user:pass@127.0.0.1:3306/app?connect_timeout=5")
  rows = try Db.query(conn, "select id, name from users where age > ?", [Db.Value.Int(28)])
  puts(rows.size)
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

## The url

The url is `mysql://user:password@host:port/database?parameter=value`, and `mariadb://` is the same.

- The user, the password and the database are percent-decoded: write `p%40ss` for `p@ss`.
- The host is required, the port is 3306 by default, an IPv6 host is `[::1]`, and the database is optional.
- Use an address. The host `localhost` makes the client library use the local socket, which is not where a container listens.
- The parameters are `connect_timeout` (seconds; set it, since an unreachable host otherwise waits as long as the operating system does), `timeout_ms` (the limit of each statement, see [timeouts](#timeouts)) and `ssl_mode`. Any other parameter is an error.

A bad url is `mysql error: <message>`, and the message never repeats a part of the url. A server that does not accept the connection is `mysql error <code>: <message>`, with the code of the client library or the server (`2002` unreachable, `1045` access denied, `1049` unknown database).

## Timeouts

`timeout_ms` (a url parameter, or the `timeout_ms` argument of `Db.query` and `Db.execute`: `-1` takes the connection's, `0` has none) is set on the server, and the adapter reads at `open` which server it is. MySQL gets `max_execution_time`, which limits only a `SELECT`: it fails with `mysql error 3024`. A `DO` or an `INSERT` is not bounded on MySQL. An interrupted `SLEEP()` ends early without an error: `select sleep(5)` on MySQL 8.4, `DO SLEEP(20)` on MariaDB. MariaDB gets `max_statement_time`, which limits every statement: `mysql error 1969`. `Db.timeout?(message)` recognizes both, and the connection works after them. A call with its own limit sets the variable before the statement and puts the connection's back after it (two more round trips, none when the call asks for the limit the connection has; the server's default comes back when the url has no `timeout_ms`). Without `timeout_ms` nothing is bounded.

A url with `timeout_ms` also sets the client read and write timeouts, in whole seconds, to the limit plus 10 seconds, as a backstop for what the server does not time (a `DO` or an `INSERT` on MySQL, a lost network). A statement that hits it fails with `mysql error 2013: Lost connection to server during query` and the connection is gone (`Db.healthy?(conn)` is `false`). The backstop is fixed at `open`, so a call that asks for a limit longer than the url's, `0` included, is cut at the backstop: open with the longer `timeout_ms` for it.

`Db.in_transaction?(conn)` reads the status flag of the last reply from the server, and `Db.healthy?(conn)` pings it.

## TLS

- `?ssl_mode=required` uses TLS and accepts any certificate. It hides the traffic, but it does not prove the server.
- `?ssl_mode=verify&ssl_ca=PATH` uses TLS and checks the certificate against the PEM file of authorities at `PATH`. `verify` without `ssl_ca`, and `ssl_ca` without `verify`, are errors.
- Without `ssl_mode` the library decides, and Connector/C 3.4 connected without TLS. Use `verify` over any network you do not trust.
- A client certificate is not supported.

## Types

| MySQL | `Db.Value` |
|---|---|
| `tinyint`, `smallint`, `mediumint`, `int`, `bigint`, `year`, and the `unsigned` ones that fit an `Int` | `Int` |
| `float`, `double` | `Float` (no NaN or infinity) |
| `boolean` (a `tinyint(1)`) | `Int` |
| `binary`, `varbinary`, the blobs, `bit`, `geometry` | `Blob` |
| NULL | `Null` |
| `char`, `varchar`, the texts, `json`, `enum`, `set` | `Text` |
| `decimal`, `date`, `time`, `datetime`, `timestamp`, a `bigint unsigned` past `Int` | `Text` |

A `Text` parameter goes into a column of any of those types. A `datetime` reads as `2024-02-29 13:14:15`. The connection character set is `utf8mb4`.

## Statements

- Every statement with parameters is prepared and its values are bound. The sql must be one statement; the scanner refuses a second one before the server sees it.
- MySQL does not prepare some statements (`START TRANSACTION`, `BEGIN`, `SAVEPOINT`, `USE`, `LOCK TABLES`). When the server answers `1295` to a statement with no placeholder, the adapter sends it as text. A statement with parameters never does.
- `execute` counts the rows of `INSERT`, `UPDATE`, `DELETE` and `REPLACE` that match. An `INSERT ... ON DUPLICATE KEY UPDATE` or a `REPLACE` over an existing row counts 2. Other statements give 0.
- `CALL` gives its first result set. A `CREATE PROCEDURE` with a body of several statements cannot be sent: create it with the `mysql` client.
- `LOAD DATA LOCAL INFILE` is off, so a server cannot ask for a file of this machine.

## Transactions

A transaction starts with `START TRANSACTION`. They do not nest: `BEGIN` and `START TRANSACTION` fail with `mysql error: a transaction is already in progress` while the server reports one open. See [transactions](/guide/transactions/).

## Connections

The end of the task that opened the connection closes it, or call `Db.close` earlier. `mysql_close` talks to the server and blocks the scheduler while it runs, so open the connection in the task that keeps it. A connection used after `close` is `mysql error: the connection is closed`.

`open`, `query` and `execute` wait for the server on the compute pool, so other tasks keep running. Use a connection from one task at a time, and never close it while a query runs.
