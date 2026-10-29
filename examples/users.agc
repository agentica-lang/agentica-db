## A small users API in the style of a web handler: each route is a function from an `HttpRequest` to an
## `HttpResponse`, and the database goes in as an argument. It uses the Orm for everything: a schema, `check`,
## `insert`, `find`, the query builder, `patch`, `delete` and a transaction that gives back a value.
##
## It runs on its own against an in-memory SQLite database and prints each request with its response, so no server
## is needed. To serve it, open the connection in `main` and hand `HTTP.listen` a block that calls
## `handle(conn, schema, request)`. A real app adds more: a 405 with an `Allow` header, a cap on the size of an import,
## and URL decoding of the query.
## `specs/examples.feature` runs this file and checks what it prints.

import Db from "../db"
import Orm from "../orm"

CREATE_USERS = "create table users (id integer primary key, name text not null unique, age integer)"
# A list never has more rows than this: a real API would page it with an offset.
LIST_LIMIT = 100

# A column that can be NULL is a `JsonField`: a NULL reads as `JsonField.Null`, and an age that was not sent is
# `Absent`, which an insert leaves out (the column takes its default, NULL here).
struct User
  id: Int = 0
  name: String
  age: JsonField[Int]
end

# The body of a POST: the same fields without the key.
struct NewUser
  name: String
  age: JsonField[Int]
end

struct Batch
  users: List[NewUser]
end

def main() -> Void
  case run()
    ok(_) -> IO.flush()
    error(message) ->
      IO.warn(message)
      System.exit(1)
  end
end

# The routes: the method and the parts of the path (`/users/7` is ["", "users", "7"]).
def handle(conn: Db.Connection, schema: Orm.Schema[User], request: HttpRequest) -> HttpResponse
  parts = request.path.split("/")
  if parts.size == 2 and parts[1] == "users"
    case request.method
      "POST" -> return create(conn, schema, request.body)
      "GET" -> return list(conn, schema, request.target)
      _ -> return failure(405, "method not allowed")
    end
  end

  if parts.size == 3 and parts[1] == "users" and parts[2] == "import" and request.method == "POST"
    return import_users(conn, schema, request.body)
  end

  if parts.size == 3 and parts[1] == "users"
    case parts[2].to_i
      error(_) -> return failure(404, "no such user")
      ok(id) -> return user_route(conn, schema, request, id)
    end
  end

  return failure(404, "no such route")
end

def user_route(conn: Db.Connection, schema: Orm.Schema[User], request: HttpRequest, id: Int) -> HttpResponse
  case request.method
    "GET" -> return show(conn, schema, id)
    "PATCH" -> return change(conn, schema, id, request.body)
    "DELETE" -> return remove(conn, schema, id)
    _ -> return failure(405, "method not allowed")
  end
end

# POST /users: the body is decoded into a plain struct, and the Orm gives back the row with its new key.
def create(conn: Db.Connection, schema: Orm.Schema[User], body: String) -> HttpResponse
  case JSON.decode(body, NewUser)
    error(_) -> return failure(400, "the body is not a user")
    ok(input) ->
      case Orm.insert(conn, schema, User(name: input.name, age: input.age))
        error(message) -> return refused(message)
        ok(user) -> return json(201, JSON.encode(user))
      end
  end
end

# GET /users, with ?min_age=N and ?sort=COLUMN. The column of the request goes through `order_by`, which checks it
# against the schema, so a request cannot put sql there; the sql of `where` is a constant of the program.
def list(conn: Db.Connection, schema: Orm.Schema[User], target: String) -> HttpResponse
  case filtered(Orm.from(schema), target)
    error(message) -> return failure(400, message)
    ok(query) ->
      column = param(target, "sort").unwrap_or("id")
      case Orm.all(Orm.order_by(query, column) |> Orm.limit(LIST_LIMIT), conn)
        error(message) -> return refused(message)
        ok(found) -> return json(200, JSON.encode(found))
      end
  end
end

# The query with the filters of the request: only ?min_age so far.
def filtered(query: Orm.Query[User], target: String) -> Result[Orm.Query[User]]
  case param(target, "min_age")
    error(_) -> return ok(query)
    ok(text) ->
      case text.to_i
        error(_) -> return error("min_age is not a number")
        ok(years) -> return ok(Orm.where(query, "age >= ?", [Db.Value.Int(years)]))
      end
  end
end

# GET /users/7: `find` gives `Some` or `None`, so a missing row is a 404 and a broken database is a 500.
def show(conn: Db.Connection, schema: Orm.Schema[User], id: Int) -> HttpResponse
  case Orm.find(conn, schema, Db.Value.Int(id))
    error(message) -> return refused(message)
    ok(found) ->
      case found
        Orm.Option.None -> return failure(404, "no such user")
        Orm.Option.Some(user) -> return json(200, JSON.encode(user))
      end
  end
end

