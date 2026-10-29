#!/usr/bin/env bash
# Checks every ```agentica block of site/content with `agentica check`, so the samples of the site cannot drift
# from the API. A block that an ```output block follows is also run, and its standard output must be that text.
# A block is a whole program, and must not start a server when it has an output block. A fence that starts with
# `agentica` but has other words, and an output block that no agentica block precedes, are failures too.
# The package is imported as `pkg/db/...`, which this script sets up in a temporary project from the files of
# this checkout: a manifest, a lock with the hash that the build verifies, and deps/db/.
# Needs `agentica` on PATH. Usage: tools/check-site-samples.sh [CONTENT_DIR]
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
content="${1:-$root/site/content}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

command -v agentica >/dev/null || { echo "check-site-samples: agentica is not on PATH" >&2; exit 2; }

# The files of the package: the library modules, not the specs, examples or tests.
mkdir -p "$work/deps/db"
cp "$root/agentica.toml" "$root"/*.agc "$work/deps/db/"
cp -r "$root/orm" "$work/deps/db/orm"

# The hash of the lock (modules.md of the programming skill): for each .agc file (and agentica.toml, which is hashed
# because it has a [native] table) in bytewise order of its path,
# the path, a zero byte, the size in decimal, a zero byte and the bytes.
hash="$(
  cd "$work/deps/db"
  find . \( -name '*.agc' -o -name agentica.toml \) | sed 's|^\./||' | LC_ALL=C sort | while read -r file; do
    printf '%s\0%s\0' "$file" "$(wc -c < "$file")"
    cat "$file"
  done | sha256sum | cut -d' ' -f1
)"
commit="0000000000000000000000000000000000000000"
cat > "$work/agentica.toml" <<TOML
name = "site_samples"

[dependencies]
db = { git = "https://github.com/agentica-lang/agentica-db", ref = "$commit" }
TOML
cat > "$work/agentica.lock" <<LOCK
version = 1

[[package]]
name = "db"
git = "https://github.com/agentica-lang/agentica-db"
ref = "$commit"
commit = "$commit"
hash = "sha256:$hash"
LOCK

count=0
failed=0
while IFS= read -r page; do
  # One file per block, named after the path of the page below the content folder (with __ for each /) and the
  # line of the opening fence, so two pages with the same file name cannot collide.
  relative="${page#"$content"/}"
  key="$(echo "${relative%.md}" | sed 's|/|__|g')"
  if ! awk -v dir="$work" -v key="$key" -v page="$page" '
    function fail(message) { printf "FAIL %s:%d: %s\n", page, NR, message > "/dev/stderr"; bad = 1 }
    /^```(agentica|agc)[ \t]*$/ && !inside { inside = 1; name = sprintf("%s/%s-%d.agc", dir, key, NR); next }
    /^```(agentica|agc)/ && !inside {
      fail("words after agentica: a block takes no attributes"); inside = 1; name = "/dev/null"; next
    }
    /^```output[ \t]*$/ && !inside && last != "" { inside = 1; name = last ".out"; last = ""; next }
    /^```output/ && !inside {
      fail("an output block needs an agentica block before it"); inside = 1; name = "/dev/null"; next
    }
    /^```[ \t]*$/ && inside { inside = 0; close(name); if (name ~ /\.agc$/) last = name; next }
    inside { print > name; next }
    /[^ \t]/ { last = "" }
    END { exit bad }
  ' "$page"; then
    failed=$((failed + 1))
  fi
done < <(find "$content" -name '*.md' | LC_ALL=C sort)

for sample in "$work"/*.agc; do
  [ -e "$sample" ] || break
  count=$((count + 1))
  if ! output="$(cd "$work" && agentica check "$sample" 2>&1)"; then
    failed=$((failed + 1))
    echo "FAIL $(basename "$sample")" >&2
    echo "$output" >&2
  elif [ -e "$sample.out" ]; then
    # The output block is the whole standard output; stderr  is not compared.
    actual="$(cd "$work" && timeout 30 agentica "$sample" 2>/dev/null)" || actual="(the program failed)"
    if [ "$actual" != "$(cat "$sample.out")" ]; then
      failed=$((failed + 1))
      echo "FAIL $(basename "$sample"): the output is not the output block" >&2
      echo "$actual" >&2
    fi
  fi
done

if [ "$count" -eq 0 ]; then
  echo "check-site-samples: no agentica blocks found in $content" >&2
  exit 1
fi
echo "check-site-samples: $count blocks, $failed failed"
[ "$failed" -eq 0 ]
