import Prop from "pkg/prop/prop"
import Scanners from "../sqlite_scanners"

# These read the statement cache of the native driver (`shorts`), so the FFI run of CI leaves this file out.
RUNS = 100

def test_a_read_runs_in_a_short_call_by_its_words_on_sqlite() -> Result[Void]
  Prop.check(Scanners.read_gen(), Prop.Config(runs: RUNS)) do |read| Scanners.read_runs_short_as_modelled(read) end
end

def test_a_pragma_ends_the_short_writes_by_its_name_on_sqlite() -> Result[Void]
  Prop.check(Scanners.pragma_gen(), Prop.Config(runs: RUNS)) do |pragma|
    Scanners.pragma_ends_short_writes_as_modelled(pragma)
  end
end
