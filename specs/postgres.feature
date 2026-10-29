Feature: PostgreSQL
  What only the PostgreSQL adapter promises. These scenarios need a server: set AGENTICA_DB_POSTGRES_URL.
  The first step of each opens the connection. Parameters travel as text and the server infers their types from
  the sql, so a type comes from the context of the placeholder or from a cast.
  In a step text, [SP] stands for a space a text cell cannot end with, [URL] is the url of the server
  (`[URL]&name=value` adds a libpq parameter) and [SERVER] is that url without its scheme.

  Scenario: Values read back unchanged in columns of the integer, float, text, boolean and null types
    Given a "postgres" database
    Then each value reads back unchanged in a column of its type:
      | column type | value                                        |
      | integer     | Int 2147483647                               |
      | smallint    | Int -32768                                   |
      | float8      | Float 0.0000001                              |
      | float4      | Float 0.5                                    |
      | varchar(5)  | Text short                                   |
      | boolean     | Bool true                                    |
      | boolean     | Bool false                                   |
      | text        | Text quote ' and " and ? and ; and \\ and $1 |
      | numeric     | Null                                         |
      | uuid        | Null                                         |
      | boolean     | Null                                         |

  Scenario: Infinity and NaN round trip, and come back from the server's own spellings
    Given a "postgres" database
    Then the query "select 'Infinity'::float8 as a, '-Infinity'::float8 as b, 'NaN'::float8 as c" returns:
      | a              | b               | c         |
      | Float Infinity | Float -Infinity | Float NaN |
    And each value reads back unchanged in a column of its type:
      | column type | value     |
      | float8      | Float NaN |

  Scenario Outline: A float is read exactly, with or without an exponent: <literal>
    Given a "postgres" database
    Then the server reads the float "<literal>" exactly

    Examples:
      | literal                 |
      | 5e-324                  |
      | 1.7976931348623157e308  |
      | -1.5e-07                |
      | 1e+20                   |
      | -0                      |
      | 9007199254740993        |

  Scenario: A NaN column does not read into a Float field of the Orm
    Given a "postgres" database
    When I read people with "select 1 as id, 'ana' as name, true as admin, 'NaN'::float8 as score"
    Then it fails with exactly "orm error: people: score: not a finite Float"

  Scenario: A bytea reads back whole in the hex and the escape output formats
    Given a "postgres" database
    Then the query "select '\\x00ff0a5c27'::bytea as v" returns:
      | v                   |
      | Blob 0,255,10,92,39 |
    When I execute "set bytea_output = 'escape'"
    Then the query "select '\\x00ff0a5c27'::bytea as v" returns:
      | v                   |
      | Blob 0,255,10,92,39 |

  Scenario: A type without a variant comes back as text
    Given a "postgres" database
    Then the query "select '{\"a\": 1}'::json as j, '{\"a\":1}'::jsonb as jb, array[1, 2]::int[] as a" returns:
      | j             | jb            | a          |
      | Text {"a": 1} | Text {"a": 1} | Text {1,2} |
    And the query "select 'ab'::char(3) as c, 'x'::name as nm, interval '1 day' as iv, 7::oid as o" returns:
      | c           | nm     | iv         | o      |
      | Text ab[SP] | Text x | Text 1 day | Text 7 |

  Scenario: Text parameters are accepted by columns of those types
    Given a "postgres" database
    And I execute "create temp table t (n numeric, d date, ts timestamp, u uuid, j jsonb)"
    When I execute "insert into t values (?, ?, ?, ?, ?)" with:
      | value                                     |
      | Text 12.50                                |
      | Text 2024-02-29                           |
      | Text 2024-02-29 13:14:15                  |
      | Text 123e4567-e89b-12d3-a456-426614174000 |
      | Text {"a": [1, 2]}                        |
    Then the query "select n, d, ts from t" returns:
      | n          | d               | ts                       |
      | Text 12.50 | Text 2024-02-29 | Text 2024-02-29 13:14:15 |
    And the query "select u, j from t" returns:
      | u                                         | j                  |
      | Text 123e4567-e89b-12d3-a456-426614174000 | Text {"a": [1, 2]} |

  Scenario: UTF-8 survives a connection that asks for another client encoding
    Given a "postgres" database
    When I open "[URL]&client_encoding=LATIN1"
    And I query "select ?::text as v, current_setting('client_encoding') as encoding" with:
      | value                |
      | Text héllo ✓ 日本 🚀 |
    Then the result is:
      | v                    | encoding  |
      | Text héllo ✓ 日本 🚀 | Text UTF8 |

  Scenario: A parameter whose type the server cannot infer needs a cast
    Given a "postgres" database
    When I query "select ? is null as v" with:
      | value |
      | Int 1 |
    Then it fails with "postgres error 42P18: "
    When I query "select ?::bigint as v" with:
      | value |
      | Int 1 |
    Then the result is:
      | v     |
      | Int 1 |

  Scenario: A COMMIT of a failed transaction is an error, not a commit
    Given a "postgres" database
    And I execute "create temp table t (a integer)"
    And I execute "BEGIN"
    And I execute "insert into t values (1)"
    When I execute "select 1 / 0"
    Then it fails with "postgres error 22012: "
    When I execute "COMMIT"
    Then it fails with "postgres error 25P02: "
    And the query "select a from t" returns:
      | a |

  Scenario: A transaction body that hides a failed statement does not commit
    Given a "postgres" database
    And I execute "create temp table t (a integer)"
    When I run these statements in a transaction:
      | sql                      | on failure |
      | insert into t values (1) |            |
      | select 1 / 0             | carry on   |
    Then it fails with "postgres error 25P02: "
    And the query "select a from t" returns:
      | a |

  Scenario: An explicit ROLLBACK and a COMMIT that works are not errors
    Given a "postgres" database
    And I execute "create temp table t (a integer)"
    And I execute "begin"
    And I execute "insert into t values (1)"
    And I execute "rollback"
    And the query "select a from t" returns:
      | a |
    And I execute "begin"
    And I execute "insert into t values (2)"
    And I execute "end"
    Then the query "select a from t" returns:
      | a     |
      | Int 2 |

  Scenario: Execute counts a returning statement, and a delete with returning gives its rows
    Given a "postgres" database
    And I execute "create temp table t (a integer)"
    And I execute "insert into t values (1), (2), (3)"
    When I execute "insert into t values (4) returning a"
    Then the changed row count is 1
    When I query "delete from t where a > 2 returning a"
    Then the result is:
      | a     |
      | Int 3 |
      | Int 4 |

  Scenario: A COPY is refused and the connection still works
    Given a "postgres" database
    And I execute "create temp table t (a integer)"
    And I execute "insert into t values (1), (2)"
    When I query "copy t to stdout"
    Then it fails with exactly "postgres error: COPY is not supported"
    When I execute "copy t from stdin"
    Then it fails with exactly "postgres error: COPY is not supported"
    And the query "select count(*) as v from t" returns:
      | v     |
      | Int 2 |

  Scenario: A postgresql:// url works too
    Given a "postgres" database
    When I open "postgresql://[SERVER]"
    Then the query "select 1 as v" returns:
      | v     |
      | Int 1 |
