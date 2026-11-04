## The steps of the features. They drive `Pool` through `driver.agc`, which holds the pool and its jobs (see
## `protocol.agc`). A job is a caller that takes a resource, uses it in a way its name says, and gives it back; the
## resource is a fake cell, and its counters (`made`, `terminated`, `peak`, ...) are what the scenarios check.

import BDD from "std/bdd"
import Protocol from "protocol"
import {Request} from "protocol"

REPLY_MS = 60_000

def main() -> Void
  BDD.run([
    BDD.step("a pool with:") do |ctx, args| send(ctx, Request(op: "start", table: BDD.table(ctx))) end,
    BDD.step("starting a pool with these settings fails with {string}:") do |ctx, args|
      send(ctx, Request(op: "start_fails", text: args[0], table: BDD.table(ctx)))
    end,
    BDD.step("job {string} holds a resource for {int} ms") do |ctx, args|
      send(ctx, Request(op: "job", name: args[0], kind: "holds", number: args[1].to_i!))
    end,
    BDD.step("job {string} probes the pool for {int} ms") do |ctx, args|
      send(ctx, Request(op: "job", name: args[0], kind: "probe", number: args[1].to_i!))
    end,
    BDD.step("{int} callers each take a resource and give it back at once") do |ctx, args|
      send(ctx, Request(op: "flood", number: args[0].to_i!))
    end,
    job_step("job {string} crashes", "crashes"),
    job_step("job {string} returns an error", "fails"),
    job_step("job {string} never returns", "hangs"),
    BDD.step("the caller of job {string} is cancelled") do |ctx, args|
      send(ctx, Request(op: "cancel_job", name: args[0]))
    end,
    BDD.step("I wait for the jobs") do |ctx, args| send(ctx, Request(op: "wait_jobs")) end,
    BDD.step("I wait {int} ms") do |ctx, args| send(ctx, Request(op: "sleep", number: args[0].to_i!)) end,
    BDD.step("I close the pool, giving the jobs {int} ms to finish") do |ctx, args|
      send(ctx, Request(op: "close", number: args[0].to_i!))
    end,
    BDD.step("job {string} succeeds") do |ctx, args|
      send(ctx, Request(op: "expect_job", name: args[0], text: "ok"))
    end,
    BDD.step("job {string} gets {string}") do |ctx, args|
      send(ctx, Request(op: "expect_job", name: args[0], text: args[1]))
    end,
    BDD.step("job {string} fails with a pool timeout") do |ctx, args|
      send(ctx, Request(op: "expect_timeout", name: args[0]))
    end,
    BDD.step("the jobs ended in this order: {string}") do |ctx, args|
      send(ctx, Request(op: "expect_order", text: args[0]))
    end,
    BDD.step("the count {string} is {int}") do |ctx, args|
      send(ctx, Request(op: "expect_count", name: args[0], number: args[1].to_i!, kind: "is"))
    end,
    BDD.step("the count {string} reaches {int} within {int} ms") do |ctx, args|
      send(
        ctx,
        Request(op: "expect_count", name: args[0], number: args[1].to_i!, kind: "reaches", wait: args[2].to_i!),
      )
    end,
  ])
end

def job_step(pattern: String, kind: String) -> BDD.Step
  return BDD.step(pattern) do |ctx, args| send(ctx, Request(op: "job", name: args[0], kind: kind)) end
end

# Sends the request to the driver, started on the first one, and checks that it answers ok. The driver puts what went
# wrong in the reply, which shows as the actual line of the failed check.
def send(ctx: BDD.Context, req: Request) -> BDD.Context
  running = start(ctx)
  asked = BDD.when_line(running, JSON.encode(req))
  return BDD.then_line(asked, Protocol.OK, REPLY_MS)
end

def start(ctx: BDD.Context) -> BDD.Context
  if BDD.get(ctx, "driver").ok?
    return ctx
  end

  return BDD.set(BDD.given_program(ctx, "driver.agc"), "driver", JSON.from(true))
end
