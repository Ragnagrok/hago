#!/usr/bin/env bash
# The programs of the README's Performance section, built with each compiler
# given and timed: the median of nine runs, interleaved, on the eight
# performance cores of an i7-12700K (taskset -c 0-15; change CORES for
# another machine). Every compiler must make programs that print the same.
#
#   bench/run.sh                         # the compiler of this tree
#   bench/run.sh OLD_HAGO NEW_HAGO       # two compilers, side by side
#
# One column of time and one of peak memory per compiler. The JSON input is
# made by bench/json-input.go; the sieve with Data.Map up to ten million,
# 20 s a run, is left out unless SLOW=1.
set -uo pipefail
cd "$(dirname "$0")/.."
here=$(pwd)
cores=${CORES:-0-15}
runs=${RUNS:-9}
if [ $# -eq 0 ]; then cabal build -v0 exe:hago && set -- "$(cabal list-bin -v0 exe:hago)"; fi
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
go run bench/json-input.go > "$work/input.json"

progs=(
  "nfib 40, Int -> Int|bench/nfib.hgo|"
  "nfib 40, (Ord a, Num a), at Int|bench/nfib-poly.hgo|"
  "squares of multiples of 3, lists|bench/squares-list.hgo|"
  "the same with Iter|bench/squares-iter.hgo|"
  "the same over a Vector|bench/squares-vector.hgo|"
  "Pythagorean triples, comprehension|bench/triples-list.hgo|"
  "the same as do over Iter|bench/triples-iter.hgo|"
  "the same with Iter.filter|bench/triples-filter.hgo|"
  "foldr (+) over 10M, recursion|bench/foldr-sum.hgo|"
  "mapM_ over 1M in IO|bench/mapm-io.hgo|"
  "recursive IO loop, 5M|bench/loop-io.hgo|"
  "the same, two functions calling each other|bench/loop-io-mutual.hgo|"
  "mapM_ over 1M in StateT Int IO|bench/mapm-statet.hgo|"
  "50M additions, newtype|bench/meters-newtype.hgo|"
  "50M additions, data|bench/meters-data.hgo|"
  "JSON, 3.7 MB|examples/json.hgo|$work/input.json"
  "fib 32 x 16, map|bench/fib-map.hgo|"
  "fib 32 x 16, parMap|bench/fib-parmap.hgo|"
  "Data.Map, 1M inserts, deletes, lookups|bench/map-insert-delete.hgo|"
  "sieve to 1M, STVector|examples/sieve.hgo|1000000 st"
  "sieve to 1M, Data.Map|examples/sieve.hgo|1000000 map"
  "sieve to 10M, STVector|examples/sieve.hgo|10000000 st"
  "sieve to 10M, in IO|bench/sieve-io.hgo|"
  "sieve to 10M, in IO, with threads|bench/sieve-io-threads.hgo|"
  "frequencies of 1M, HashTable|examples/frequencies.hgo|1000000 table"
  "frequencies of 1M, Data.Map|examples/frequencies.hgo|1000000 map"
)
[ "${SLOW:-0}" == 1 ] && progs+=("sieve to 10M, Data.Map|examples/sieve.hgo|10000000 map")

for p in "${progs[@]}"; do
  IFS='|' read -r label src args <<<"$p"
  n=$(echo "$label" | tr -c 'a-zA-Z0-9\n' '_')
  outs=()
  c=0
  for h in "$@"; do
    d=$work/$c/$n; mkdir -p "$d"
    if ! HAGO_CACHE=$work/cache$c "$h" build "$src" -o "$d/main.go" >/dev/null 2>&1 || ! (cd "$d" && go build -o prog main.go); then
      echo "$label: compiler $c does not build it"; continue 2
    fi
    # shellcheck disable=SC2086
    outs+=("$("$d/prog" $args 2>&1)")
    c=$((c + 1))
  done
  for o in "${outs[@]}"; do [ "$o" == "${outs[0]}" ] || { echo "$label: the outputs differ"; continue 2; }; done
  declare -A times=() mems=()
  for r in $(seq "$runs"); do
    for k in $(seq 0 $((c - 1))); do
      # shellcheck disable=SC2086
      o=$( { /usr/bin/time -f "%e %M" taskset -c "$cores" "$work/$k/$n/prog" $args >/dev/null; } 2>&1 | tail -1)
      times[$k]+="${o% *} "; mems[$k]=${o#* }
    done
  done
  line="| $label |"
  for k in $(seq 0 $((c - 1))); do
    med=$(tr ' ' '\n' <<<"${times[$k]}" | grep . | sort -n | sed -n "$(( (runs + 1) / 2 ))p")
    line+=" $med s | $(( ${mems[$k]} / 1024 )) MB |"
  done
  echo "$line"
  unset times mems
done
cd "$here"
