Feature: MySQL and MariaDB
  What only the MySQL adapter promises. These scenarios need a server: set AGENTICA_DB_MYSQL_URL (a mysql:// url
  with a user, a password, a host, a port and a database, such as `mysql://root:pw@127.0.0.1:3306/mysql`).
  The first step of each opens the connection. Placeholders are `?`, which MySQL takes natively, and the values are
  always bound by the prepared statement API.
  In a step text, [LF], [TAB], [SP] and [NUL] stand for characters a text cannot hold, [URL] is the url of the server
  (`[URL]&name=value` adds a url parameter), [SERVER] is that url without its scheme and [ADDRESS] is its host and
  port only.

  Scenario Outline: A <scheme> url opens the database it names
    Given a "mysql" database
    When I open "<scheme>://[SERVER]"
    Then the query "select 1 as v" returns:
      | v     |
      | Int 1 |

    Examples:
      | scheme  |
      | mysql   |
      | mariadb |

  Scenario: The database of the url is the current one
    Given a "mysql" database
    When I open "mysql://root:pw@[ADDRESS]/information_schema"
    Then the query "select database() as db" returns:
      | db                    |
      | Text information_schema |

  Scenario: A user and a password with reserved characters are percent-decoded
    Given a "mysql" database
    And I execute "drop user if exists 'we ird'@'%'"
    And I execute "create user 'we ird'@'%' identified by 'p@ss:w/rd#?%'"
    When I open "mysql://we%20ird:p%40ss%3Aw%2Frd%23%3F%25@[ADDRESS]/"
    Then the query "select current_user() as u" returns:
      | u                |
      | Text we ird@% |
    When I open "[URL]"
    And I execute "drop user 'we ird'@'%'"
    Then it succeeds

  Scenario Outline: A bad url is a mysql error that does not show the password: <url>
    Given a "mysql" database
    When I open "<url>"
    Then it fails with "mysql error: <message>"
    And the failure never shows "hunter2"

    Examples:
      | url                                            | message                                                 |
      | mysql://user:hunter2@host:notaport/db          | the url port is not a number from 1 to 65535            |
      | mysql://user:hunter2@host:70000/db             | the url port is not a number from 1 to 65535            |
      | mysql://user:h%zzunter2@host/db                | the url has a bad percent escape                        |
      | mysql://user:hunter2@host/db?nope=1            | the url has an unknown parameter                        |
      | mysql://user:hunter2@host/db?ssl_mode=nope     | the url ssl_mode is required or verify                  |
      | mysql://user:hunter2@host/db?connect_timeout=x | the url connect_timeout is not a number of seconds      |
      | mysql://user:hunter2@host/db/more              | the url path has more than one part                     |
      | mysql://user:hunter2@                          | the url has no host                                     |
      | mysql://user:hunter2@[::1                      | the url has an IPv6 host without a closing bracket      |

  Scenario Outline: The ssl_mode <mode> connects over TLS
    Given a "mysql" database
    When I open "[URL]&ssl_mode=<mode>"
    Then the query "select count(*) as v from information_schema.session_status where variable_name = 'SSL_CIPHER' and variable_value <> ''" returns:
      | v     |
      | Int 1 |

    Examples:
      | mode     |
      | required |
      | verify   |

  Scenario: A url with a NUL character is refused before the library sees it
    Given a "mysql" database
    When I open "mysql://localhost/db[NUL]"
    Then it fails with exactly "mysql error: the url contains a NUL character"

  Scenario: An unreachable server is a mysql error with the client code
    Given a "mysql" database
    When I open "mysql://nobody:hunter2@127.0.0.1:1/none?connect_timeout=2"
    Then it fails with "mysql error 2002: "
    And the failure never shows "hunter2"

  Scenario: A wrong password is a mysql error 1045 that does not show the password
    Given a "mysql" database
    When I open "mysql://root:hunter2@[ADDRESS]/"
    Then it fails with "mysql error 1045: Access denied for user"
    And the failure never shows "hunter2"

  Scenario: An unknown database is a mysql error 1049
    Given a "mysql" database
    When I open "mysql://root:pw@[ADDRESS]/no_such_database"
    Then it fails with "mysql error 1049: "

  Scenario: Values read back unchanged in columns of every integer, float, text and blob type
    Given a "mysql" database
    Then each value reads back unchanged in a column of its type:
      | column type          | value                      |
      | tinyint              | Int -128                   |
      | tinyint unsigned     | Int 255                    |
      | smallint             | Int -32768                 |
      | mediumint            | Int 8388607                |
      | int                  | Int 2147483647             |
      | int unsigned         | Int 4294967295             |
      | bigint unsigned      | Int 9223372036854775807    |
      | float                | Float 0.5                  |
      | double               | Float 0.0000001            |
      | year                 | Int 2024                   |
      | varchar(5)           | Text short                 |
      | char(3)              | Text ab                    |
      | tinytext             | Text tiny                  |
      | mediumtext           | Text medium                |
      | longtext             | Repeat 40000 Text héllo    |
      | text                 | Text quote ' and \\ and ?  |
      | binary(3)            | Blob 1,2,3                 |
      | varbinary(4)         | Blob 0,255                 |
      | tinyblob             | Blob 0,1                   |
      | blob                 | Repeat 20000 Blob 255      |
      | longblob             | Repeat 20000 Blob 0        |
      | boolean              | Int 1                      |
      | boolean              | Int 0                      |
      | bigint               | Null                       |
      | double               | Null                       |
      | varchar(5)           | Null                       |
      | blob                 | Null                       |

  Scenario: A bool is stored as 1 or 0 and reads back as an int
    Given a "mysql" database
    When I execute "create temporary table t (v boolean)"
    And I execute "insert into t values (?), (?)" with:
      | value      |
      | Bool true  |
      | Bool false |
    Then the query "select v from t order by v" returns:
      | v     |
      | Int 0 |
      | Int 1 |

  Scenario: A type without a variant comes back as text
    Given a "mysql" database
    Then the query "select 12.50 as n, cast('2024-02-29' as date) as d, cast('2024-02-29 13:14:15' as datetime) as ts, cast('13:14:15' as time) as t" returns:
      | n          | d               | ts                       | t             |
      | Text 12.50 | Text 2024-02-29 | Text 2024-02-29 13:14:15 | Text 13:14:15 |
    And the query "select cast(1.5 as decimal(10, 3)) as dec3, cast('1:2:3' as time) as t" returns:
      | dec3       | t            |
      | Text 1.500 | Text 01:02:03 |

  Scenario: An enum, a set and a timestamp are text
    Given a "mysql" database
    And I execute "create temporary table t (e enum('a', 'b'), s set('x', 'y'), ts timestamp null)"
    When I execute "insert into t values (?, ?, ?)" with:
      | value               |
      | Text b              |
      | Text x,y            |
      | Text 2024-02-29 13:14:15 |
    Then the query "select e, s, ts from t" returns:
      | e      | s        | ts                       |
      | Text b | Text x,y | Text 2024-02-29 13:14:15 |

  Scenario: Text parameters are accepted by columns of those types
    Given a "mysql" database
    And I execute "create temporary table t (n decimal(10, 2), d date, j json)"
    When I execute "insert into t values (?, ?, ?)" with:
      | value              |
      | Text 12.50         |
      | Text 2024-02-29    |
      | Text {"a": [1, 2]} |
    Then the query "select n, d, j from t" returns:
      | n          | d               | j                  |
      | Text 12.50 | Text 2024-02-29 | Text {"a": [1, 2]} |

  Scenario: A bigint unsigned past the range of an int comes back as text
    Given a "mysql" database
    Then the query "select 18446744073709551615 as big, cast(5 as unsigned) as small" returns:
      | big                       | small |
      | Text 18446744073709551615 | Int 5 |

  Scenario: Integer widths come back as ints and a float as a float
    Given a "mysql" database
    Then the query "select cast(1 as signed) as a, 2 as b, 3000000000 as c, 0.5e0 as d, cast(0.5 as double) as e" returns:
      | a     | b     | c              | d         | e         |
      | Int 1 | Int 2 | Int 3000000000 | Float 0.5 | Float 0.5 |

  Scenario: A bit column comes back as a blob
    Given a "mysql" database
    Then the query "select b'1010' as v" returns:
      | v      |
      | Blob 10 |

  Scenario: A big text and a big blob come back whole
    Given a "mysql" database
    When I query "select ? as v" with:
      | value                   |
      | Repeat 40000 Text héllo |
    Then the result is:
      | v                       |
      | Repeat 40000 Text héllo |
    When I query "select ? as v" with:
      | value                 |
      | Repeat 20000 Blob 255 |
    Then the result is:
      | v                     |
      | Repeat 20000 Blob 255 |

  Scenario: The connection speaks UTF-8 whatever the server defaults to
    Given a "mysql" database
    When I query "select ? as v, @@character_set_client as client, @@character_set_connection as conn, @@character_set_results as results" with:
      | value                |
      | Text héllo ✓ 日本 🚀 |
    Then the result is:
      | v                    | client       | conn         | results      |
      | Text héllo ✓ 日本 🚀 | Text utf8mb4 | Text utf8mb4 | Text utf8mb4 |

  Scenario Outline: A NaN or an infinity is refused, since MySQL cannot store one: <value>
    Given a "mysql" database
    When I execute "select ?" with:
      | value   |
      | <value> |
    Then it fails with exactly "mysql error: a float parameter is NaN or infinite, which MySQL cannot store"

    Examples:
      | value          |
      | Float NaN      |
      | Float Infinity |
      | Float -Infinity |

  Scenario Outline: A placeholder is only outside literals, identifiers and comments: <sql>
    Given a "mysql" database
    When I query "<sql>" with:
      | value |
      | Int 5 |
    Then the result is:
      | q        | n     |
      | <quoted> | Int 5 |

    Examples:
      | sql                                            | quoted      |
      | select '?' as q, ? as n                        | Text ?      |
      | select 'it''s ?' as q, ? as n                  | Text it's ? |
      | select 'it\\\\'s ?' as q, ? as n                  | Text it's ? |
      | select \\"?\\" as q, ? as n                      | Text ?      |
      | select '?' /* ? */ as q, -- ?[LF] ? as n       | Text ?      |
      | select '?' as q, # ?[LF] ? as n                | Text ?      |

  Scenario: A quoted identifier keeps its question mark
    Given a "mysql" database
    When I query "select 1 as `col?`, ? as n" with:
      | value |
      | Int 5 |
    Then the result is:
      | col?  | n     |
      | Int 1 | Int 5 |

  Scenario: Several placeholders are bound in order
    Given a "mysql" database
    When I query "select ? + ? as n, ? as s" with:
      | value  |
      | Int 2  |
      | Int 3  |
      | Text x |
    Then the result is:
      | n     | s      |
      | Int 5 | Text x |

  Scenario Outline: A semicolon inside a literal, a comment or an identifier is not a second statement: <sql>
    Given a "mysql" database
    Then the query "<sql>" returns:
      | v      |
      | <text> |

    Examples:
      | sql                                   | text      |
      | select 'a;b' as v                     | Text a;b  |
      | select 'a\\\\';b' as v                   | Text a';b |
      | select 'a'';b' as v                   | Text a';b |
      | select \\"a;b\\" as v                   | Text a;b  |
      | select `a;b` as v from (select 'x' as `a;b`) t | Text x |
      | select 'x' as v /* a; b */            | Text x    |
      | select 'x' as v # a; b                | Text x    |

  Scenario: The errors carry the code of the server, and the connection works after any of them
    Given a "mysql" database
    And I execute "create temporary table t (a integer not null primary key)"
    When I query "select * from nowhere"
    Then it fails with "mysql error 1146: Table 'mysql.nowhere' doesn't exist"
    When I execute "insert into t values (null)"
    Then it fails with "mysql error 1048: Column 'a' cannot be null"
    When I execute "insert into t values (1)"
    And I execute "insert into t values (1)"
    Then it fails with "mysql error 1062: Duplicate entry '1' for key"
    And the query "select 1 as v" returns:
      | v     |
      | Int 1 |

  Scenario: Execute counts the rows that match, not only the rows that change
    Given a "mysql" database
    And I execute "create temporary table t (a integer, b integer)"
    And I execute "insert into t values (1, 1), (2, 1), (3, 1)"
    When I execute "update t set b = 1 where a < ?" with:
      | value |
      | Int 3 |
    Then the changed row count is 2
    When I execute "select a from t"
    Then the changed row count is 0
    When I execute "delete from t"
    Then the changed row count is 3

  Scenario: A statement that returns rows is run for its effect by execute, and the connection works after it
    Given a "mysql" database
    And I execute "create temporary table t (a integer)"
    When I execute "insert into t values (1), (2)"
    And I execute "select a from t"
    Then the changed row count is 0
    And the query "select count(*) as v from t" returns:
      | v     |
      | Int 2 |

  Scenario: A transaction is open between START TRANSACTION and COMMIT, and a second one is refused
    Given a "mysql" database
    And I execute "create temporary table t (a integer)"
    And I execute "start transaction"
    And I execute "insert into t values (1)"
    When I execute "BEGIN"
    Then it fails with exactly "mysql error: a transaction is already in progress"
    When I execute "start transaction"
    Then it fails with exactly "mysql error: a transaction is already in progress"
    When I execute "rollback"
    And I execute "begin"
    And I execute "insert into t values (2)"
    And I execute "commit"
    Then the query "select a from t" returns:
      | a     |
      | Int 2 |

  Scenario: The verb is found after newlines and comments
    Given a "mysql" database
    And I execute "start transaction"
    When I execute "/* again */ begin[LF]"
    Then it fails with exactly "mysql error: a transaction is already in progress"
    When I execute "# again[LF]-- more[LF][TAB]START[LF]TRANSACTION"
    Then it fails with exactly "mysql error: a transaction is already in progress"
    When I execute "rollback"
    Then it succeeds

  Scenario: A failed statement does not abort the transaction, so the rest commits
    Given a "mysql" database
    And I execute "create temporary table t (a integer primary key)"
    When I run these statements in a transaction:
      | sql                      | on failure |
      | insert into t values (1) |            |
      | insert into t values (1) | carry on   |
      | insert into t values (2) |            |
    Then it succeeds
    And the query "select a from t order by a" returns:
      | a     |
      | Int 1 |
      | Int 2 |

  Scenario: Using a closed connection is an error
    Given a "mysql" database
    When I close the database
    And I query "select 1"
    Then it fails with exactly "mysql error: the connection is closed"

  Scenario: A connection is used by the task that opened it
    Given a "mysql" database
    When another task opens its own connection and queries "select 42 as v"
    Then the result is:
      | v      |
      | Int 42 |

  Scenario: Other tasks run while a query waits for the server
    Given a "mysql" database
    Then another task keeps running during "select sleep(0.5) as v", with gaps under 300 milliseconds

  Scenario: Only one statement runs, the sql of a second one is never sent
    Given a "mysql" database
    And I execute "create temporary table t (a integer)"
    When I execute "insert into t values (1); insert into t values (2)"
    Then it fails with exactly "mysql error: the sql has more than one statement"
    And the query "select count(*) as v from t" returns:
      | v     |
      | Int 0 |
