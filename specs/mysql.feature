Feature: MySQL and MariaDB
  What only the MySQL adapter promises. These scenarios need a server: set AGENTICA_DB_MYSQL_URL (a mysql:// url
  with a user, a password, a host, a port and a database, such as `mysql://root:pw@127.0.0.1:3306/mysql`).
  The first step of each opens the connection. Placeholders are `?`, which MySQL takes natively, and the values are
  always bound by the prepared statement API.
  In a step text, [LF], [TAB], [SP] and [NUL] stand for characters a text cannot hold, [URL] is the url of the server
  (`[URL]&name=value` adds a url parameter), [SERVER] is that url without its scheme and [ADDRESS] is its host and
  port only.

  Scenario: A mariadb:// url works too
    Given a "mysql" database
    When I open "mariadb://[SERVER]"
    Then the query "select 1 as v" returns:
      | v     |
      | Int 1 |

  Scenario: The ssl_mode required connects over TLS
    Given a "mysql" database
    When I open "[URL]&ssl_mode=required"
    Then the query "show status like 'Ssl_cipher'" returns:
      | Variable_name   | Value                      |
      | Text Ssl_cipher | Text TLS_AES_256_GCM_SHA384 |

  # The server of the tests has a self-signed certificate, which no authority of this file vouches for. Without a file
  # of authorities libmariadb does not verify anything, so the url must name one.
  Scenario: The ssl_mode verify refuses a server whose certificate the authorities do not vouch for
    Given a "mysql" database
    When I open "[URL]&ssl_mode=verify&ssl_ca=fixtures/unrelated-ca.pem"
    Then it fails with "mysql error 2026: TLS/SSL error: self-signed certificate"
    And the failure never shows "pw"

  Scenario: A wrong password is a mysql error 1045 that does not show the password
    Given a "mysql" database
    When I open "mysql://root:hunter2@[ADDRESS]/"
    Then it fails with "mysql error 1045: Access denied for user"
    And the failure never shows "hunter2"

  Scenario: Values read back unchanged in columns of every integer, float, text and blob type of MySQL
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
      | text                 | Text quote ' and \\ and ?  |
      | binary(3)            | Blob 1,2,3                 |
      | varbinary(4)         | Blob 0,255                 |
      | tinyblob             | Blob 0,1                   |
      | boolean              | Int 1                      |
      | boolean              | Int 0                      |

  Scenario: A type without a variant is written from text and comes back as text
    Given a "mysql" database
    And I execute "create temporary table t (n decimal(10, 3), d date, ts datetime, tm time, j json, e enum('a', 'b'), s set('x', 'y'))"
    When I execute "insert into t values (?, ?, ?, ?, ?, ?, ?)" with:
      | value                    |
      | Text 12.5                |
      | Text 2024-02-29          |
      | Text 2024-02-29 13:14:15 |
      | Text 1:2:3               |
      | Text {"a": [1, 2]}       |
      | Text b                   |
      | Text x,y                 |
    Then the query "select n, d, ts, tm from t" returns:
      | n           | d               | ts                       | tm            |
      | Text 12.500 | Text 2024-02-29 | Text 2024-02-29 13:14:15 | Text 01:02:03 |
    And the query "select j, e, s from t" returns:
      | j                  | e      | s        |
      | Text {"a": [1, 2]} | Text b | Text x,y |

  Scenario: A bigint unsigned past the range of an int comes back as text
    Given a "mysql" database
    Then the query "select 18446744073709551615 as big, cast(5 as unsigned) as small" returns:
      | big                       | small |
      | Text 18446744073709551615 | Int 5 |

  Scenario: A bit column comes back as a blob
    Given a "mysql" database
    Then the query "select b'1010' as v" returns:
      | v      |
      | Blob 10 |

  Scenario Outline: A NaN or an infinity is refused, since MySQL cannot store one: <value>
    Given a "mysql" database
    When I execute "select ?" with:
      | value   |
      | <value> |
    Then it fails with exactly "mysql error: a float parameter is NaN or infinite, which MySQL cannot store"

    Examples:
      | value           |
      | Float NaN       |
      | Float -Infinity |

  Scenario: The connection speaks UTF-8 whatever the server defaults to
    Given a "mysql" database
    When I query "select ? as v, @@character_set_client as client, @@character_set_connection as conn, @@character_set_results as results" with:
      | value                |
      | Text héllo ✓ 日本 🚀 |
    Then the result is:
      | v                    | client       | conn         | results      |
      | Text héllo ✓ 日本 🚀 | Text utf8mb4 | Text utf8mb4 | Text utf8mb4 |

  Scenario: Execute counts the rows that match, and an upsert over an existing row counts 2
    Given a "mysql" database
    And I execute "create temporary table t (a integer primary key, b integer)"
    And I execute "insert into t values (1, 1), (2, 1), (3, 1)"
    When I execute "update t set b = 1 where a < ?" with:
      | value |
      | Int 3 |
    Then the changed row count is 2
    When I execute "insert into t values (1, 2) on duplicate key update b = 3"
    Then the changed row count is 2
    When I execute "replace into t values (1, 4)"
    Then the changed row count is 2
    When I execute "replace into t values (4, 4)"
    Then the changed row count is 1
    And the query "select a, b from t order by a" returns:
      | a     | b     |
      | Int 1 | Int 4 |
      | Int 2 | Int 1 |
      | Int 3 | Int 1 |
      | Int 4 | Int 4 |

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

  Scenario: A statement the server does not prepare runs over the text protocol, but never with parameters
    Given a "mysql" database
    When I execute "use information_schema"
    Then the query "select database() as db" returns:
      | db                      |
      | Text information_schema |
    And the query "check table mysql.db" returns:
      | Table         | Op         | Msg_type    | Msg_text |
      | Text mysql.db | Text check | Text status | Text OK  |
    When I execute "start transaction" with:
      | value |
      | Int 1 |
    Then it fails with "mysql error"

  Scenario: A float column keeps the precision of a float
    Given a "mysql" database
    And I execute "create temporary table t (v float)"
    When I execute "insert into t values (?), (?)" with:
      | value     |
      | Float 0.5 |
      | Float 0.1 |
    Then the query "select v from t order by v" returns:
      | v                    |
      | Float 0.10000000149011612 |
      | Float 0.5            |

  Scenario: LOAD DATA LOCAL INFILE is refused, so a server cannot read a file of this machine
    Given a "mysql" database
    And I execute "create temporary table t (a text)"
    When I execute "load data local infile '/etc/hostname' into table t"
    Then it fails with "mysql error "
    And the query "select count(*) as v from t" returns:
      | v     |
      | Int 0 |

