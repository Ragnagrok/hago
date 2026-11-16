#!/usr/bin/env bash
# Builds the compiler, compiles and runs every example program comparing its
# output with the .out file next to it, and checks that every file in rejected/ fails
# with the error announced on its "-- expects:" line. Modules are compiled with an
# empty cache, and every example again with the cache full, which must give the
# same Go.
set -euo pipefail
cd "$(dirname "$0")"

cabal build -v0 exe:hago
hago=$(cabal list-bin -v0 exe:hago)
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
export HAGO_CACHE="$out/cache"

failures=0
# a program has an .out next to it; the other .hgo files are its modules
for expected_out in examples/*.out; do
  name=$(basename "$expected_out" .out)
  f="examples/$name.hgo"
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

# separate compilation: what the cache keeps gives the same program
for expected_out in examples/*.out; do
  name=$(basename "$expected_out" .out)
  if [ -f "$out/$name/main.go" ] && ! { "$hago" build "examples/$name.hgo" -o "$out/$name/again.go" && cmp -s "$out/$name/main.go" "$out/$name/again.go"; }; then
    echo "FAIL examples/$name.hgo gives different Go with the cache full"; failures=1
  fi
done
echo "ok   every example gives the same Go with the cache full"

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
