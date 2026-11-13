import Migrate from "../../migrate"

def migration() -> Migrate.Migration
  Migrate.sql(1, "create users", ["create table users (id integer primary key, name text not null)"])
end
