Feature: Values
  A Value written as a parameter reads back unchanged. A table cell is a Value written as text: `Int 31`,
  `Float -0.25`, `Text ana`, `Blob 0,1,255`, `Bool true`, `Null`, and `Repeat 5000 Blob 7` for a big one.
  In a text, [LF] and [TAB] stand for the characters a cell cannot hold.

  Scenario Outline: Every kind of value is written with parameters and read back on <adapter>
    Given a "<adapter>" database
    And I execute "create temp table t (i bigint, f double precision, s text, b <blob type>, n text, flag boolean)"
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
      | Int 9223372036854775807 | Float -0.25 | Text héllo ✓ 日本 🚀 | Blob 0,1,255,0,128 | Null | <flag> |

    Examples:
      | adapter  | flag      | blob type |
      | sqlite   | Int 1     | blob      |
      | postgres | Bool true | bytea     |

  Scenario Outline: Values read back unchanged on <adapter>
    Given a "<adapter>" database
    Then each value reads back unchanged in a column of its type:
      | column type      | value                             |
      | bigint           | Int 0                             |
      | bigint           | Int -1                            |
      | bigint           | Int 9223372036854775807           |
      | bigint           | Int -9223372036854775808          |
      | bigint           | Null                              |
      | double precision | Float 0.1                         |
      | double precision | Float 1000000000000000000000000.5 |
      | double precision | Float -123456.789                 |
      | double precision | Float Infinity                    |
      | double precision | Float -Infinity                   |
      | text             | Text                              |
      | text             | Text quote ' and " and ? and ;    |
      | text             | Text line[LF]break[TAB]tab ünï 🚀 |
      | text             | Null                              |
      | <blob type>      | Blob                              |
      | <blob type>      | Blob 0                            |
      | <blob type>      | Blob 255                          |
      | <blob type>      | Blob 0,255,0,92,120,39            |
      | <blob type>      | Repeat 5000 Blob 7                |

    Examples:
      | adapter  | blob type |
      | sqlite   | blob      |
      | postgres | bytea     |
