#!/usr/bin/env bash
# Builds the compiler, compiles and runs every example comparing its output
# with the .out file next to it, and checks that every file in rejected/ fails
# with the error announced on its "-- expects:" line.
set -euo pipefail
cd "$(dirname "$0")"

cabal build -v0 exe:hago
hago=$(cabal list-bin -v0 exe:hago)
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

failures=0
for f in examples/*.hgo; do
  name=$(basename "$f" .hgo)
  mkdir -p "$out/$name"
  if ! "$hago" build "$f" -o "$out/$name/main.go"; then
    echo "FAIL $f doesn't compile"; failures=1; continue
  fi
  if actual=$(cd "$out/$name" && go run main.go 2>&1) && [ "$actual" == "$(cat "examples/$name.out")" ]; then
    echo "ok   $f"
  else
    echo "FAIL $f printed:"; echo "$actual"; failures=1
  fi
done

for f in rejected/*.hgo; do
  expected=$(sed -n 's/^-- expects: //p' "$f")
  if output=$("$hago" build "$f" -o "$out/rejected.go" 2>&1); then
    echo "FAIL $f compiled, and it shouldn't"; failures=1
  elif grep -qF "$expected" <<<"$output"; then
    echo "ok   $f is rejected: $expected"
  else
    echo "FAIL $f is rejected, but not for the expected reason:"; echo "$output"; failures=1
  fi
done
exit $failures
