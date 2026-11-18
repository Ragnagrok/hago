#!/usr/bin/env bash
# Builds the compiler, compiles and runs every example program comparing its
# output with the .out file next to it (the concurrent ones also under Go's
# race detector), checks that every program in failing/ fails at run time,
# replays every session in repl/, and checks that every file in rejected/ fails
# with the error announced on its "-- expects:" line. Modules are compiled with an
# empty cache, and every example again with the cache full, which must give the
# same Go.
set -euo pipefail
cd "$(dirname "$0")"

cabal build -v0 exe:hago
# the runtime, in both versions (see runtime/concurrent.go)
(cd runtime && go vet runtime.go thunk_sequential.go && go vet -tags hago_concurrent runtime.go concurrent.go)
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

# the concurrent examples again under Go's race detector, which fails a
# program that touches memory from two goroutines without synchronising
for f in examples/concurrent-*.hgo examples/parallel.hgo examples/http-server.hgo; do
  name=$(basename "$f" .hgo)
  if actual=$(cd "$out/$name" && go run -race main.go 2>&1) && [ "$actual" == "$(cat "examples/$name.out")" ]; then
    echo "ok   $f under the race detector"
  else
    echo "FAIL $f under the race detector printed:"; echo "$actual"; failures=1
  fi
done

# programs that compile, and then fail as their "-- expects:" line says
for f in failing/*.hgo; do
  expected=$(sed -n 's/^-- expects: //p' "$f")
  name=failing-$(basename "$f" .hgo)
  mkdir -p "$out/$name"
  if ! "$hago" build "$f" -o "$out/$name/main.go"; then
    echo "FAIL $f doesn't compile"; failures=1; continue
  fi
  (cd "$out/$name" && go build -o prog main.go)
  if output=$("$out/$name/prog" 2>&1); then
    echo "FAIL $f didn't fail"; failures=1
  elif [ "$(head -1 <<<"$output")" == "$expected" ] && [ "$(wc -l <<<"$output")" -eq 1 ]; then
    echo "ok   $f fails: $expected"
  else
    echo "FAIL $f failed with:"; echo "$output"; failures=1
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

# a session at the prompt: the lines after "hago> " and "hago| " are typed,
# and the transcript must come out the same
for t in repl/*.txt; do
  if actual=$(sed -n 's/^hago[>|] //p' "$t" | "$hago" repl 2>&1) && [ "$actual" == "$(cat "$t")" ]; then
    echo "ok   $t"
  else
    echo "FAIL $t gave:"; diff <(echo "$actual") "$t" || true; failures=1
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
