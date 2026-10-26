import MysqlUrl from "../mysql_url"

def target_of(url: String) -> MysqlUrl.Target
  return MysqlUrl.parse(url).unwrap!
end

def refused(url: String, message: String) -> Result[Void]
  return Test.eq(MysqlUrl.parse(url).message, "mysql error: #{message}")
end

def main() -> Void
  Test.run([
    Test.test("a url is read into its parts, and the missing parts take their defaults") do
      found = target_of("mysql://ana:pw@db.example:3307/app?connect_timeout=5&ssl_mode=verify&ssl_ca=%2Fetc%2Fca.pem")
      try Test.eq(found.host, "db.example")
      try Test.eq(found.port, 3307)
      try Test.eq(found.user, "ana")
      try Test.eq(found.password, "pw")
      try Test.eq(found.database, "app")
      try Test.eq(found.timeout, 5)
      try Test.eq(found.ca, "/etc/ca.pem")
      try Test.eq(found.tls, MysqlUrl.Tls.Verify)
      bare = target_of("mariadb://localhost")
      try Test.eq(bare.port, 3306)
      try Test.eq(bare.user, "")
      try Test.eq(bare.database, "")
      try Test.eq(bare.timeout, 0)
      try Test.eq(bare.tls, MysqlUrl.Tls.Default)
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
      try refused("mysql://u:hunter2@h?nope=1",
                  "the url has an unknown parameter, the ones that exist are connect_timeout, ssl_mode and ssl_ca")
      try refused("mysql://u:hunter2@h?ssl_mode=nope", "the url ssl_mode is required or verify")
      try refused("mysql://u:hunter2@h?connect_timeout=x", "the url connect_timeout is not a number of seconds")
      try refused("mysql://u:hunter2@[::1", "the url has an IPv6 host without a closing bracket")
      try refused("mysql://u:hunter2@h?ssl_mode=verify&ssl_ca=x.pem&ssl_mode=required", "the url sets ssl_mode twice")
      return refused("mysql://u:h%00@h", "the url contains a NUL character")
    end,
  ])
end
