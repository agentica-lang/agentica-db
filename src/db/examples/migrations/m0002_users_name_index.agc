import Migrate from "../../migrate"

export def migration() -> Migrate.Migration
  Migrate.sql(2, "users name index", ["create unique index users_name on users (name)"])
end
