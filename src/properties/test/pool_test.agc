import Prop from "pkg/prop/prop"
import PoolModel from "../pool_model"

# The runs are fewer than in the other properties: a case takes real time (leases, cancels and a close wait for
# milliseconds), about 100 ms on average, and a test may take 30 s.
RUNS = 40
SHRINKS = 40

def test_random_sequences_keep_the_pool_invariants() -> Result[Void]
  return Prop.check(PoolModel.sequence_gen(), Prop.Config(runs: RUNS, shrinks: SHRINKS)) do |pair|
    PoolModel.keeps_invariants(pair.first, pair.second)
  end
end

def test_a_burst_leaves_no_more_than_max_waiting_in_line() -> Result[Void]
  return Prop.check(PoolModel.burst_gen(), Prop.Config(runs: RUNS, shrinks: SHRINKS)) do |pair|
    PoolModel.keeps_line(pair.first, pair.second)
  end
end
