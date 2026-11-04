## The list of the migrations of `migrations/`, oldest first. A new file is added here, and the test of the layout
## (`test/migrations_layout_test.agc`) fails when it is not.

import Migrate from "../migrate"
import CreateUsers from "migrations/m0001_create_users"
import UsersNameIndex from "migrations/m0002_users_name_index"
import FirstUser from "migrations/m0003_first_user"

export def all() -> List[Migrate.Migration]
  return [CreateUsers.migration(), UsersNameIndex.migration(), FirstUser.migration()]
end
