Feature: Outcomes
  The body of a job runs in a task of the pool and checkin gets its outcome: Done, Crashed or TimedOut. The fake
  checkin keeps the cell after Done and ends it after the other two, unless the pool says keep_dirty. A cell that is
  ended is replaced by a new one, so the pool keeps its size.

  Scenario Outline: A body that crashes gives an error and checkin decides on the cell (keep_dirty <keep_dirty>)
    Given a pool with:
      | setting    | value        |
      | size       | 1            |
      | keep_dirty | <keep_dirty> |
    When job "A" crashes
    And job "B" holds a resource for 10 ms
    And I wait for the jobs
    Then job "A" gets "error task crashed"
    And job "B" succeeds
    And the count "checkin_crashed" is 1
    And the count "made" is <made>
    And the count "terminated" reaches <terminated> within 2000 ms

    Examples:
      | keep_dirty | made | terminated |
      | false      | 2    | 1          |
      | true       | 1    | 0          |

  Scenario: A body that returns an error is a normal outcome
    Given a pool with:
      | setting | value |
      | size    | 1     |
    When job "A" returns an error
    And job "B" holds a resource for 10 ms
    And I wait for the jobs
    Then job "A" gets "error the body failed"
    And job "B" succeeds
    And the count "checkin_done" is 2
    And the count "made" is 1

  Scenario: A body that runs longer than lease_ms is cancelled and its cell is replaced
    Given a pool with:
      | setting  | value |
      | size     | 1     |
      | lease_ms | 150   |
    When job "A" never returns
    And job "B" holds a resource for 10 ms
    And I wait for the jobs
    Then job "A" gets "error pool error: lease timed out after 150 ms"
    And job "A" fails with a pool timeout
    And job "B" succeeds
    And the count "checkin_timed_out" is 1
    And the count "made" is 2
    And the count "terminated" reaches 1 within 2000 ms

  Scenario: A pool whose init fails does not start and ends the resources it made
    Then starting a pool with these settings fails with "init failed for resource 2":
      | setting       | value |
      | size          | 2     |
      | init_fails_at | 2     |
    And the count "terminated" reaches 1 within 2000 ms

  Scenario Outline: A setting out of range is refused (<setting>)
    Then starting a pool with these settings fails with "<error>":
      | setting   | value   |
      | <setting> | <value> |

    Examples:
      | setting     | value | error                                                   |
      | size        | 0     | pool error: size must be at least 1                     |
      | checkout_ms | 0     | pool error: checkout_ms and lease_ms must be at least 1 |
