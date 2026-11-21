// Runtime support for programs compiled by hago. The compiler copies
// everything below the marker into each generated file; the header only
// exists so this file can be checked on its own with `go vet`.
package main

import (
	rt_bufio "bufio"
	rt_fmt "fmt"
	rt_iter "iter"
	rt_big "math/big"
	rt_os "os"
	rt_filepath "path/filepath"
	rt_slices "slices"
	rt_strconv "strconv"
	rt_strings "strings"
	rt_sync "sync"
	rt_atomic "sync/atomic"
	rt_time "time"
)

// --- runtime ---

// Lists: the head is strict, the tail a memoised thunk.
// A list is a pointer to its first cell, and nil when it is empty.
type List[T any] = *Cons[T]
type Cons[T any] struct {
	F0 T
	F1 *rt_thunk[List[T]]
}

// Every runtime import is used even if the program never prints.
var _ = rt_fmt.Sprint

// Thunks are in thunk_sequential.go or thunk_concurrent.go: the compiler
// copies the concurrent ones only into programs that start goroutines.

var _ = rt_sync.OnceValue[int]
var _ = rt_big.NewInt
var _ = rt_filepath.Base
var _ = rt_time.Now

func rt_error[T any](msg string) T { panic(msg) }

// A program that fails (error, a division by zero) says why on standard
// error and exits with status 1, without Go's trace of the goroutines.
func rt_failed() {
	if r := recover(); r != nil {
		rt_fmt.Fprintln(rt_os.Stderr, "error:", r)
		rt_os.Exit(1)
	}
}

// IO is trampolined: running an action yields either its result or the
// next action to run, and rt_run loops over them. A do block that ends in
// another action, a bind, and *> therefore run in constant stack, so
// recursive IO loops and mapM_ over long lists do not grow the Go stack.
type IO[A any] func() IOStep[A]
type IOStep[A any] struct {
	done bool
	val  A
	next IO[A]
}

func rt_run[A any](m IO[A]) A {
	for {
		s := m()
		if s.done {
			return s.val
		}
		m = s.next
	}
}
func rt_done[A any](v A) IOStep[A]     { return IOStep[A]{done: true, val: v} }
func rt_next[A any](m IO[A]) IOStep[A] { return IOStep[A]{next: m} }
func rt_pure[A any](v A) IO[A]         { return func() IOStep[A] { return IOStep[A]{done: true, val: v} } }
func rt_bind[A, B any](m IO[A], k func(A) IO[B]) IO[B] {
	return func() IOStep[B] { return IOStep[B]{next: k(rt_run(m))} }
}
func rt_then[A, B any](m IO[A], n *rt_thunk[IO[B]]) IO[B] {
	return func() IOStep[B] { rt_run(m); return IOStep[B]{next: n.force()} }
}

// Standard input is read through one buffer, which goroutines take turns at.
var rt_stdin = rt_bufio.NewReader(rt_os.Stdin)
var rt_stdinMu rt_sync.Mutex

var rt_getLine IO[string] = func() IOStep[string] {
	rt_stdinMu.Lock()
	s, _ := rt_stdin.ReadString('\n')
	rt_stdinMu.Unlock()
	return rt_done(rt_strings.TrimRight(s, "\r\n"))
}

