Feature: Examples
  The programs of examples/ run against SQLite as they are, so the README never shows code that does not work.

  Scenario: The users example serves its requests with the Orm
    Given the Agentica program "../examples/users.agc"
    Then the program exits with code 0 within 30000 milliseconds
    And stdout is:
      """
      POST /users -> 201 {"id":1,"name":"Ana","age":31}
      POST /users -> 201 {"id":2,"name":"Bob","age":null}
      POST /users -> 400 {"error":"the body is not a user"}
      GET /users/1 -> 200 {"id":1,"name":"Ana","age":31}
      GET /users/9 -> 404 {"error":"no such user"}
      POST /users -> 500 {"error":"internal error"}
      GET /users?min_age=30 -> 200 [{"id":1,"name":"Ana","age":31}]
      GET /users?sort=nickname -> 400 {"error":"orm error: users: nickname is not a column of the table"}
      PATCH /users/2 -> 200 {"id":2,"name":"Bob","age":27}
      PATCH /users/2 -> 400 {"error":"orm error: users: the changes have a key that is not a column"}
      POST /users/import -> 500 {"error":"nothing was imported"}
      GET /users -> 200 [{"id":1,"name":"Ana","age":31},{"id":2,"name":"Bob","age":27}]
      POST /users/import -> 201 [{"id":3,"name":"Cy","age":null},{"id":4,"name":"Dee","age":null}]
      DELETE /users/1 -> 204
      DELETE /users/1 -> 404 {"error":"no such user"}
      GET /users?min_age=20&sort=name -> 200 [{"id":2,"name":"Bob","age":27}]

      """
