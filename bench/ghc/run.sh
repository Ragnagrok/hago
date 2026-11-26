#!/usr/bin/env bash
# Hago against GHC on the same programs: bench/*.hgo and examples/ beside
# bench/ghc/*.hs, written to do the same work (the same algorithms, Hago's
# strict fields as strict fields, JSON's combinators and printer ported as
# they are). Each pair prints the same, but for how Go and Haskell write a
# Double; the median of nine runs, interleaved, on the cores in CORES
# (0-15, the performance cores of an i7-12700K).
#
#   bench/ghc/run.sh            # the hago of this tree, and ghc -O2
#   bench/ghc/run.sh HAGO       # another hago
#
# It needs GHC with cabal; vector, hashtables and parallel are installed
# into a package environment of its own (from Hackage the first time).
set -uo pipefail
cd "$(dirname "$0")/../.."
cores=${CORES:-0-15}
runs=${RUNS:-9}
if [ $# -eq 0 ]; then cabal build -v0 exe:hago && set -- "$(cabal list-bin -v0 exe:hago)"; fi
hago=$1
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
go run bench/json-input.go > "$work/input.json"
cabal install -v0 --lib vector hashtables parallel --package-env "$work/env" || exit 1

ghcBuild() { # name, flags...
  local n=$1; shift
  mkdir -p "$work/ghc/$n"
  ghc -O2 -package-env "$work/env" -package containers -package mtl -package array -package text "$@" \
    -outputdir "$work/ghc/$n" -o "$work/ghc/$n/prog" "bench/ghc/${n%%+*}.hs" > "$work/ghc/$n.log" 2>&1 \
    || { cat "$work/ghc/$n.log"; return 1; }
}

progs=(
  "nfib 40, Int -> Int|bench/nfib.hgo|nfib||"
  "nfib 40, (Ord a, Num a), at Int|bench/nfib-poly.hgo|nfib-poly||"
  "squares of multiples of 3, lists|bench/squares-list.hgo|squares-list||"
  "the same over a Vector (unboxed in GHC)|bench/squares-vector.hgo|squares-vector||"
  "Pythagorean triples, comprehension|bench/triples-list.hgo|triples-list||"
  "foldr (+) over 10M, recursion|bench/foldr-sum.hgo|foldr-sum||"
  "foldr max over 10M|bench/foldr-max.hgo|foldr-max||"
  "foldr over 10M, a step with mod before the rest|bench/foldr-mod.hgo|foldr-mod||"
  "mapM_ over 1M in IO|bench/mapm-io.hgo|mapm-io||"
  "recursive IO loop, 5M|bench/loop-io.hgo|loop-io||"
  "the same, two functions calling each other|bench/loop-io-mutual.hgo|loop-io-mutual||"
  "two pure functions calling each other, 100M|bench/mutual-pure.hgo|mutual-pure||"
  "mapM_ over 1M in StateT Int IO|bench/mapm-statet.hgo|mapm-statet||"
  "50M additions, newtype|bench/meters-newtype.hgo|meters-newtype||"
  "50M additions, data|bench/meters-data.hgo|meters-data||"
  "JSON, 3.7 MB|examples/json.hgo|json||$work/input.json"
  "fib 32 x 16, map|bench/fib-map.hgo|fib-map||"
  "the same, GHC without full laziness|bench/fib-map.hgo|fib-map+nofloat|-fno-full-laziness|"
  "fib 32 x 16, parMap|bench/fib-parmap.hgo|fib-parmap|-threaded -with-rtsopts=-N|"
  "Data.Map, 1M inserts, deletes, lookups|bench/map-insert-delete.hgo|map-insert-delete||"
  "Data.Set, 1M inserts, deletes, lookups|bench/set-insert-delete.hgo|set-insert-delete||"
  "sieve to 1M, Data.Map|examples/sieve.hgo|sieve||1000000 map"
  "sieve to 10M, STVector / STUArray|examples/sieve.hgo|sieve||10000000 st"
  "sieve to 10M, IOVector / IOUArray|bench/sieve-io.hgo|sieve-io||"
  "the same, in a program with threads|bench/sieve-io-threads.hgo|sieve-io-threads|-threaded|"
  "frequencies of 1M, hash table in ST|examples/frequencies.hgo|frequencies||1000000 table"
  "frequencies of 1M, Data.Map|examples/frequencies.hgo|frequencies||1000000 map"
)

echo "| Program | Hago | | GHC | |"
echo "| --- | --- | --- | --- | --- |"
for p in "${progs[@]}"; do
  IFS='|' read -r label src gname gflags args <<<"$p"
  n=$(echo "$label" | tr -c 'a-zA-Z0-9\n' '_')
  d=$work/hago/$n; mkdir -p "$d"
  if ! HAGO_CACHE=$work/cache "$hago" build "$src" -o "$d/main.go" >/dev/null 2>&1 || ! (cd "$d" && go build -o prog main.go); then
    echo "$label: hago does not build it"; continue
  fi
  # shellcheck disable=SC2086
  [ -x "$work/ghc/$gname/prog" ] || ghcBuild "$gname" $gflags || { echo "$label: ghc does not build it"; continue; }
  # shellcheck disable=SC2086
  oh=$("$d/prog" $args 2>&1); og=$("$work/ghc/$gname/prog" $args 2>&1)
  # Go writes 1e+22 where Haskell writes 1.0e22: numbers aside, the same
  strip() { sed -E 's/[0-9][0-9.e+-]*//g'; }
  if [ "$(strip <<<"$oh")" != "$(strip <<<"$og")" ]; then echo "$label: the outputs differ"; continue; fi
  th=(); tg=(); mh=0; mg=0
  for r in $(seq "$runs"); do
    # shellcheck disable=SC2086
    o=$( { /usr/bin/time -f "%e %M" taskset -c "$cores" "$d/prog" $args >/dev/null; } 2>&1 | tail -1); th+=("${o% *}"); mh=${o#* }
    # shellcheck disable=SC2086
    o=$( { /usr/bin/time -f "%e %M" taskset -c "$cores" "$work/ghc/$gname/prog" $args >/dev/null; } 2>&1 | tail -1); tg+=("${o% *}"); mg=${o#* }
  done
  k=$(( (runs + 1) / 2 ))
  medh=$(printf "%s\n" "${th[@]}" | sort -n | sed -n "${k}p"); medg=$(printf "%s\n" "${tg[@]}" | sort -n | sed -n "${k}p")
  echo "| $label | $medh s | $((mh / 1024)) MB | $medg s | $((mg / 1024)) MB |"
done
