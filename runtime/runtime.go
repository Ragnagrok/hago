// Runtime support for programs compiled by hago. The compiler copies
// everything below the marker into each generated file; the header only
// exists so this file can be checked on its own with `go vet`.
package main

import (
	rt_bufio "bufio"
	rt_fmt "fmt"
	rt_os "os"
	rt_reflect "reflect"
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

func (Nil[T]) rt_items() []any { return nil }
func (c Cons[T]) rt_items() []any {
	out := []any{}
	var l List[T] = c
	for {
		cell, ok := l.(Cons[T])
		if !ok {
			return out
		}
		out = append(out, cell.F0)
		l = cell.F1()
	}
}

type Tup2[A, B any] struct {
	F0 A
	F1 B
}
type Tup3[A, B, C any] struct {
	F0 A
	F1 B
	F2 C
}

func (t Tup2[A, B]) rt_fields() []any    { return []any{t.F0, t.F1} }
func (t Tup3[A, B, C]) rt_fields() []any { return []any{t.F0, t.F1, t.F2} }

type rt_lister interface{ rt_items() []any }
type rt_tupler interface{ rt_fields() []any }
type rt_constr interface{ rt_con() (string, int) }

// Thunks.
func rt_ready[T any](v T) func() T          { return func() T { return v } }
func rt_lazy[T any](f func() T) func() T    { return rt_sync.OnceValue(f) }
func rt_error[T any](msg string) T          { panic(msg) }

// IO actions are functions without arguments.
func rt_bind[A, B any](m func() A, k func(A) func() B) func() B {
	return func() B { return k(m())() }
}
func rt_then[A, B any](m func() A, n func() func() B) func() B {
	return func() B { m(); return n()() }
}

var rt_stdin = rt_bufio.NewReader(rt_os.Stdin)

func rt_getLine() string {
	s, _ := rt_stdin.ReadString('\n')
	return rt_strings.TrimRight(s, "\r\n")
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

// Fields of a constructor, forcing the lazy ones.
func rt_conFields(x any) []any {
	v := rt_reflect.ValueOf(x)
	out := make([]any, v.NumField())
	for i := range out {
		f := v.Field(i)
		if f.Kind() == rt_reflect.Func && f.Type().NumIn() == 0 && f.Type().NumOut() == 1 {
			f = f.Call(nil)[0]
		}
		out[i] = f.Interface()
	}
	return out
}

// show, structurally, for any value that is not a function.
func rt_show(x any) string { return rt_showP(0, x) }

func rt_showP(d int, x any) string {
	switch v := x.(type) {
	case int:
		s := rt_strconv.Itoa(v)
		if v < 0 && d > 6 {
			return "(" + s + ")"
		}
		return s
	case bool:
		if v {
			return "True"
		}
		return "False"
	case rune:
		return rt_strconv.QuoteRune(v)
	case string:
		return rt_strconv.Quote(v)
	case struct{}:
		return "()"
	case rt_lister:
		items := v.rt_items()
		if len(items) > 0 {
			if _, ok := items[0].(rune); ok {
				rs := make([]rune, len(items))
				for i, it := range items {
					rs[i] = it.(rune)
				}
				return rt_strconv.Quote(string(rs))
			}
		}
		parts := make([]string, len(items))
		for i, it := range items {
			parts[i] = rt_showP(0, it)
		}
		return "[" + rt_strings.Join(parts, ",") + "]"
	case rt_tupler:
		fs := v.rt_fields()
		parts := make([]string, len(fs))
		for i, f := range fs {
			parts[i] = rt_showP(0, f)
		}
		return "(" + rt_strings.Join(parts, ",") + ")"
	case rt_constr:
		name, _ := v.rt_con()
		fs := rt_conFields(x)
		if len(fs) == 0 {
			return name
		}
		parts := []string{name}
		for _, f := range fs {
			parts = append(parts, rt_showP(11, f))
		}
		s := rt_strings.Join(parts, " ")
		if d > 10 {
			return "(" + s + ")"
		}
		return s
	}
	return rt_fmt.Sprint(x)
}

func rt_eq(a, b any) bool { return rt_compare(a, b) == 0 }

// Structural comparison: constructors by declaration order, then fields.
func rt_compare(a, b any) int {
	switch x := a.(type) {
	case int:
		return rt_cmp(x, b.(int))
	case rune:
		return rt_cmp(x, b.(rune))
	case string:
		return rt_strings.Compare(x, b.(string))
	case bool:
		y := b.(bool)
		switch {
		case x == y:
			return 0
		case !x:
			return -1
		}
		return 1
	case struct{}:
		return 0
	case rt_lister:
		return rt_compareAll(x.rt_items(), b.(rt_lister).rt_items())
	case rt_tupler:
		return rt_compareAll(x.rt_fields(), b.(rt_tupler).rt_fields())
	case rt_constr:
		_, ta := x.rt_con()
		_, tb := b.(rt_constr).rt_con()
		if ta != tb {
			return rt_cmp(ta, tb)
		}
		return rt_compareAll(rt_conFields(a), rt_conFields(b))
	}
	panic("cannot compare values of type " + rt_fmt.Sprintf("%T", a))
}

func rt_compareAll(xs, ys []any) int {
	for i := 0; i < len(xs) && i < len(ys); i++ {
		if c := rt_compare(xs[i], ys[i]); c != 0 {
			return c
		}
	}
	return rt_cmp(len(xs), len(ys))
}

func rt_cmp[T int | rune](a, b T) int {
	switch {
	case a < b:
		return -1
	case a > b:
		return 1
	}
	return 0
}
