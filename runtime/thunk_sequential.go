//go:build !hago_concurrent

// Thunks for a program that runs on one goroutine. See runtime.go.
package main

// --- runtime ---

// Thunks.
// A thunk is computed the first time it is forced and remembered. This
// program runs on one goroutine, so it needs no lock: sync.OnceValue cost seven
// allocations per thunk, this costs two. A thunk forced while it is being
// computed is a value defined in terms of itself.
type rt_thunk[T any] struct {
	f     func() T
	v     T
	state uint8 // 0 not computed, 1 computing, 2 computed
}

// A Lazy a is a *rt_thunk[a]: one allocation, and the closure that computes
// it, which is dropped once it has run.
func (t *rt_thunk[T]) force() T {
	if t.state == 2 {
		return t.v
	}
	return t.compute()
}

func (t *rt_thunk[T]) compute() T {
	if t.state == 1 {
		panic("a value is defined in terms of itself")
	}
	t.state = 1
	t.v = t.f()
	t.f = nil
	t.state = 2
	return t.v
}

func rt_lazy[T any](f func() T) *rt_thunk[T] { return &rt_thunk[T]{f: f} }

// A suspension of a value already computed.
func rt_ready[T any](v T) *rt_thunk[T] { return &rt_thunk[T]{v: v, state: 2} }