# PATCH /users/7: the body is a JSON object of the fields to change, passed to `patch` as it is. A key that is not a
# column is an error of the Orm, and `patch` gives the number of rows it changed.
def change(conn: Db.Connection, schema: Orm.Schema[User], id: Int, body: String) -> HttpResponse
  case JSON.parse(body)
    error(_) -> return failure(400, "the body is not JSON")
    ok(changes) ->
      case Orm.patch(conn, schema, Db.Value.Int(id), changes)
        error(message) -> return refused(message)
        ok(0) -> return failure(404, "no such user")
        ok(_) -> return show(conn, schema, id)
      end
  end
end

def remove(conn: Db.Connection, schema: Orm.Schema[User], id: Int) -> HttpResponse
  case Orm.delete(conn, schema, Db.Value.Int(id))
    error(message) -> return refused(message)
    ok(0) -> return failure(404, "no such user")
    ok(_) -> return HttpResponse(status: 204, headers: [], body: "")
  end
end

# POST /users/import: all the users of the body, or none. The transaction rolls back when an insert fails (a name
# that is already taken: a conflict) and gives back the users it created when it commits.
def import_users(conn: Db.Connection, schema: Orm.Schema[User], body: String) -> HttpResponse
  case JSON.decode(body, Batch)
    error(_) -> return failure(400, "the body is not a batch of users")
    ok(batch) ->
      done = Db.transaction(conn) do |tx|
        created: List[User] = []
        for input in batch.users
          created = created.push(try Orm.insert(tx, schema, User(name: input.name, age: input.age)))
        end

        ok(created)
      end

      case done
        error(message) -> return refused_import(message)
        ok(created) -> return json(201, JSON.encode(created))
      end
  end
end

def users() -> Orm.Schema[User]
  return Orm.schema("users", User.members, JSON.codec(User))
end

def json(status: Int, body: String) -> HttpResponse
  return HttpResponse(status: status, headers: [Header(name: "Content-Type", value: "application/json")], body: body)
end

def failure(status: Int, message: String) -> HttpResponse
  return json(status, JSON.encode({"error": message}))
end

# The status of a failure comes from its kind (`Orm.classify`), not from its text: a bad request is the client's
# fault and its message says what to fix, a conflict (a name that is already taken) is a 409, and anything else is a
# fault of the server that a client has no use for.
def refused(message: String) -> HttpResponse
  case Orm.classify(message)
    Orm.Error.BadRequest(text) -> return failure(400, text)
    Orm.Error.Conflict(_) -> return failure(409, "conflict")
    _ -> return failure(500, "internal error")
  end
end

# The same for an import: nothing was saved, whatever the reason.
def refused_import(message: String) -> HttpResponse
  case Orm.classify(message)
    Orm.Error.Conflict(_) -> return failure(409, "nothing was imported")
    _ -> return failure(500, "nothing was imported")
  end
end

# The value of ?key=value in a request target.
def param(target: String, key: String) -> Result[String]
  parts = target.split("?")
  if parts.size < 2
    return error("no query")
  end

  for pair in parts[1].split("&")
    found = pair.split("=")
    if found.size == 2 and found[0] == key
      return ok(found[1])
    end
  end

  return error("no #{key}")
end

# The requests of the example, in order.
def script() -> List[HttpRequest]
  return [
    build_request("POST", "/users", "{\"name\": \"Ana\", \"age\": 31}"),
    build_request("POST", "/users", "{\"name\": \"Bob\"}"),
    build_request("POST", "/users", "{\"age\": 5}"),
    build_request("GET", "/users/1", ""),
    build_request("GET", "/users/9", ""),
    build_request("POST", "/users", "{\"name\": \"Ana\"}"),
    build_request("GET", "/users?min_age=30", ""),
    build_request("GET", "/users?sort=nickname", ""),
    build_request("PATCH", "/users/2", "{\"age\": 27}"),
    build_request("PATCH", "/users/2", "{\"nickname\": \"b\"}"),
    build_request("POST", "/users/import", "{\"users\": [{\"name\": \"Cy\"}, {\"name\": \"Ana\"}]}"),
    build_request("GET", "/users", ""),
    build_request("POST", "/users/import", "{\"users\": [{\"name\": \"Cy\"}, {\"name\": \"Dee\"}]}"),
    build_request("DELETE", "/users/1", ""),
    build_request("DELETE", "/users/1", ""),
    build_request("GET", "/users?min_age=20&sort=name", ""),
  ]
end

def build_request(method: String, target: String, body: String) -> HttpRequest
  return HttpRequest(method: method, target: target, path: target.split("?")[0], headers: [], body: body)
end

def run() -> Result[Void]
  conn = try Db.open("sqlite::memory:")
  try Db.execute(conn, CREATE_USERS, [])
  schema = users()
  try Orm.check(conn, schema)
  for item in script()
    response = handle(conn, schema, item)
    puts("#{item.method} #{item.target} -> #{response.status} #{response.body}".strip())
  end

  Db.close(conn)
  return ok()
end
