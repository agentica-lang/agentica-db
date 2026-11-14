---
title: Generic pool
weight: 3
description: The generic pool of resources that DbPool is built on, the pool package of agentica-lang/packages.
aliases:
  - /guide/pool/
---

The pool that [`DbPool`](/production/pooling/) is built on is a package of its own, `pool`, in [agentica-lang/packages](https://github.com/agentica-lang/packages). It is for any resource that is made once and lent to one caller at a time: a database connection, an HTTP connection, a worker. Its documentation is on the [pool page](https://agentica-lang.github.io/packages/pool/): the `Spec`, its settings and defaults, the errors and their kinds, and how a caller that ends and a close are handled.

A project that needs only the pool installs it alone:

```sh
agentica add pool https://github.com/agentica-lang/packages --tag pool-0.1.0 --subdir pool
```

`DbPool` takes the settings of the pool as its own options, with the same names and defaults (see the [connection pool](/production/pooling/)). A project that imports `pkg/db/db_pool` gets the `pool` package as a dependency of `db`.
