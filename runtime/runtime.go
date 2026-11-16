// Runtime support for programs compiled by hago. The compiler copies
// everything below the marker into each generated file; the header only
// exists so this file can be checked on its own with `go vet`.
package main

import (
	rt_bufio "bufio"
	rt_fmt "fmt"
	rt_os "os"
	rt_strconv "strconv"
	rt_strings "strings"
	rt_sync "sync"
)

// --- runtime ---

// Lists: the head is strict, the tail a memoised thunk.
type List[T any] interface{ isList() }
type Nil[T any] struct{}
type Cons[T any] struct {
	F0 T
	F1 func() List[T]
}

func (Nil[T]) isList()  {}
func (Cons[T]) isList() {}


// Every runtime import is used even if the program never prints.
var _ = rt_fmt.Sprint

// Thunks.
// A thunk is computed the first time it is forced and remembered. Programs
// run on one goroutine, so it needs no lock: sync.OnceValue cost seven
// allocations per thunk, this costs two. A thunk forced while it is being
// computed is a value defined in terms of itself.
type rt_thunk[T any] struct {
	f     func() T
	v     T
	state uint8 // 0 not computed, 1 computing, 2 computed
}

func (t *rt_thunk[T]) force() T {
	if t.state != 2 {
		if t.state == 1 {
			panic("a value is defined in terms of itself")
		}
		t.state = 1
		t.v = t.f()
		t.f = nil
		t.state = 2
	}
	return t.v
}

func rt_lazy[T any](f func() T) func() T { return (&rt_thunk[T]{f: f}).force }

var _ = rt_sync.OnceValue[int]
func rt_error[T any](msg string) T       { panic(msg) }

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
func rt_then[A, B any](m IO[A], n func() IO[B]) IO[B] {
	return func() IOStep[B] { rt_run(m); return IOStep[B]{next: n()} }
}

var rt_stdin = rt_bufio.NewReader(rt_os.Stdin)

var rt_getLine IO[string] = func() IOStep[string] {
	s, _ := rt_stdin.ReadString('\n')
	return rt_done(rt_strings.TrimRight(s, "\r\n"))
}

// Files, standard input and the command line, called through foreign
// imports in the Prelude and System.Environment.
func rt_getContents() string {
	var sb rt_strings.Builder
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
func rt_getArgs() List[string] {
	var l List[string] = Nil[string]{}
	for i := len(rt_os.Args) - 1; i >= 1; i-- {
		tail := l
		l = Cons[string]{rt_os.Args[i], func() List[string] { return tail }}
	}
	return l
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
	for {
		c, ok := l.(Cons[string])
		if !ok {
			return sb.String()
		}
		sb.WriteString(c.F0)
		l = c.F1()
	}
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
	for {
		c, ok := l.(Cons[rune])
		if !ok {
			return sb.String()
		}
		sb.WriteRune(c.F0)
		l = c.F1()
	}
}

func rt_unpack(s string) List[rune] {
	rs := []rune(s)
	var from func(i int) List[rune]
	from = func(i int) List[rune] {
		if i >= len(rs) {
			return Nil[rune]{}
		}
		return Cons[rune]{rs[i], rt_lazy(func() List[rune] { return from(i + 1) })}
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
