## A program that passes only the SQLite driver: it reads a url, opens it with `Db`, and answers the error, or
## `opened`. It imports no other driver, so a build of it makes only the native SQLite module.

import Db from "../../db"
import Sqlite from "../../sqlite"

private

def main() -> Void
  line = IO.gets
  while line.ok?
    case Db.open(line.unwrap_or(""), [Sqlite.driver()])
      error(message) -> puts(message)
      ok(conn) ->
        Db.close(conn)
        puts("opened")
    end

    IO.flush()
    line = IO.gets
  end
end
