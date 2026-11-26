#!/usr/bin/env bash
# Builds the compiler, compiles and runs every example program comparing its
# output with the .out file next to it (the concurrent ones also under Go's
# race detector), checks that every program in failing/ fails at run time,
# replays every session in repl/, runs search-path/ (modules found through
# -i and HAGO_PATH, hago run in a Go module), and checks that every file in
# rejected/ fails with the error announced on its "-- expects:" line, with
# hago build and with hago check, which must pass every example and module of
# the library. Modules
# are compiled with an empty cache, and every example again with the cache
# full, which must give the same Go. The reference in docs/library must be
# what hago doc makes, and hago fmt must keep every file's meaning and comments.
set -euo pipefail
cd "$(dirname "$0")"

cabal build -v0 exe:hago
# the runtime, in both versions (see runtime/concurrent.go)
(cd runtime && go vet runtime.go thunk_sequential.go lib_*.go && go vet -tags hago_concurrent runtime.go concurrent.go lib_*.go)
hago=$(cabal list-bin -v0 exe:hago)
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
export HAGO_CACHE="$out/cache"
unset HAGO_PATH

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

# hago check: every example, module of the library and the Prelude passes,
# and every rejected program fails with its error, as hago build does
checked=1
for f in $(find examples lib -name '*.hgo' | sort) prelude/Prelude.hgo; do
  if ! output=$("$hago" check "$f" 2>&1); then
    echo "FAIL hago check $f:"; echo "$output"; failures=1; checked=0
  fi
done
for f in rejected/*.hgo; do
  expected=$(sed -n 's/^-- expects: //p' "$f")
  if output=$("$hago" check "$f" 2>&1) || ! grep -qF "$expected" <<<"$output"; then
    echo "FAIL hago check $f gave:"; echo "$output"; failures=1; checked=0
  fi
done
[ $checked == 1 ] && echo "ok   hago check passes every example and module, and fails every rejected program"

# the library's reference in docs/library is what hago doc makes now
"$hago" doc -o "$out/docs"
if diff -r "$out/docs" docs/library >/dev/null; then
  echo "ok   docs/library is up to date"
else
  echo "FAIL docs/library is not what hago doc makes; run it:"; diff -r "$out/docs" docs/library | head -20 || true; failures=1
fi

# hago fmt on a copy of every .hgo file but rejected/'s. It checks itself that
# the syntax tree and the comments stay the same, and fails otherwise; here,
# that only blank lines and whitespace at the ends of lines changed, and that
# running it again changes nothing
mkdir -p "$out/fmt"
formatted=1
for f in $(find examples lib prelude -name '*.hgo' | sort); do
  copy="$out/fmt/$(echo "$f" | tr / _)"
  cp "$f" "$copy"
  if ! output=$("$hago" fmt "$copy" 2>&1); then
    echo "FAIL hago fmt $f:"; echo "$output"; failures=1; formatted=0
  elif ! cmp -s <(sed 's/[[:space:]]*$//' "$f" | grep -v '^$') <(grep -v '^$' "$copy"); then
    echo "FAIL hago fmt $f changed more than blank lines and trailing whitespace"; failures=1; formatted=0
  elif ! "$hago" fmt --check "$copy" >/dev/null; then
    echo "FAIL hago fmt $f is not the same when run again"; failures=1; formatted=0
  fi
done
[ $formatted == 1 ] && echo "ok   hago fmt keeps every file's syntax tree and comments, and gives the same file again"

# a session at the prompt: the lines after "hago> " and "hago| " are typed,
# and the transcript must come out the same
for t in repl/*.txt; do
  if actual=$(sed -n 's/^hago[>|] //p' "$t" | "$hago" repl 2>&1) && [ "$actual" == "$(cat "$t")" ]; then
    echo "ok   $t"
  else
    echo "FAIL $t gave:"; diff <(echo "$actual") "$t" || true; failures=1
  fi
done

# modules looked for next to the program, then in -i's directories, then in
# HAGO_PATH's; hago run builds in the Go module of the go.mod above the
# program, whose own Go package it uses, and refuses that program without one
if actual=$(HAGO_PATH=search-path/second "$hago" run -i search-path/first search-path/Main.hgo 2>&1) && [ "$actual" == "$(cat search-path/Main.out)" ] \
  && HAGO_PATH=search-path/second "$hago" check -i search-path/first search-path/Main.hgo; then
  echo "ok   search-path/Main.hgo, with -i and HAGO_PATH, in its Go module"
else
  echo "FAIL search-path/Main.hgo printed:"; echo "$actual"; failures=1
fi
cp -R search-path "$out/no-go-mod" && rm "$out/no-go-mod/go.mod"
if output=$("$hago" run -i "$out/no-go-mod/first" -i "$out/no-go-mod/second" "$out/no-go-mod/Main.hgo" 2>&1) || ! grep -qF "so it needs a go.mod" <<<"$output"; then
  echo "FAIL search-path/Main.hgo without a go.mod gave:"; echo "$output"; failures=1
else
  echo "ok   search-path/Main.hgo without a go.mod is refused"
fi
if output=$("$hago" check search-path/Main.hgo 2>&1) || ! grep -qF "cannot find module Shared (looked for search-path/Shared.hgo)" <<<"$output"; then
  echo "FAIL search-path/Main.hgo without -i gave:"; echo "$output"; failures=1
else
  echo "ok   search-path/Main.hgo without -i cannot find its modules"
fi

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
