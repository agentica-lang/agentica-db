#!/usr/bin/env bash
# The SQLite scenarios, the users example and the SQLite properties on db_sqlite built as its prebuilt files are:
# with -DDB_SQLITE_STATIC and the SQLite of native/sqlite_static.c instead of the system library
# (.github/workflows/native-prebuilt.yml). CI runs it on Linux, macOS and Windows (Git Bash, with the UCRT64 gcc first
# on PATH). SQLite is compiled once, here, and CC carries the object into each build of the module, so a scenario that
# builds the module with an empty cache does not compile SQLite again. First it checks that the native driver runs
# the linked SQLite, by its version, and that it has the options OMIT_LOAD_EXTENSION and THREADSAFE=1.
set -eo pipefail
cd "$(dirname "$0")/.."

python=python3 compiler=cc root=$PWD pic=(-fPIC) link=(-Wl,--no-as-needed -lm)
case "$(uname -s)" in
  MINGW* | MSYS*) python=python compiler=gcc root=$(pwd -W) pic=() link=() ;;
  Darwin) link=() ;;
esac

rm -rf build/sqlite
version=$("$python" -I tools/sqlite_amalgamation.py build/sqlite)
"$compiler" -c -std=c11 -O2 -fvisibility=hidden "${pic[@]}" -Ibuild/sqlite native/sqlite_static.c \
  -o build/sqlite/sqlite_static.o
export CC="$compiler -DDB_SQLITE_STATIC -I$root/build/sqlite $root/build/sqlite/sqlite_static.o ${link[*]}"
export AGENTICA_DB_SQLITE_DRIVER=native

cat > build/sqlite_version.agc <<'EOF'
import Db from "../db"
import Sqlite from "../sqlite"

def main() -> Void
  conn = Db.open("sqlite::memory:", [Sqlite.driver()]).unwrap!
  puts(Db.query(conn, "select sqlite_version() as v", []).unwrap![0]["v"])
  for row in Db.query(conn, "pragma compile_options", []).unwrap!
    puts(row["compile_options"])
  end

end
EOF
got=$(agentica build/sqlite_version.agc)
first=$(head -n 1 <<< "$got")
if [ "$first" != "Value.Text(\"$version\")" ]; then
  echo "the native driver runs SQLite $first, not the linked $version" >&2
  exit 1
fi
for option in OMIT_LOAD_EXTENSION THREADSAFE=1; do
  if ! grep -qxF "Value.Text(\"$option\")" <<< "$got"; then
    echo "the linked SQLite lacks $option; its options: $got" >&2
    exit 1
  fi
done

agentica test --jobs 4 --only "on sqlite"
agentica test --jobs 4 --only "users example"
cd properties
agentica test --jobs 4 --only "on sqlite"
