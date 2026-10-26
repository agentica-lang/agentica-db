import MysqlUrl from "../mysql_url"

def target_of(url: String) -> MysqlUrl.Target
  return MysqlUrl.parse(url).unwrap!
end

def refused(url: String, message: String) -> Result[Void]
  return Test.eq(MysqlUrl.parse(url).message, "mysql error: #{message}")
end

def main() -> Void
  Test.run([
    Test.test("a full url is read into its parts") do
      found = target_of("mysql://ana:pw@db.example:3307/app?connect_timeout=5&ssl_mode=verify&ssl_ca=%2Fetc%2Fca.pem")
      try Test.eq(found.host, "db.example")
      try Test.eq(found.port, 3307)
      try Test.eq(found.user, "ana")
      try Test.eq(found.password, "pw")
      try Test.eq(found.database, "app")
      try Test.eq(found.timeout, 5)
      try Test.eq(found.ca, "/etc/ca.pem")
      return Test.eq(found.tls, MysqlUrl.Tls.Verify)
    end,
    Test.test("the parts that are missing take their defaults") do
      found = target_of("mariadb://localhost")
      try Test.eq(found.port, 3306)
      try Test.eq(found.user, "")
      try Test.eq(found.password, "")
      try Test.eq(found.database, "")
      try Test.eq(found.timeout, 0)
      try Test.eq(found.tls, MysqlUrl.Tls.Default)
      return Test.eq(target_of("mysql://[::1]:3307/").host, "::1")
    end,
    Test.test("the user, the password and the database are percent-decoded") do
      found = target_of("mysql://we%20ird:p%40ss%3Aw%2Frd%23@h/d%62")
      try Test.eq(found.user, "we ird")
      try Test.eq(found.password, "p@ss:w/rd#")
      try Test.eq(found.database, "db")
      # An `@` that was not encoded belongs to the password.
      return Test.eq(target_of("mysql://u:p@ss@h").password, "p@ss")
    end,
    Test.test("a bad url is an error that repeats no part of it") do
      try refused("mysql://u:hunter2@h:0/d", "the url port is not a number from 1 to 65535")
      try refused("mysql://u:hunter2@h:65536/d", "the url port is not a number from 1 to 65535")
      try refused("mysql://u:hunter2@/d", "the url has no host")
      try refused("mysql://u:hunter2@h/a/b", "the url path has more than one part")
      try refused("mysql://u:h%2@h", "the url has a bad percent escape")
      try refused("mysql://u:%ff@h", "the url has a percent escape that is not UTF-8")
      try refused("mysql://u:hunter2@h?ssl_mode=verify", "the url ssl_mode=verify needs ssl_ca=PATH")
      try refused("mysql://u:hunter2@h?ssl_ca=x.pem", "the url ssl_ca works only with ssl_mode=verify")
      try refused("mysql://u:hunter2@h?ssl_mode=required&ssl_ca=x.pem",
                  "the url ssl_ca works only with ssl_mode=verify")
      return refused("mysql://u:h%00@h", "the url contains a NUL character")
    end,
  ])
end
