import Migrate from "../../migrate"

export def migration() -> Migrate.Migration
  Migrate.sql(1, "create users", ["create table users (id integer primary key, name text not null)"])
end
