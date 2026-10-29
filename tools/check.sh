#!/bin/sh
# Runs `agentica check` on every .agc file of the package, its orm/, examples/, specs/ and test/ folders, and stops
# at the first failure. Needs agentica on PATH. `make check` and the CI jobs on macOS and Windows (which has no make)
# run it, so the list of files is written once.
cd "$(dirname "$0")/.." || exit 1
for file in *.agc */*.agc specs/fixtures/*/*.agc; do
  case $file in deps/*|build/*|tmp/*) continue;; esac
  agentica check "$file" || exit 1
done
