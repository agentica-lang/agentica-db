Feature: Values
  A Value written as a parameter reads back unchanged. A table cell is a Value written as text: `Int 31`,
  `Float -0.25`, `Text ana`, `Blob 0,1,255`, `Bool true`, `Null`, and `Repeat 5000 Blob 7` for a big one.
  In a text, [LF] and [TAB] stand for the characters a cell cannot hold.

  Scenario Outline: Every kind of value is written with parameters and read back on <adapter>
    Given a "<adapter>" database
    And I execute "create temporary table t (i bigint, f double precision, s text, b <blob type>, n text, flag boolean)"
    When I execute "insert into t values (?, ?, ?, ?, ?, ?)" with:
      | value                   |
      | Int 9223372036854775807 |
      | Float -0.25             |
      | Text héllo ✓ 日本 🚀    |
      | Blob 0,1,255,0,128      |
      | Null                    |
      | Bool true               |
    Then the changed row count is 1
    And the query "select i, f, s, b, n, flag from t" returns:
      | i                       | f           | s                    | b                  | n    | flag   |
      | Int 9223372036854775807 | Float -0.25 | Text héllo ✓ 日本 🚀 | Blob 0,1,255,0,128 | Null | <true> |
    When I execute "insert into t (flag) values (?)" with:
      | value      |
      | Bool false |
    Then the query "select flag from t where i is null" returns:
      | flag    |
      | <false> |

    Examples:
      | adapter  | true      | false      | blob type |
      | sqlite   | Int 1     | Int 0      | blob      |
      | postgres | Bool true | Bool false | bytea     |
      | mysql    | Int 1     | Int 0      | longblob  |

  # The longest text and blob here are the "big value" case: the adapter reads them past its first buffer.
  Scenario Outline: Values read back unchanged on <adapter>
    Given a "<adapter>" database
    Then each value reads back unchanged in a column of its type:
      | column type      | value                             |
      | bigint           | Int -9223372036854775808          |
      | bigint           | Null                              |
      | double precision | Float 0.1                         |
      | double precision | Float 1000000000000000000000000.5 |
      | text             | Text                              |
      | text             | Text quote ' and " and ? and ;    |
      | text             | Text line[LF]break[TAB]tab ünï 🚀 |
      | text             | Null                              |
      | <long text type> | Repeat 40000 Text héllo           |
      | <blob type>      | Blob                              |
      | <blob type>      | Blob 0,255,0,92,120,39            |
      | <blob type>      | Null                              |
      | <blob type>      | Repeat 20000 Blob 255             |

    Examples:
      | adapter  | blob type | long text type |
      | sqlite   | blob      | text           |
      | postgres | bytea     | text           |
      | mysql    | longblob  | longtext       |

  # MySQL has no infinity: its adapter refuses one (see mysql.feature).
  Scenario Outline: Infinities read back unchanged on <adapter>
    Given a "<adapter>" database
    Then each value reads back unchanged in a column of its type:
      | column type      | value           |
      | double precision | Float Infinity  |
      | double precision | Float -Infinity |

    Examples:
      | adapter  |
      | sqlite   |
      | postgres |
