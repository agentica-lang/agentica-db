## Reads a `mysql://` or `mariadb://` url into the arguments of the connection.
##
## `mysql://user:password@host:3306/database?connect_timeout=5`. The user, the password and the database are
## percent-decoded (`%40` is `@`), so a password may hold any character. The host is required (`localhost` uses
## the local socket of the client library); an IPv6 host is written `[::1]`. The parameters are
## `connect_timeout`, in seconds, and `ssl_mode`: `required` (use TLS, whatever the certificate) or `verify` (use
## TLS and let the client library check the certificate). Without `ssl_mode` the client library decides. An error
## names the problem and never repeats any part of the url, since a url holds a password.

SCHEMES = ["mysql://", "mariadb://"]
DEFAULT_PORT = 3306
MAX_PORT = 65535
HEX_BASE = 16
PERCENT = 37
DIGIT_ZERO = 48
DIGIT_NINE = 57
UPPER_A = 65
UPPER_F = 70
LOWER_A = 97
LOWER_F = 102
LETTER_OFFSET = 10

## The TLS mode of a connection: what the client library does by default, TLS with any certificate, or TLS with a
## certificate that the system authorities vouch for.
export enum Tls
  Default
  Required
  Verify
end

## Where and how to connect. An empty `user` is the user of the process, and an empty `database` selects none.
export struct Target
  host: String
  port: Int
  user: String
  password: String
  database: String
  timeout: Int = 0
  tls: Tls = Tls.Default
end

struct Address
  host: String
  port: Int
end

struct Options
  timeout: Int
  tls: Tls
end

## Reads the url. An error is `mysql error: <message>`.
export def parse(url: String) -> Result[Target]
  if url.include?(String.from_code(0))
    return error("mysql error: the url contains a NUL character")
  end

  scheme = SCHEMES.find do |prefix| url.start_with?(prefix) end.unwrap_or("")
  rest = url.slice(scheme.length, url.length - scheme.length)
  halves = split_once(rest, "?")
  options = try read_query(halves[1])
  parts = split_once(halves[0], "/")
  database = try decode(parts[1])
  if database.include?("/")
    return error("mysql error: the url path has more than one part")
  end

  # The password may hold an `@` that was not encoded: the host starts after the last one.
  at = last_index(parts[0], "@")
  userinfo = parts[0].slice(0, max_zero(at))
  login = split_once(userinfo, ":")
  user = try decode(login[0])
  password = try decode(login[1])
  address = try read_address(parts[0].slice(at + 1, parts[0].length - at - 1))
  if [user, password, database].any? do |part| part.include?(String.from_code(0)) end
    return error("mysql error: the url contains a NUL character")
  end

  return ok(Target(host: address.host, port: address.port, user: user, password: password, database: database,
                   timeout: options.timeout, tls: options.tls))
end

# The text before the first `separator` and the text after it (empty when there is none).
def split_once(text: String, separator: String) -> List[String]
  found = text.index_of(separator)
  case found
    ok(at) -> return [text.slice(0, at), text.slice(at + 1, text.length - at - 1)]
    error(_) -> return [text, ""]
  end
end

# The index of the last `separator`, or -1.
def last_index(text: String, separator: String) -> Int
  last = -1
  parts = text.split(separator)
  if parts.size > 1
    last = text.length - parts[parts.size - 1].length - separator.length
  end

  return last
end

def max_zero(n: Int) -> Int
  if n < 0
    return 0
  end

  return n
end

def read_address(text: String) -> Result[Address]
  if text.empty?
    return error("mysql error: the url has no host")
  end

  if text.start_with?("[")
    return read_ipv6(text)
  end

  halves = split_once(text, ":")
  if halves[0].empty?
    return error("mysql error: the url has no host")
  end

  port = try read_port(halves[1], text.include?(":"))
  return ok(Address(host: halves[0], port: port))
end

