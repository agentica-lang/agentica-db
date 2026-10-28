Feature: Transactions
  Db.transaction runs a block between BEGIN and COMMIT. The block returns ok to commit, or an error to roll back,
  and the transaction gives that error. A block that returns a value gives it when the transaction commits.
  Transactions do not nest.

  Scenario Outline: A transaction that returns ok commits on <adapter>
    Given a "<adapter>" database
    And I execute "create temporary table users (name varchar(50) not null unique)"
    When I run these statements in a transaction:
      | sql                                     |
      | insert into users (name) values ('ana') |
      | insert into users (name) values ('bob') |
    Then it succeeds
    And the query "select name from users order by name" returns:
      | name     |
      | Text ana |
      | Text bob |

    Examples:
      | adapter  |
      | sqlite   |
      | postgres |
      | mysql    |

  Scenario Outline: A transaction that returns an error rolls back and gives that error on <adapter>
    Given a "<adapter>" database
    And I execute "create temporary table users (name varchar(50) not null unique)"
    And I execute "insert into users (name) values ('kept')"
    When I run these statements in a transaction that fails with "stop here":
      | sql                                      |
      | insert into users (name) values ('lost') |
    Then it fails with exactly "stop here"
    And the query "select name from users" returns:
      | name      |
      | Text kept |

    Examples:
      | adapter  |
      | sqlite   |
      | postgres |
      | mysql    |

  Scenario Outline: A transaction that returns a value commits and gives it on <adapter>
    Given a "<adapter>" database
    And I execute "create temporary table users (name varchar(50) not null unique)"
    When I run these statements in a transaction that gives a count:
      | sql                                             |
      | insert into users (name) values ('ana')         |
      | insert into users (name) values ('bob'), ('cy') |
    Then the changed row count is 2
    And the query "select name from users order by name" returns:
      | name     |
      | Text ana |
      | Text bob |
      | Text cy  |

    Examples:
      | adapter  |
      | sqlite   |
      | postgres |
      | mysql    |

  Scenario Outline: A transaction that returns a value and then an error rolls back on <adapter>
    Given a "<adapter>" database
    And I execute "create temporary table users (name varchar(50) not null unique)"
    And I execute "insert into users (name) values ('kept')"
    When I run these statements in a transaction that gives a count, then fails with "stop here":
      | sql                                      |
      | insert into users (name) values ('lost') |
    Then it fails with exactly "stop here"
    And the query "select name from users" returns:
      | name      |
      | Text kept |

    Examples:
      | adapter  |
      | sqlite   |
      | postgres |
      | mysql    |

  Scenario Outline: A failed statement inside a transaction rolls it back on <adapter>
    Given a "<adapter>" database
    And I execute "create temporary table users (name varchar(50) not null unique)"
    And I execute "insert into users (name) values ('dup')"
    When I run these statements in a transaction:
      | sql                                       |
      | insert into users (name) values ('other') |
      | insert into users (name) values ('dup')   |
    Then it fails with "<prefix>"
    And the query "select name from users" returns:
      | name     |
      | Text dup |

    Examples:
      | adapter  | prefix                                                               |
      | sqlite   | sqlite error 19: UNIQUE constraint failed                            |
      | postgres | postgres error 23505: duplicate key value violates unique constraint |
      | mysql    | mysql error 1062: Duplicate entry 'dup' for key                      |

  Scenario Outline: Transactions do not nest, and a new one works after the refusal on <adapter>
    Given a "<adapter>" database
    And I execute "create temporary table users (name varchar(50) not null unique)"
    When I run these statements in a transaction that starts a transaction inside it:
      | sql                                       |
      | insert into users (name) values ('inner') |
    Then it fails with "<prefix>"
    And the query "select name from users" returns:
      | name |
    When I run these statements in a transaction:
      | sql                                       |
      | insert into users (name) values ('later') |
    Then it succeeds
    And the query "select name from users" returns:
      | name       |
      | Text later |

    Examples:
      | adapter  | prefix                                                          |
      | sqlite   | sqlite error 1: cannot start a transaction within a transaction |
      | postgres | postgres error 25001:                                           |
      | mysql    | mysql error: a transaction is already in progress               |
