## The sql of the conditions, the order and the page of a query. It does no I/O: the connection only says how names
## are quoted. A column name reaches here after the Orm checked it against the schema, and goes through
## `Dialect.quote` anyway; a value is always a `?` parameter.

import Db from "../db"
import Dialect from "dialect"

# The largest Int: a page with an offset and no limit still needs a limit in SQLite and MySQL.
NO_LIMIT = 9223372036854775807

## One condition: a column equal to a value (`Null` is `is null`), a column among values (no value matches nothing),
## or a piece of sql of the caller with its parameters.
export enum Cond
  Eq(String, Db.Value)
  In(String, List[Db.Value])
  Raw(String, List[Db.Value])
end

## One column of the order, ascending or not.
export struct Order
  column: String
  desc: Bool
end

## What a query holds: the conditions (all of them must hold), the order, the limit (-1 for none) and the offset.
export struct Plan
  conds: List[Cond] = []
  orders: List[Order] = []
  limit: Int = -1
  offset: Int = 0
end

## A piece of sql and its parameters, in the order of the `?` in the sql.
export struct Piece
  sql: String
  params: List[Db.Value]
end

## ` where a and b`, or nothing when the plan has no condition.
export def where_piece(conn: Db.Connection, plan: Plan) -> Result[Piece]
  texts: List[String] = []
  params: List[Db.Value] = []
  for cond in plan.conds
    piece = try cond_piece(conn, cond)
    texts = texts.push(piece.sql)
    params = params.concat(piece.params)
  end

  if texts.empty?
    return ok(Piece(sql: "", params: []))
  end

  return ok(Piece(sql: " where #{texts.join(" and ")}", params: params))
end

## ` order by a, b desc limit ? offset ?`, with only the parts the plan has.
export def tail_piece(conn: Db.Connection, plan: Plan) -> Result[Piece]
  names: List[String] = []
  for order in plan.orders
    quoted = try Dialect.quote(conn, order.column)
    if order.desc
      names = names.push("#{quoted} desc")
    else
      names = names.push(quoted)
    end
  end

  sql = ""
  if not names.empty?
    sql = " order by #{names.join(", ")}"
  end

  params: List[Db.Value] = []
  if plan.limit >= 0 or plan.offset > 0
    sql = sql + " limit ?"
    params = params.push(Db.Value.Int(max_rows(plan)))
  end

  if plan.offset > 0
    sql = sql + " offset ?"
    params = params.push(Db.Value.Int(plan.offset))
  end

  return ok(Piece(sql: sql, params: params))
end

## Whether the plan has an order, a limit or an offset.
export def paged?(plan: Plan) -> Bool
  return not plan.orders.empty? or plan.limit >= 0 or plan.offset > 0
end

def max_rows(plan: Plan) -> Int
  if plan.limit >= 0
    return plan.limit
  end

  return NO_LIMIT
end

def cond_piece(conn: Db.Connection, cond: Cond) -> Result[Piece]
  case cond
    Cond.Eq(column, Db.Value.Null) -> return ok(Piece(sql: "#{try Dialect.quote(conn, column)} is null", params: []))
    Cond.Eq(column, value) -> return ok(Piece(sql: "#{try Dialect.quote(conn, column)} = ?", params: [value]))
    Cond.In(_, values) if values.empty? -> return ok(Piece(sql: "1 = 0", params: []))
    Cond.In(column, values) ->
      marks = values.map do |value| "?" end.join(", ")
      return ok(Piece(sql: "#{try Dialect.quote(conn, column)} in (#{marks})", params: values))
    Cond.Raw(sql, params) -> return ok(Piece(sql: "(#{sql})", params: params))
  end
end
