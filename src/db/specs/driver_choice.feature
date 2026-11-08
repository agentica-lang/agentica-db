Feature: The driver of a run
  CI runs the scenarios once per driver, with AGENTICA_DB_<ADAPTER>_DRIVER set to `native` and then to `ffi`. These
  scenarios fail when the connection runs another driver than the variable names, so a run cannot pass on the wrong
  one. With the variable unset any driver passes. MySQL has the FFI driver only, so it is not here.

  Scenario Outline: The connection runs the driver that the run names on <adapter>
    Given a "<adapter>" database
    When I check that the connection runs the driver that "<variable>" names
    Then it succeeds

    Examples:
      | adapter  | variable                    |
      | sqlite   | AGENTICA_DB_SQLITE_DRIVER   |
      | postgres | AGENTICA_DB_POSTGRES_DRIVER |
