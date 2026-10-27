## The program under test of the missing-library scenario (see its manifest): it reads a url, opens it with `Db`, and
## answers the error, or `opened`.

import Db from "../../../db"

def main() -> Void
  line = IO.gets
  while line.ok?
    case Db.open(line.unwrap_or(""))
      error(message) -> puts(message)
      ok(conn) ->
        Db.close(conn)
        puts("opened")
    end

    IO.flush()
    line = IO.gets
  end
end
