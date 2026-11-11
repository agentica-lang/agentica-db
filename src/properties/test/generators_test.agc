import Prop from "pkg/prop/prop"
import Gens from "../value_gens"

SAMPLE_SEED = 42
SAMPLE_SIZE = 400

# A generator that never makes the interesting values would pass every property for nothing. The text cells must hold
# the quote, the placeholder, the newline and the characters of 2 to 4 bytes, and the blobs a zero byte.
def test_the_text_cells_hold_the_pieces_that_break_a_driver() -> Result[Void]
  cells = Prop.sample(Gens.text_cell(), SAMPLE_SEED, SAMPLE_SIZE)
  pieces = ["'", "\"", "?", "$1", ";", "--", "\\", "\n", "\t", "é", "日本", "🚀"]
  for piece in pieces
    seen = cells.any? do |cell| cell.include?(piece) end
    try Test.assert(seen, "no text cell of #{SAMPLE_SIZE} holds #{piece.inspect}")
  end

  Test.assert(cells.any? do |cell| cell == "Text " end, "no text cell is empty")
end

def test_the_other_cells_hold_their_edges() -> Result[Void]
  ints = Prop.sample(Gens.int_cell(), SAMPLE_SEED, SAMPLE_SIZE)
  try Test.assert(ints.include?("Int 9223372036854775807"), "no Int cell holds the biggest Int")
  try Test.assert(ints.include?("Int -9223372036854775808"), "no Int cell holds the least Int")
  kinds = Gens.FloatKinds(nan: true, infinite: true, negative_zero: true)
  floats = Prop.sample(Gens.float_cell(kinds), SAMPLE_SEED, SAMPLE_SIZE)
  try Test.assert(floats.include?("Float NaN"), "no Float cell is NaN")
  try Test.assert(floats.include?("Float -0.0"), "no Float cell is -0.0")
  blobs = Prop.sample(Gens.blob_cell(), SAMPLE_SEED, SAMPLE_SIZE)
  try Test.assert(
    blobs.any? do |cell| cell.include?("Blob 0,") or cell.include?(",0") end,
    "no blob holds a zero byte",
  )

  Test.assert(blobs.include?("Blob "), "no blob is empty")
end