// Files, standard input and the command line, called through foreign
// imports in the Prelude and System.Environment.
func rt_getContents() string {
	var sb rt_strings.Builder
	rt_stdinMu.Lock()
	defer rt_stdinMu.Unlock()
	rt_stdin.WriteTo(&sb)
	return sb.String()
}
func rt_readFile(path string) (string, error) {
	b, err := rt_os.ReadFile(path)
	return string(b), err
}
func rt_writeFile(path string, s string) error {
	return rt_os.WriteFile(path, []byte(s), 0o644)
}
func rt_appendFile(path string, s string) error {
	f, err := rt_os.OpenFile(path, rt_os.O_APPEND|rt_os.O_CREATE|rt_os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = f.WriteString(s)
	return err
}

// Whether standard input has nothing more to read.
func rt_isEOF() bool {
	rt_stdinMu.Lock()
	defer rt_stdinMu.Unlock()
	_, err := rt_stdin.Peek(1)
	return err != nil
}

func rt_putErr(s string) { rt_fmt.Fprint(rt_os.Stderr, s) }

func rt_getArgs() List[string] { return rt_stringList(rt_os.Args[1:]) }

func rt_getProgName() string { return rt_filepath.Base(rt_os.Args[0]) }

// SplitMix64 (Steele, Lea and Flood, 2014), for System.Random: a generator
// is its state, the next state adds a constant, and a value is the state
// mixed. Ints are used as the 64 bits they hold.
func rt_splitmixStep(s int) int { return int(uint64(s) + 0x9e3779b97f4a7c15) }

func rt_splitmixMix(s int) int {
	z := uint64(s)
	z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9
	z = (z ^ (z >> 27)) * 0x94d049bb133111eb
	return int(z ^ (z >> 31))
}

// x mod n, with x read as unsigned, for n > 0.
func rt_unsignedMod(x, n int) int { return int(uint64(x) % uint64(n)) }

// A Double in [0, 1) from the top 53 bits.
func rt_unitDouble(x int) float64 { return float64(uint64(x)>>11) / (1 << 53) }

// The generator randomRIO and newStdGen draw from: seeded by the clock, or
// by HAGO_RANDOM_SEED, which makes a run repeatable. It is stepped
// atomically, so goroutines that draw at once each get their own number.
var rt_globalSeed = func() uint64 {
	if s := rt_os.Getenv("HAGO_RANDOM_SEED"); s != "" {
		if n, err := rt_strconv.Atoi(s); err == nil {
			return uint64(rt_splitmixMix(n))
		}
	}
	return uint64(rt_splitmixMix(int(rt_time.Now().UnixNano())))
}()

func rt_nextGlobalSeed() int {
	return rt_splitmixMix(int(rt_atomic.AddUint64(&rt_globalSeed, 0x9e3779b97f4a7c15)))
}

func rt_stringList(ss []string) List[string] {
	var l List[string]
	for i := len(ss) - 1; i >= 0; i-- {
		tail := l
		l = &Cons[string]{ss[i], rt_ready(tail)}
	}
	return l
}

// words and lines, as Haskell has them: lines "a\n" is ["a"], and lines ""
// is [].
func rt_words(s string) List[string] { return rt_stringList(rt_strings.Fields(s)) }

func rt_lines(s string) List[string] {
	if s == "" {
		return nil
	}
	return rt_stringList(rt_strings.Split(rt_strings.TrimSuffix(s, "\n"), "\n"))
}

// Strings, for Data.String. A Go string is sliced without copying.
func rt_firstRune(s string) rune {
	for _, r := range s {
		return r
	}
	return 0
}
func rt_dropRune(s string) string {
	for i := range s {
		if i > 0 {
			return s[i:]
		}
	}
	return ""
}
func rt_concatStrings(l List[string]) string {
	var sb rt_strings.Builder
	for l != nil {
		sb.WriteString(l.F0)
		l = l.F1.force()
	}
	return sb.String()
}

// Haskell's div and mod round towards negative infinity.
func rt_div(a, b int) int {
	q := a / b
	if a%b != 0 && (a < 0) != (b < 0) {
		q--
	}
	return q
}
func rt_mod(a, b int) int {
	m := a % b
	if m != 0 && (m < 0) != (b < 0) {
		m += b
	}
	return m
}

func rt_pack(l List[rune]) string {
	var sb rt_strings.Builder
	for l != nil {
		sb.WriteRune(l.F0)
		l = l.F1.force()
	}
	return sb.String()
}

func rt_unpack(s string) List[rune] {
	rs := []rune(s)
	var from func(i int) List[rune]
	from = func(i int) List[rune] {
		if i >= len(rs) {
			return nil
		}
		return &Cons[rune]{rs[i], rt_lazy(func() List[rune] { return from(i + 1) })}
	}
	return from(0)
}

// Doubles print with a decimal point, as in Haskell.
func rt_showDouble(x float64) string {
	s := rt_strconv.FormatFloat(x, 'g', -1, 64)
	if !rt_strings.ContainsAny(s, ".eIN") {
		s += ".0"
	}
	return s
}

// Integer: a *big.Int that is never changed once made, so values can be shared.

func rt_integerFromInt(n int) *rt_big.Int { return rt_big.NewInt(int64(n)) }

func rt_integerFromString(s string) *rt_big.Int {
	z, _ := new(rt_big.Int).SetString(s, 10)
	return z
}

func rt_integerParse(s string) (*rt_big.Int, error) {
	z, ok := new(rt_big.Int).SetString(s, 10)
	if !ok {
		return nil, rt_fmt.Errorf("not an integer: %q", s)
	}
	return z, nil
}

func rt_integerAdd(a, b *rt_big.Int) *rt_big.Int  { return new(rt_big.Int).Add(a, b) }
func rt_integerSub(a, b *rt_big.Int) *rt_big.Int  { return new(rt_big.Int).Sub(a, b) }
func rt_integerMul(a, b *rt_big.Int) *rt_big.Int  { return new(rt_big.Int).Mul(a, b) }
func rt_integerNeg(a *rt_big.Int) *rt_big.Int     { return new(rt_big.Int).Neg(a) }
func rt_integerQuot(a, b *rt_big.Int) *rt_big.Int { return new(rt_big.Int).Quo(a, b) }
func rt_integerRem(a, b *rt_big.Int) *rt_big.Int  { return new(rt_big.Int).Rem(a, b) }
func rt_integerCompare(a, b *rt_big.Int) int      { return a.Cmp(b) }
func rt_integerShow(a *rt_big.Int) string         { return a.String() }
func rt_integerToInt(a *rt_big.Int) int           { return int(a.Int64()) }

func rt_integerToDouble(a *rt_big.Int) float64 {
	f, _ := new(rt_big.Float).SetInt(a).Float64()
	return f
}

// div and mod round towards minus infinity, as Haskell's do; big.Int's
// DivMod is Euclidean, which differs when the divisor is negative.
func rt_integerDivMod(a, b *rt_big.Int) (*rt_big.Int, *rt_big.Int) {
	q, m := new(rt_big.Int).DivMod(a, b, new(rt_big.Int))
	if b.Sign() < 0 && m.Sign() != 0 {
		q.Sub(q, rt_big.NewInt(1))
		m.Add(m, b)
	}
	return q, m
}

func rt_integerDiv(a, b *rt_big.Int) *rt_big.Int { q, _ := rt_integerDivMod(a, b); return q }
func rt_integerMod(a, b *rt_big.Int) *rt_big.Int { _, m := rt_integerDivMod(a, b); return m }

// Data.Vector: a Vector a is a Go slice, []T, which Hago code never changes:
// every operation that gives a vector makes a new slice.
func rt_vecFromList[T any](l List[T]) []T {
	var v []T
	for ; l != nil; l = l.F1.force() {
		v = append(v, l.F0)
	}
	return v
}

func rt_vecToList[T any](v []T) List[T] {
	var l List[T]
	for i := len(v) - 1; i >= 0; i-- {
		l = &Cons[T]{v[i], rt_ready(l)}
	}
	return l
}

func rt_vecLength[T any](v []T) int { return len(v) }

var rt_outOfRange = rt_fmt.Errorf("out of range")

func rt_vecIndex[T any](v []T, i int) (T, error) {
	if i < 0 || i >= len(v) {
		var zero T
		return zero, rt_outOfRange
	}
	return v[i], nil
}

func rt_vecGenerate[T any](n int, f func(int) T) []T {
	v := make([]T, max(n, 0))
	for i := range v {
		v[i] = f(i)
	}
	return v
}

func rt_vecReplicate[T any](n int, x T) []T {
	v := make([]T, max(n, 0))
	for i := range v {
		v[i] = x
	}
	return v
}

func rt_vecMap[A, B any](f func(A) B, v []A) []B {
	w := make([]B, len(v))
	for i, x := range v {
		w[i] = f(x)
	}
	return w
}

func rt_vecImap[A, B any](f func(int, A) B, v []A) []B {
	w := make([]B, len(v))
	for i, x := range v {
		w[i] = f(i, x)
	}
	return w
}

func rt_vecFilter[T any](p func(T) bool, v []T) []T {
	var w []T
	for _, x := range v {
		if p(x) {
			w = append(w, x)
		}
	}
	return w
}

func rt_vecFoldl[B, A any](f func(B, A) B, z B, v []A) B {
	for _, x := range v {
		z = f(z, x)
	}
	return z
}

func rt_vecAppend[T any](a, b []T) []T {
	return append(append(make([]T, 0, len(a)+len(b)), a...), b...)
}

func rt_vecConcat[T any](vs List[[]T]) []T {
	var w []T
	for ; vs != nil; vs = vs.F1.force() {
		w = append(w, vs.F0...)
	}
	return w
}

// The n elements from i on, or as many as there are. The slice shares the
// array, which nothing ever changes.
func rt_vecSlice[T any](i, n int, v []T) []T {
	i = min(max(i, 0), len(v))
	return v[i:min(i+max(n, 0), len(v))]
}

func rt_vecReverse[T any](v []T) []T {
	w := rt_slices.Clone(v)
	rt_slices.Reverse(w)
	return w
}

// A stable sort, by a function that says whether one element goes before
// another.
func rt_vecSortBy[T any](before func(T, T) bool, v []T) []T {
	w := rt_slices.Clone(v)
	rt_slices.SortStableFunc(w, func(a, b T) int {
		switch {
		case before(a, b):
			return -1
		case before(b, a):
			return 1
		}
		return 0
	})
	return w
}

func rt_vecZipWith[A, B, C any](f func(A, B) C, a []A, b []B) []C {
	w := make([]C, min(len(a), len(b)))
	for i := range w {
		w[i] = f(a[i], b[i])
	}
	return w
}

func rt_vecToIter[T any](v []T) rt_iter.Seq[T] { return rt_slices.Values(v) }

func rt_vecFromIter[T any](s rt_iter.Seq[T]) []T { return rt_slices.Collect(s) }

// Data.Iter: an Iter a is Go's iter.Seq[T], a function that gives its values
// one by one to a function of the consumer's, which says whether it wants
// more. Each stage of a pipeline is one function; no value is allocated per
// element. Consuming an Iter twice computes it twice.
func rt_iterFrom(n int) rt_iter.Seq[int] {
	return func(yield func(int) bool) {
		for i := n; yield(i); i++ {
		}
	}
}

// From a to b, both included.
func rt_iterRange(a, b int) rt_iter.Seq[int] {
	return func(yield func(int) bool) {
		for i := a; i <= b && yield(i); i++ {
		}
	}
}

func rt_iterIterate[T any](f func(T) T, x T) rt_iter.Seq[T] {
	return func(yield func(T) bool) {
		for v := x; yield(v); v = f(v) {
		}
	}
}

// An Iter with no values: a generic function, which Go makes an iter.Seq of
// once its type is given, so it needs no allocation.
func rt_iterEmpty[T any](yield func(T) bool) {}

func rt_iterSingleton[T any](x T) rt_iter.Seq[T] {
	return func(yield func(T) bool) { yield(x) }
}

func rt_iterRepeat[T any](x T) rt_iter.Seq[T] {
	return func(yield func(T) bool) {
		for yield(x) {
		}
	}
}

func rt_iterFromList[T any](l List[T]) rt_iter.Seq[T] {
	return func(yield func(T) bool) {
		for c := l; c != nil && yield(c.F0); c = c.F1.force() {
		}
	}
}

func rt_iterToList[T any](s rt_iter.Seq[T]) List[T] {
	return rt_vecToList(rt_slices.Collect(s))
}

func rt_iterMap[A, B any](f func(A) B, s rt_iter.Seq[A]) rt_iter.Seq[B] {
	return func(yield func(B) bool) {
		for x := range s {
			if !yield(f(x)) {
				return
			}
		}
	}
}

func rt_iterFilter[T any](p func(T) bool, s rt_iter.Seq[T]) rt_iter.Seq[T] {
	return func(yield func(T) bool) {
		for x := range s {
			if p(x) && !yield(x) {
				return
			}
		}
	}
}

func rt_iterTakeWhile[T any](p func(T) bool, s rt_iter.Seq[T]) rt_iter.Seq[T] {
	return func(yield func(T) bool) {
		for x := range s {
			if !p(x) || !yield(x) {
				return
			}
		}
	}
}

func rt_iterDropWhile[T any](p func(T) bool, s rt_iter.Seq[T]) rt_iter.Seq[T] {
	return func(yield func(T) bool) {
		dropping := true
		for x := range s {
			if dropping && p(x) {
				continue
			}
			dropping = false
			if !yield(x) {
				return
			}
		}
	}
}

func rt_iterTake[T any](n int, s rt_iter.Seq[T]) rt_iter.Seq[T] {
	return func(yield func(T) bool) {
		if n <= 0 {
			return
		}
		i := 0
		for x := range s {
			i++
			if !yield(x) || i >= n {
				return
			}
		}
	}
}

func rt_iterDrop[T any](n int, s rt_iter.Seq[T]) rt_iter.Seq[T] {
	return func(yield func(T) bool) {
		i := 0
		for x := range s {
			i++
			if i > n && !yield(x) {
				return
			}
		}
	}
}

func rt_iterConcatMap[A, B any](f func(A) rt_iter.Seq[B], s rt_iter.Seq[A]) rt_iter.Seq[B] {
	return func(yield func(B) bool) {
		for x := range s {
			for y := range f(x) {
				if !yield(y) {
					return
				}
			}
		}
	}
}

func rt_iterAppend[T any](a, b rt_iter.Seq[T]) rt_iter.Seq[T] {
	return func(yield func(T) bool) {
		for x := range a {
			if !yield(x) {
				return
			}
		}
		for x := range b {
			if !yield(x) {
				return
			}
		}
	}
}

// The second Iter is read with iter.Pull, which runs it as a coroutine, so
// zipWith costs more per element than the other stages.
func rt_iterZipWith[A, B, C any](f func(A, B) C, a rt_iter.Seq[A], b rt_iter.Seq[B]) rt_iter.Seq[C] {
	return func(yield func(C) bool) {
		next, stop := rt_iter.Pull(b)
		defer stop()
		for x := range a {
			y, ok := next()
			if !ok || !yield(f(x, y)) {
				return
			}
		}
	}
}

func rt_iterFoldl[B, A any](f func(B, A) B, z B, s rt_iter.Seq[A]) B {
	for x := range s {
		z = f(z, x)
	}
	return z
}

var rt_notFound = rt_fmt.Errorf("not found")

// The first value that satisfies p; the rest is not computed.
func rt_iterFind[T any](p func(T) bool, s rt_iter.Seq[T]) (T, error) {
	for x := range s {
		if p(x) {
			return x, nil
		}
	}
	var zero T
	return zero, rt_notFound
}

func rt_iterMapM_[T any](f func(T) IO[struct{}], s rt_iter.Seq[T]) {
	for x := range s {
		rt_run(f(x))
	}
}

func rt_iterLines(s string) rt_iter.Seq[string] {
	return func(yield func(string) bool) {
		for len(s) > 0 {
			i := rt_strings.IndexByte(s, '\n')
			if i < 0 {
				yield(s)
				return
			}
			if !yield(rt_strings.TrimSuffix(s[:i], "\r")) {
				return
			}
			s = s[i+1:]
		}
	}
}

func rt_iterWords(s string) rt_iter.Seq[string] { return rt_strings.FieldsSeq(s) }

func rt_iterChars(s string) rt_iter.Seq[rune] {
	return func(yield func(rune) bool) {
		for _, c := range s {
			if !yield(c) {
				return
			}
		}
	}
}

// Data.Ratio: a Rational is a *big.Rat that is never modified, always in
// lowest terms with a positive denominator.
func rt_ratMake(n, d *rt_big.Int) *rt_big.Rat {
	if d.Sign() == 0 {
		panic("division by zero")
	}
	return new(rt_big.Rat).SetFrac(n, d)
}

func rt_ratFromInt(n int) *rt_big.Rat             { return new(rt_big.Rat).SetInt64(int64(n)) }
func rt_ratFromInteger(n *rt_big.Int) *rt_big.Rat { return new(rt_big.Rat).SetInt(n) }

// The exact value of a Double: 0.1 is 3602879701896397 % 36028797018963968.
func rt_ratFromDouble(x float64) *rt_big.Rat {
	r := new(rt_big.Rat)
	if r.SetFloat64(x) == nil {
		panic("a Rational from a Double that is not a number or is infinite")
	}
	return r
}

func rt_ratAdd(a, b *rt_big.Rat) *rt_big.Rat { return new(rt_big.Rat).Add(a, b) }
func rt_ratSub(a, b *rt_big.Rat) *rt_big.Rat { return new(rt_big.Rat).Sub(a, b) }
func rt_ratMul(a, b *rt_big.Rat) *rt_big.Rat { return new(rt_big.Rat).Mul(a, b) }
func rt_ratNeg(a *rt_big.Rat) *rt_big.Rat    { return new(rt_big.Rat).Neg(a) }

func rt_ratQuo(a, b *rt_big.Rat) *rt_big.Rat {
	if b.Sign() == 0 {
		panic("division by zero")
	}
	return new(rt_big.Rat).Quo(a, b)
}

func rt_ratCompare(a, b *rt_big.Rat) int          { return a.Cmp(b) }
func rt_ratNumerator(a *rt_big.Rat) *rt_big.Int   { return new(rt_big.Int).Set(a.Num()) }
func rt_ratDenominator(a *rt_big.Rat) *rt_big.Int { return new(rt_big.Int).Set(a.Denom()) }

func rt_ratToDouble(a *rt_big.Rat) float64 {
	f, _ := a.Float64()
	return f
}

// Data.Time: a Time is Go's time.Time.
func rt_timeNow() rt_time.Time { return rt_time.Now() }

// Seconds from the second time to the first.
func rt_timeDiff(a, b rt_time.Time) float64 { return a.Sub(b).Seconds() }

func rt_timeAdd(seconds float64, t rt_time.Time) rt_time.Time {
	return t.Add(rt_time.Duration(seconds * float64(rt_time.Second)))
}

func rt_timeFromUnix(seconds int) rt_time.Time           { return rt_time.Unix(int64(seconds), 0).UTC() }
func rt_timeUnix(t rt_time.Time) int                     { return int(t.Unix()) }
func rt_timeUTC(t rt_time.Time) rt_time.Time             { return t.UTC() }
func rt_timeLocal(t rt_time.Time) rt_time.Time           { return t.Local() }
func rt_timeFormat(layout string, t rt_time.Time) string { return t.Format(layout) }

func rt_timeParse(layout, s string) (rt_time.Time, error) { return rt_time.Parse(layout, s) }

func rt_timeYear(t rt_time.Time) int    { return t.Year() }
func rt_timeMonth(t rt_time.Time) int   { return int(t.Month()) }
func rt_timeDay(t rt_time.Time) int     { return t.Day() }
func rt_timeHour(t rt_time.Time) int    { return t.Hour() }
func rt_timeMinute(t rt_time.Time) int  { return t.Minute() }
func rt_timeSecond(t rt_time.Time) int  { return t.Second() }
func rt_timeWeekday(t rt_time.Time) int { return int(t.Weekday()) }
