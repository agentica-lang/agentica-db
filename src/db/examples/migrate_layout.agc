## One file per migration: `migrations/m0001_create_users.agc` and the ones after it each export `migration()`, and
## `migrations.agc` lists them in order. This program applies the list to an in-memory SQLite database twice, and
## prints the versions each run applied and the user that the third migration inserted.
## `specs/examples.feature` runs this file and checks what it prints.

import Db from "../db"
import Migrate from "../migrate"
import Migrations from "migrations"

def main() -> Void
  case run()
    ok(_) -> puts("done")
    error(message) -> IO.warn(message)
  end
end

def run() -> Result[Void]
  conn = try Db.open("sqlite::memory:")
  puts(try Migrate.up(conn, Migrations.all()))
  puts(try Migrate.up(conn, Migrations.all()))
  rows = try Db.query(conn, "select name from users", [])
  puts(rows.length)
  Db.close(conn)
  ok()
end
