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
    Then job "C" gets "error pool error: queue full (max_waiting 1)"
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

  Scenario: The pool lends up to max_overflow more resources in a spike and ends them when they are given back
    Given a pool with:
      | setting      | value |
      | size         | 1     |
      | max_overflow | 2     |
    When job "A" holds a resource for 300 ms
    And job "B" holds a resource for 300 ms
    And job "C" holds a resource for 300 ms
    And job "D" holds a resource for 300 ms
    And I wait for the jobs
    Then the count "peak" is 3
    And the count "made" reaches 3 within 2000 ms
    And the count "terminated" reaches 2 within 2000 ms
    And job "D" succeeds

  Scenario: A pool without a spike makes no more than its size
    Given a pool with:
      | setting      | value |
      | size         | 2     |
      | max_overflow | 2     |
    When job "A" holds a resource for 50 ms
    And I wait for the jobs
    And job "B" holds a resource for 50 ms
    And I wait for the jobs
    Then the count "made" is 2
    And the count "terminated" is 0

  Scenario: A flood of callers while the owner is busy does not lose a resource
    Given a pool with:
      | setting      | value |
      | size         | 2     |
      | lazy         | true  |
      | checkout_ms  | 10000 |
      | max_waiting  | 5000  |
      | slow_init_at | 2     |
      | slow_init_ms | 800   |
    When job "A" holds a resource for 1500 ms
    And job "B" holds a resource for 10 ms
    And 1300 callers each take a resource and give it back at once
    And I wait for the jobs
    And job "P1" probes the pool for 300 ms
    And job "P2" probes the pool for 300 ms
    And I wait for the jobs
    Then the count "flood_failed" is 0
    And the count "probe_peak" is 2
    And the count "made" is 2

  Scenario: A steady load over size does not make and end an overflow resource for every request
    Given a pool with:
      | setting          | value |
      | size             | 1     |
      | max_overflow     | 1     |
      | overflow_idle_ms | 3000  |
    When job "A" keeps taking a resource for 1000 ms
    And job "B" keeps taking a resource for 1000 ms
    And I wait for the jobs
    Then the count "made" is 2
    And the count "terminated" is 0
    And the count "loop_failed" is 0
    And the count "terminated" reaches 1 within 6000 ms

  Scenario: A resource made for a caller that gave up is ended once the spike is over
    Given a pool with:
      | setting          | value |
      | size             | 1     |
      | max_overflow     | 1     |
      | overflow_idle_ms | 100   |
      | checkout_ms      | 100   |
      | slow_init_at     | 2     |
      | slow_init_ms     | 400   |
    When job "A" holds a resource for 800 ms
    And job "B" holds a resource for 10 ms
    And I wait for the jobs
    Then job "B" fails with a pool timeout
    And the count "made" is 2
    And the count "terminated" reaches 1 within 3000 ms

  Scenario: An overflow resource is ended as soon as it is given back when overflow_idle_ms is 0
    Given a pool with:
      | setting          | value |
      | size             | 1     |
      | max_overflow     | 1     |
      | overflow_idle_ms | 0     |
    When job "A" holds a resource for 300 ms
    And job "B" holds a resource for 300 ms
    And I wait for the jobs
    Then the count "made" is 2
    And the count "terminated" reaches 1 within 500 ms