# `[::1]` or `[::1]:3306`.
def read_ipv6(text: String) -> Result[Address]
  closing = text.index_of("]")
  case closing
    error(_) -> return error("mysql error: the url has an IPv6 host without a closing bracket")
    ok(at) ->
      after = text.slice(at + 1, text.length - at - 1)
      host = text.slice(1, at - 1)
      if host.empty?
        return error("mysql error: the url has no host")
      end

      if after.empty?
        return ok(Address(host: host, port: DEFAULT_PORT))
      end

      if not after.start_with?(":")
        return error("mysql error: the url port is not a number from 1 to #{MAX_PORT}")
      end

      port = try read_port(after.slice(1, after.length - 1), true)
      return ok(Address(host: host, port: port))
  end
end

def read_port(text: String, given: Bool) -> Result[Int]
  if not given
    return ok(DEFAULT_PORT)
  end

  number = digits(text)
  if not number.ok? or text.length > 5 or number.unwrap_or(0) < 1 or number.unwrap_or(0) > MAX_PORT
    return error("mysql error: the url port is not a number from 1 to #{MAX_PORT}")
  end

  return number
end

# A non-empty run of ASCII digits as an Int.
def digits(text: String) -> Result[Int]
  bytes = text.to_bytes
  if bytes.empty? or bytes.any? do |byte| byte < DIGIT_ZERO or byte > DIGIT_NINE end
    return error("not a number")
  end

  return text.to_i
end

# The parameters of the url: the connect timeout in seconds (0 when the url sets none) and the TLS mode.
def read_query(query: String) -> Result[Options]
  options = Options(timeout: 0, tls: Tls.Default)
  if query.empty?
    return ok(options)
  end

  for pair in query.split("&")
    halves = split_once(pair, "=")
    if halves[0] == "connect_timeout"
      seconds = digits(halves[1])
      if not seconds.ok? or halves[1].length > 5
        return error("mysql error: the url connect_timeout is not a number of seconds")
      end

      options = options.with(timeout: seconds.unwrap_or(0))
    elsif halves[0] == "ssl_mode" and halves[1] == "required"
      options = options.with(tls: Tls.Required)
    elsif halves[0] == "ssl_mode" and halves[1] == "verify"
      options = options.with(tls: Tls.Verify)
    elsif halves[0] == "ssl_mode"
      return error("mysql error: the url ssl_mode is required or verify")
    else
      return error("mysql error: the url has an unknown parameter, the ones that exist are connect_timeout " +
                     "and ssl_mode")
    end
  end

  return ok(options)
end

# Decodes `%XX` escapes into bytes, which must make UTF-8.
def decode(text: String) -> Result[String]
  if not text.include?("%")
    return ok(text)
  end

  bytes = text.to_bytes
  out: List[Int] = []
  at = 0
  while at < bytes.size
    if bytes[at] == PERCENT
      high = hex_value(bytes, at + 1)
      low = hex_value(bytes, at + 2)
      if high < 0 or low < 0
        return error("mysql error: the url has a bad percent escape")
      end

      out = out.push(high * HEX_BASE + low)
      at += 3
    else
      out = out.push(bytes[at])
      at += 1
    end
  end

  decoded = String.from_bytes(out)
  if not decoded.ok?
    return error("mysql error: the url has a percent escape that is not UTF-8")
  end

  return decoded
end

# The value of the hex digit at `at`, or -1 when there is none.
def hex_value(bytes: List[Int], at: Int) -> Int
  if at >= bytes.size
    return -1
  end

  byte = bytes[at]
  if byte >= DIGIT_ZERO and byte <= DIGIT_NINE
    return byte - DIGIT_ZERO
  elsif byte >= UPPER_A and byte <= UPPER_F
    return byte - UPPER_A + LETTER_OFFSET
  elsif byte >= LOWER_A and byte <= LOWER_F
    return byte - LOWER_A + LETTER_OFFSET
  end

  return -1
end
