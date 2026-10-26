## The values that cross the database boundary: query parameters and result columns.

## One SQL value. An adapter turns each variant into the native type of its database.
export enum Value
  Null
  Int(Int)
  Float(Float)
  Text(String)
  Blob(List[Int])
  Bool(Bool)
end

## One result row: column name to value, in column order. A repeated column name keeps the last value.
export type Row = Map[String, Value]
