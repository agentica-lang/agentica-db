## What both drivers of the MySQL adapter decide from the first word of a statement: whether a BEGIN may run, and
## whether `execute` counts the rows that it changed.

# The statements whose affected rows execute reports; every other one gives 0, a SELECT too.
COUNTING_VERBS = Set.new(["insert", "update", "delete", "replace"])

## MySQL has no error for a BEGIN inside a transaction: it commits the open one without a word. Transactions do not
## nest here, as in the other adapters, so a BEGIN or START TRANSACTION is refused while the server says that one is
## open (the `open` argument).
export def check_begin(open: Bool, verb: String) -> Result[Void]
  if (verb == "begin" or verb == "start") and open
    return error("mysql error: a transaction is already in progress")
  end

  return ok()
end

## Whether `execute` gives the affected rows of a statement with this verb.
export def counts?(verb: String) -> Bool
  return COUNTING_VERBS.include?(verb)
end
