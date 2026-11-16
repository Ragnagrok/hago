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
func rt_lazy[T any](f func() T) func() T { return rt_sync.OnceValue(f) }
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
