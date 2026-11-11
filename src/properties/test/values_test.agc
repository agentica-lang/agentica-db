import Store from "../store"

# Each test writes 100 generated rows and reads them back. The adapter is in the name like in the scenarios ("on
# sqlite" is what the CI of macOS and Windows keeps). CI runs the file once per driver (AGENTICA_DB_SQLITE_DRIVER and
# AGENTICA_DB_POSTGRES_DRIVER name it, and one process runs one driver): each run checks its driver against the same
# model of what the database holds, so the two drivers agree on every row the generators make.
RUNS = 100

def test_a_row_reads_back_as_written_on_sqlite() -> Result[Void] = Store.reads_back(Store.Adapter.Sqlite, RUNS)

def test_a_row_reads_back_as_written_on_postgres() -> Result[Void] = Store.reads_back(Store.Adapter.Postgres, RUNS)

# MySQL and MariaDB have the FFI driver only (agentica-lang/agentica-db#77), which makes a call for each value: 50 rows
# fit the step budget of a test with room to spare, so the 100 are two tests.
def test_a_row_reads_back_as_written_on_mysql() -> Result[Void] = Store.reads_back(Store.Adapter.Mysql, RUNS / 2)

def test_a_second_row_reads_back_as_written_on_mysql() -> Result[Void]
  Store.reads_back(Store.Adapter.Mysql, RUNS / 2)
end
