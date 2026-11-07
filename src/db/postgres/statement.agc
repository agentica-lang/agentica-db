## What both drivers of the PostgreSQL adapter check before a statement runs and after it: the placeholders and the
## parameters, a BEGIN inside a transaction, and a COMMIT that the server turned into a ROLLBACK.

import PostgresSql from "sql"
import {Value} from "../support/value"

# PGTransactionStatusType: a transaction is open (INTRANS) or failed (INERROR).
PQTRANS_INTRANS = 2
PQTRANS_INERROR = 3
ABORTED_COMMIT_SQLSTATE = "25P02"
ACTIVE_TRANSACTION_SQLSTATE = "25001"

## The sql with `$n` placeholders and its verb, once the parameters fit it. `transaction_status` is libpq's
## PQtransactionStatus of the connection.
export def check(sql: String, params: List[Value], transaction_status: Int) -> Result[PostgresSql.Translated]
  translated = try check_sql(sql, params.size, transaction_status)
  try check_params(params)
  return ok(translated)
end

## The same without the scan of the text parameters for a NUL, which the native driver makes in C as it copies them:
## a scan here would hold the scheduler for big ones.
export def check_sql(sql: String, given: Int, transaction_status: Int) -> Result[PostgresSql.Translated]
  translated = try PostgresSql.translate(sql)
  if translated.count != given
    wanted = translated.count
    return error("postgres error: the sql has #{wanted} #{noun(wanted)}, got #{given}")
  end

  try check_begin(transaction_status, translated.verb)
  return ok(translated)
end

## A COMMIT of a transaction that failed does not fail: the server rolls it back and says ROLLBACK (`tag`, its command
## status). The data is lost, so the call must not look like a commit.
export def check_commit(tag: String, verb: String) -> Result[Void]
  if tag == "ROLLBACK" and (verb == "commit" or verb == "end")
    return error("postgres error #{ABORTED_COMMIT_SQLSTATE}: the transaction failed, COMMIT rolled it back")
  end

  return ok()
end

# PostgreSQL only warns about a BEGIN inside a transaction, and the inner COMMIT would then end the outer one:
# transactions do not nest here, as in the other adapters.
def check_begin(status: Int, verb: String) -> Result[Void]
  if (verb == "begin" or verb == "start") and (status == PQTRANS_INTRANS or status == PQTRANS_INERROR)
    return error("postgres error #{ACTIVE_TRANSACTION_SQLSTATE}: a transaction is already in progress")
  end

  return ok()
end

def noun(count: Int) -> String
  if count == 1
    return "parameter"
  end

  return "parameters"
end

def check_params(params: List[Value]) -> Result[Void]
  for param in params
    case param
      Value.Text(text) ->
        if text.include?(String.from_code(0))
          return error("postgres error: a text parameter contains a NUL character")
        end

      Value.Null -> next
      Value.Int(_) -> next
      Value.Float(_) -> next
      Value.Bool(_) -> next
      Value.Blob(_) -> next
    end
  end

  return ok()
end
