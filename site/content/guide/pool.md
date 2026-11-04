---
title: Pool
weight: 16
description: A generic pool of resources, its own package in the pool/ folder of this repository.
---

`pool/` is a package of its own in this repository (a workspace member), for any resource that is made once and lent to one caller at a time: a database connection, an HTTP connection, a worker. It has no native library. For database connections use [`DbPool`](/guide/pooling/), which is built on this pool. A project that needs only the pool installs it alone with `subdir`, and pins a commit with `ref` until a `pool-` tag exists:

```toml
[dependencies]
pool = { git = "https://github.com/agentica-lang/agentica-db", ref = "COMMIT", subdir = "pool" }
```

A `Pool.Spec[A, W]` holds the config `A` and the functions that make and end the resources `W`:

- `init(config)` makes a resource. It runs in the owner task of the pool, which owns every resource.
- `checkin(resource, outcome)` gets the resource back after each body, with the outcome `Done`, `Crashed` or `TimedOut`. An `error` ends the resource, and the pool makes another. After `TimedOut` the pool ends the resource whatever `checkin` returns, since the cancelled body may still run for a moment; after `Crashed` the body is dead and `checkin` decides.
- `ping(resource)` checks an idle resource at each health tick; an `error` ends it.
- `terminate(resource)` ends it.

`Pool.with(pool) do |resource| ... end` runs the body with a resource and gives its result. The body runs in a task of the pool, so a crash in it is an `error` for the caller and the resource still comes back. Callers wait in line, first come, first served.

```agentica
import Pool from "pkg/pool/pool"

struct Worker
  id: Int
end

def make(ids: ATS[String, Int]) -> Result[Worker]
  return ok(Worker(id: ids.add("next", 1)))
end

def check_in(worker: Worker, outcome: Pool.Outcome) -> Result[Void]
  case outcome
    Pool.Outcome.Done -> return ok()
    Pool.Outcome.Crashed -> return error("crashed")
    Pool.Outcome.TimedOut -> return error("timed out")
  end
end

def end_worker(worker: Worker) -> Void
  puts("ended worker #{worker.id}")
end

def ping(worker: Worker) -> Result[Void]
  return ok()
end

def main() -> Void
  ids: ATS[String, Int] = ATS.new()
  spec = Pool.Spec(config: ids, init: &make, checkin: &check_in, terminate: &end_worker, ping: &ping, size: 2)
  pool = Pool.start(spec).unwrap!
  puts(Pool.with(pool) do |worker| ok("worker #{worker.id}") end)
  Pool.close(pool, 1000)
end
```

```output
ok("worker 1")
ended worker 1
ended worker 2
```

The other fields of the `Spec`, all in milliseconds unless noted, with their defaults:

- `size` (10): how many resources. With `lazy: true` (false) they are made when a caller needs one.
- `max_overflow` (0): in a spike the pool makes up to this many resources more, so `size + max_overflow` is the most that exist (at most 1048576 in all).
- `overflow_idle_ms` (1000): an overflow resource that no caller needs stays this long and is ended if it is still idle then, so the pool shrinks back to `size`, and a steady load a little over `size` does not make and end a resource for every request. 0 ends it as soon as it is given back.
- `checkout_ms` (5000): how long a caller waits for a resource.
- `lease_ms` (30000): how long a body may run. A body past it is cancelled and its caller gets an error.
- `max_age_ms` (0) and `idle_ms` (0): a resource older than `max_age_ms` is ended and replaced; one unused for `idle_ms` is ended (`idle_ms` needs `lazy: true`, since an eager pool would make a new one at once). 0 turns the rule off. Both need `health_ms`, which applies them.
- `max_waiting` (1000): how many callers may wait for a resource at once.
- `health_ms` (5000): the interval of the health tick, which pings the idle resources and applies `max_age_ms` and `idle_ms`. 0 turns the tick off.

The errors are `pool error: checkout timed out after N ms` (with the last error of `init` when the pool could not make a resource), `pool error: lease timed out after N ms`, `pool error: queue full`, `pool error: closed` and `pool error: owner task ended`. `Pool.timeout?(message)` is true for the first two. A caller that got an error never has its body run later, and a caller waits for a resource no longer than `checkout_ms` (and half a second more), also while the owner is busy in a slow `init`. A failed `init` is tried again after a second, not for every job, and the callers that time out meanwhile see its error.

`Pool.close(pool, drain_ms)` refuses new callers, lets the running bodies and the callers in line finish for up to `drain_ms`, fails the rest with `pool error: closed`, ends every resource and stops the pool.

- Start the pool in a task that lives as long as it does, such as `main`: the owner task ends with the task that started it.
- Cancelling a caller does not cancel its body; `lease_ms` bounds it.
- `init` and `terminate` run in the owner task, so they should not block for long, and a crash in one ends the pool (its callers get `pool error: owner task ended`). While one blocks, `Pool.close` cannot run `terminate`: after `drain_ms` and two more seconds the owner is cancelled and the VM closes the handles it owns. `checkin` and `ping` have 5 seconds each.
