// Runtime support for programs compiled by hago. The compiler copies
// everything below the marker into each generated file; the header only
// exists so this file can be checked on its own with `go vet`.
package main

import (
	rt_bufio "bufio"
	rt_fmt "fmt"
	rt_big "math/big"
	rt_filepath "path/filepath"
	rt_time "time"
	rt_os "os"
	rt_strconv "strconv"
	rt_strings "strings"
	rt_sync "sync"
	rt_atomic "sync/atomic"
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
func rt_error[T any](msg string) T       { panic(msg) }

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
func rt_writeFile(path string, s string) (struct{}, error) {
	return struct{}{}, rt_os.WriteFile(path, []byte(s), 0o644)
}
func rt_appendFile(path string, s string) (struct{}, error) {
	f, err := rt_os.OpenFile(path, rt_os.O_APPEND|rt_os.O_CREATE|rt_os.O_WRONLY, 0o644)
	if err != nil {
		return struct{}{}, err
	}
	defer f.Close()
	_, err = f.WriteString(s)
	return struct{}{}, err
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

func rt_integerAdd(a, b *rt_big.Int) *rt_big.Int { return new(rt_big.Int).Add(a, b) }
func rt_integerSub(a, b *rt_big.Int) *rt_big.Int { return new(rt_big.Int).Sub(a, b) }
func rt_integerMul(a, b *rt_big.Int) *rt_big.Int { return new(rt_big.Int).Mul(a, b) }
func rt_integerNeg(a *rt_big.Int) *rt_big.Int    { return new(rt_big.Int).Neg(a) }
func rt_integerQuot(a, b *rt_big.Int) *rt_big.Int { return new(rt_big.Int).Quo(a, b) }
func rt_integerRem(a, b *rt_big.Int) *rt_big.Int  { return new(rt_big.Int).Rem(a, b) }
func rt_integerCompare(a, b *rt_big.Int) int     { return a.Cmp(b) }
func rt_integerShow(a *rt_big.Int) string        { return a.String() }
func rt_integerToInt(a *rt_big.Int) int          { return int(a.Int64()) }

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
