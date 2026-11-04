Feature: Checkout
  Pool.with lends a resource to a body and waits in line when all of them are taken. A job is a caller: it takes a
  resource, holds it for the time given, and gives it back. The resources are fake cells, and the counters `made`,
  `peak` (the most cells in use at once) and `checkin_done` say what the pool did with them.

  Scenario: Callers get a resource in the order they asked
    Given a pool with:
      | setting     | value |
      | size        | 1     |
      | checkout_ms | 5000  |
    When job "A" holds a resource for 200 ms
    And job "B" holds a resource for 50 ms
    And job "C" holds a resource for 50 ms
    And I wait for the jobs
    Then the jobs ended in this order: "A,B,C"
    And job "C" succeeds

  Scenario: A caller that waits longer than checkout_ms gets a timeout error
    Given a pool with:
      | setting     | value |
      | size        | 1     |
      | checkout_ms | 100   |
    When job "A" holds a resource for 500 ms
    And job "B" holds a resource for 10 ms
    And I wait for the jobs
    Then job "B" gets "error pool error: checkout timed out after 100 ms"
    And job "B" fails with a pool timeout
    And job "A" succeeds

  Scenario: The pool never lends more resources than its size
    Given a pool with:
      | setting | value |
      | size    | 2     |
    When job "A" holds a resource for 150 ms
    And job "B" holds a resource for 150 ms
    And job "C" holds a resource for 150 ms
    And job "D" holds a resource for 150 ms
    And I wait for the jobs
    Then the count "peak" is 2
    And the count "made" is 2
    And job "D" succeeds

  Scenario: A caller is refused when max_waiting callers wait already
    Given a pool with:
      | setting     | value |
      | size        | 1     |
      | max_waiting | 1     |
    When job "A" holds a resource for 400 ms
    And job "B" holds a resource for 10 ms
    And job "C" holds a resource for 10 ms
    And I wait for the jobs
    Then job "C" gets "error pool error: queue full"
    And job "B" succeeds
    And job "A" succeeds

  Scenario: A caller that is cancelled does not keep its resource
    Given a pool with:
      | setting | value |
      | size    | 1     |
    When job "A" holds a resource for 300 ms
    And the caller of job "A" is cancelled
    And job "B" holds a resource for 10 ms
    And I wait for the jobs
    Then job "B" succeeds
    And the count "made" is 1
    And the count "checkin_done" is 2
