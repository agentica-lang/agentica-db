import Migrations from "../examples/migrations"

# The versions go 1..N with no gap, and N is the number of files of the folder, so a migration file that is
# missing from the list (or a list entry with no file) fails. `Dir.list` is relative to the folder that
# `agentica test` runs in, which is this package.
def main() -> Void
  Test.run([
    Test.test("the migrations of the folder are all in the list, numbered 1 to N") do
      versions = Migrations.all().map do |migration| migration.version end
      try Test.eq(versions, (1..versions.length).to_a)
      files = try Dir.list("examples/migrations")
      return Test.eq(files.length, versions.length)
    end,
  ])
end
