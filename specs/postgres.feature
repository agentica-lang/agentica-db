Feature: PostgreSQL
  What only the PostgreSQL adapter promises. These scenarios need a server and run when AGENTICA_DB_POSTGRES_URL is
  set; the first step of each opens the connection. Parameters travel as text and the server infers their types from
  the sql, so a type comes from the context of the placeholder or from a cast.

  Scenario: Values read back unchanged in columns of every integer, float, text and bytea type
    Given a "postgres" database
    Then each value reads back unchanged in a column of its type:
      | column type | value                           |
      | integer     | Int 2147483647                  |
      | smallint    | Int -32768                      |
      | float8      | Float 0.0000001                 |
      | float4      | Float 0.5                       |
      | varchar(5)  | Text short                      |
      | bytea       | Repeat 20000 Blob 255           |
      | boolean     | Bool true                       |
      | boolean     | Bool false                      |
      | text        | Text quote ' and " and ? and ; and \\ and $1 |

  Scenario: Infinity and NaN round trip, and come back from the server's own spellings
    Given a "postgres" database
    Then the query "select 'Infinity'::float8 as a, '-Infinity'::float8 as b, 'NaN'::float8 as c" returns:
      | a              | b               | c         |
      | Float Infinity | Float -Infinity | Float NaN |
    And each value reads back unchanged in a column of its type:
      | column type | value           |
      | float8      | Float NaN       |
      | float8      | Float Infinity  |

  Scenario: A float is read exactly, with or without an exponent
    Given a "postgres" database
    Then the query "select '5e-324'::float8 as v union all select '1.7976931348623157e308'::float8 union all select '-1.5e-07'::float8 union all select '1e+20'::float8 union all select '2.2250738585072014e-308'::float8 union all select '0.1'::float8 union all select '123456789.123456789'::float8 union all select '9007199254740993'::float8" returns:
      | v                            |
      | Float 5e-324                 |
      | Float 1.7976931348623157e308 |
      | Float -1.5e-07               |
      | Float 1e+20                  |
      | Float 2.2250738585072014e-308 |
      | Float 0.1                    |
      | Float 123456789.123456789    |
      | Float 9007199254740993       |

  Scenario: A bool is a real boolean
    Given a "postgres" database
    When I query "select ?::boolean as a, 't'::boolean as b, 1 = 2 as c" with:
      | value      |
      | Bool false |
    Then the result is:
      | a          | b         | c          |
      | Bool false | Bool true | Bool false |

  Scenario: A bytea reads back whole in the hex and the escape output formats
    Given a "postgres" database
    Then the query "select '\\x00ff0a5c27'::bytea as v" returns:
      | v                    |
      | Blob 0,255,10,92,39  |
    When I execute "set bytea_output = 'escape'"
    Then the query "select '\\x00ff0a5c27'::bytea as v" returns:
      | v                    |
      | Blob 0,255,10,92,39  |

  Scenario: A null of every type reads back as null
    Given a "postgres" database
    Then the query "select cast(null as integer) as a, cast(null as float8) as b, cast(null as text) as c, cast(null as bytea) as d, cast(null as boolean) as e, cast(null as numeric) as f, cast(null as uuid) as g" returns:
      | a    | b    | c    | d    | e    | f    | g    |
      | Null | Null | Null | Null | Null | Null | Null |
    And each value reads back unchanged in a column of its type:
      | column type | value |
      | integer     | Null  |
      | float8      | Null  |
      | text        | Null  |
      | bytea       | Null  |
      | boolean     | Null  |
      | numeric     | Null  |
      | uuid        | Null  |

  Scenario: A type without a variant comes back as text
    Given a "postgres" database
    Then the query "select 12.50::numeric as n, date '2024-02-29' as d, timestamp '2024-02-29 13:14:15' as ts, '123e4567-e89b-12d3-a456-426614174000'::uuid as u, '{\"a\": 1}'::json as j, '{\"a\":1}'::jsonb as jb, array[1, 2]::int[] as a, 'ab'::char(3) as c, 'x'::name as nm, interval '1 day' as iv, 7::oid as o" returns:
      | n          | d               | ts                        | u                                         | j                | jb               | a          | c         | nm     | iv           | o      |
      | Text 12.50 | Text 2024-02-29 | Text 2024-02-29 13:14:15  | Text 123e4567-e89b-12d3-a456-426614174000 | Text {"a": 1}    | Text {"a": 1}    | Text {1,2} | Text ab[SP] | Text x | Text 1 day   | Text 7 |

  Scenario: Text parameters are accepted by columns of those types
    Given a "postgres" database
    And I execute "create temp table t (n numeric, d date, u uuid, j jsonb)"
    When I execute "insert into t values (?, ?, ?, ?)" with:
      | value                                         |
      | Text 12.50                                    |
      | Text 2024-02-29                               |
      | Text 123e4567-e89b-12d3-a456-426614174000     |
      | Text {"a": [1, 2]}                            |
    Then the query "select n, d, u, j from t" returns:
      | n          | d               | u                                         | j                  |
      | Text 12.50 | Text 2024-02-29 | Text 123e4567-e89b-12d3-a456-426614174000 | Text {"a": [1, 2]} |

  Scenario: Integer widths come back as ints and a float4 as a float
    Given a "postgres" database
    Then the query "select 1::int2 as a, 2::int4 as b, 3::int8 as c, 0.5::float4 as d" returns:
      | a     | b     | c     | d         |
      | Int 1 | Int 2 | Int 3 | Float 0.5 |

  Scenario: A big text and a big blob come back whole
    Given a "postgres" database
    When I query "select ?::text as v" with:
      | value                        |
      | Repeat 40000 Text héllo      |
    Then the result is:
      | v                            |
      | Repeat 40000 Text héllo      |
    When I query "select ?::bytea as v" with:
      | value                        |
      | Repeat 20000 Blob 255        |
    Then the result is:
      | v                            |
      | Repeat 20000 Blob 255        |

  Scenario: UTF-8 survives a connection that asks for another client encoding
    Given a "postgres" database
    When I open "[URL]&client_encoding=LATIN1"
    And I query "select ?::text as v, current_setting('client_encoding') as encoding" with:
      | value                |
      | Text héllo ✓ 日本 🚀 |
    Then the result is:
      | v                    | encoding  |
      | Text héllo ✓ 日本 🚀 | Text UTF8 |

  Scenario Outline: A placeholder is translated only outside literals, identifiers and comments: <sql>
    Given a "postgres" database
    When I query "<sql>" with:
      | value |
      | Int 5 |
    Then the result is:
      | q        | n     |
      | <quoted> | Int 5 |

    Examples:
      | sql                                          | quoted      |
      | select '?' as q, ?::int as n                 | Text ?      |
      | select 'it''s ?' as q, ?::int as n           | Text it's ? |
      | select $$?$$ as q, ?::int as n               | Text ?      |
      | select $t$$$ ?$t$ as q, ?::int as n          | Text $$ ?   |
      | select '?' /* ? */ as q, -- ?[LF] ?::int as n | Text ?      |

  Scenario: A placeholder after an escaped quote of an E string is still a placeholder
    Given a "postgres" database
    When I query "select E'\\'?' as q, ?::int as n" with:
      | value |
      | Int 5 |
    Then the result is:
      | q      | n     |
      | Text '? | Int 5 |

  Scenario: A quoted identifier keeps its question mark
    Given a "postgres" database
    When I query "select 1 as \"col?\", ?::int as n" with:
      | value |
      | Int 5 |
    Then the result is:
      | col?  | n     |
      | Int 1 | Int 5 |

  Scenario: Several placeholders are numbered in order
    Given a "postgres" database
    When I query "select ?::int + ?::int as n" with:
      | value |
      | Int 2 |
      | Int 3 |
    Then the result is:
      | n     |
      | Int 5 |

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

  Scenario: The errors carry the SQLSTATE of the server, and the connection works after any of them
    Given a "postgres" database
    And I execute "create temp table t (a integer not null primary key)"
    When I query "select * from nowhere"
    Then it fails with "postgres error 42P01: relation \"nowhere\" does not exist"
    When I query "select 1 / ?::int as v" with:
      | value |
      | Int 0 |
    Then it fails with "postgres error 22012: division by zero"
    When I execute "insert into t values (null)"
    Then it fails with "postgres error 23502: null value in column \"a\""
    When I execute "insert into t values (1)"
    And I execute "insert into t values (1)"
    Then it fails with "postgres error 23505: duplicate key value violates unique constraint"
    And the query "select 1 as v" returns:
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

  Scenario: The verb is found after newlines and comments
    Given a "postgres" database
    And I execute "create temp table t (a integer)"
    And I execute "BEGIN[LF]ISOLATION LEVEL SERIALIZABLE"
    When I execute "/* again */ begin[LF]"
    Then it fails with "postgres error 25001: "
    When I execute "insert into t values (1)"
    And I execute "select 1 / 0"
    Then it fails with "postgres error 22012: "
    # The transaction is in error: a nested BEGIN is still refused, and the COMMIT is not taken for a commit.
    When I execute "begin"
    Then it fails with "postgres error "
    When I execute "-- done[LF][TAB]COMMIT[LF]"
    Then it fails with "postgres error 25P02: "
    And the query "select a from t" returns:
      | a |

  Scenario: A transaction body that hides a failed statement does not commit
    Given a "postgres" database
    And I execute "create temp table t (a integer)"
    When I run these statements in a transaction:
      | sql                       | failure |
      | insert into t values (1)  |         |
      | select 1 / 0              | ignored |
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

  Scenario: Execute counts insert, update, delete and returning, not select
    Given a "postgres" database
    And I execute "create temp table t (a integer)"
    When I execute "insert into t values (1), (2), (3)"
    Then the changed row count is 3
    When I execute "insert into t values (4) returning a"
    Then the changed row count is 1
    When I execute "select a from t"
    Then the changed row count is 0
    When I execute "update t set a = a + 10 where a > ?" with:
      | value |
      | Int 2 |
    Then the changed row count is 2
    When I execute "delete from t where a > ?" with:
      | value   |
      | Int 100 |
    Then the changed row count is 0
    When I query "delete from t where a > 10 returning a"
    Then the result is:
      | a      |
      | Int 13 |
      | Int 14 |

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

  Scenario: Using a closed connection is an error
    Given a "postgres" database
    When I close the database
    And I query "select 1"
    Then it fails with exactly "postgres error: the connection is closed"

  Scenario: A connection is used by the task that opened it
    Given a "postgres" database
    When another task opens its own connection and queries "select 42 as v"
    Then the result is:
      | v      |
      | Int 42 |

  Scenario: Other tasks run while a query waits for the server
    Given a "postgres" database
    Then another task keeps running during "select pg_sleep(0.5)::text as v", with gaps under 300 milliseconds

  Scenario Outline: A bad url or an unreachable server is a postgres error: <url>
    Given a "postgres" database
    When I open "<url>"
    Then it fails with "postgres error: "

    Examples:
      | url                                                                 |
      | postgres://nobody@127.0.0.1:1/none?sslmode=disable&connect_timeout=2 |
      | postgres://localhost:notaport/db                                    |

  Scenario: A url with a NUL character is refused before libpq sees it
    Given a "postgres" database
    When I open "postgres://localhost/db[NUL]"
    Then it fails with exactly "postgres error: the url contains a NUL character"
