import Db from "../../db"
import Migrate from "../../migrate"

export def migration() -> Migrate.Migration
  return Migrate.code(3, "first user", &first_user)
end

def first_user(tx: Db.Connection) -> Result[Void]
  try Db.execute(tx, "insert into users (name) values (?)", [Db.Value.Text("ana")])
  return ok()
end
