Feature: Lifecycle
  A pool makes its resources at the start (or when needed, when lazy), checks the idle ones on a health tick
  (ping, max_age_ms, idle_ms) and ends them all when it is closed.

  Scenario: A lazy pool makes a resource only when a caller needs one
    Given a pool with:
      | setting | value |
      | size    | 3     |
      | lazy    | true  |
    Then the count "made" is 0
    When job "A" holds a resource for 200 ms
    And job "B" holds a resource for 200 ms
    And I wait for the jobs
    And job "C" holds a resource for 10 ms
    And I wait for the jobs
    Then the count "made" is 2
    And job "C" succeeds

  Scenario: The health tick replaces an idle resource that does not answer a ping
    Given a pool with:
      | setting     | value |
      | size        | 2     |
      | health_ms   | 100   |
      | bad_ping_id | 1     |
    Then the count "terminated" reaches 1 within 3000 ms
    And the count "made" reaches 3 within 3000 ms

  Scenario: The health tick replaces a resource older than max_age_ms
    Given a pool with:
      | setting    | value |
      | size       | 1     |
      | health_ms  | 50    |
      | max_age_ms | 150   |
    Then the count "terminated" reaches 1 within 3000 ms
    And the count "made" reaches 2 within 3000 ms

  Scenario: The health tick ends a resource that was idle for idle_ms and a lazy pool does not replace it
    Given a pool with:
      | setting   | value |
      | size      | 2     |
      | lazy      | true  |
      | health_ms | 50    |
      | idle_ms   | 150   |
    When job "A" holds a resource for 10 ms
    And I wait for the jobs
    Then the count "terminated" reaches 1 within 3000 ms
    And the count "made" is 1

  Scenario: Closing lets the running job finish, ends every resource and refuses new jobs
    Given a pool with:
      | setting | value |
      | size    | 2     |
    When job "A" holds a resource for 300 ms
    And I close the pool, giving the jobs 3000 ms to finish
    And job "B" holds a resource for 10 ms
    And I wait for the jobs
    Then job "A" succeeds
    And job "B" gets "error pool error: closed"
    And the count "terminated" is 2

  Scenario: Closing fails the jobs that outlast the drain
    Given a pool with:
      | setting | value |
      | size    | 1     |
    When job "A" holds a resource for 5000 ms
    And I close the pool, giving the jobs 100 ms to finish
    And I wait for the jobs
    Then job "A" gets "error pool error: closed"
    And the count "terminated" is 1
