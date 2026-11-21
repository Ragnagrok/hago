// Mutable structures, for Data.IORef, Data.STRef, Data.Vector.Mutable and
// Data.HashTable. A program gets this part of the runtime only if it uses
// one of its functions; see runtime.go.
//
// An IORef can be shared by threads: it is an atomic pointer to its value.
// An STRef never is (runST runs on one goroutine), so it is a plain cell.
// A vector or a table made in IO by a program that may run on several
// goroutines has a lock, taken by each operation; one made in ST, or by a
// program on one goroutine, has none (rt_concurrent is a constant, so the
// test disappears from a program without threads).
package main

import (
	rt_fmt "fmt"
	rt_sync "sync"
	rt_atomic "sync/atomic"
)

// --- runtime ---

// IORef: each value written is a new box, and the reference an atomic
// pointer to it, so a thread never sees half of a value another one is
// writing.
type rt_IORef[A any] struct{ p rt_atomic.Pointer[A] }

func rt_newIORef[A any](x A) *rt_IORef[A] {
	r := &rt_IORef[A]{}
	r.p.Store(&x)
	return r
}

func rt_readIORef[A any](r *rt_IORef[A]) A { return *r.p.Load() }

func rt_writeIORef[A any](r *rt_IORef[A], x A) { r.p.Store(&x) }

// Applies f to the value and writes the result, again if another thread
// wrote in between: f is pure, so running it twice does no harm.
func rt_modifyIORef[A any](r *rt_IORef[A], f func(A) A) {
	for {
		old := r.p.Load()
		x := f(*old)
		if r.p.CompareAndSwap(old, &x) {
			return
		}
	}
}

// The same, where f also gives a result: it gives a pair, which the runtime
// cannot name (tuples are generated), so it comes with its two projections.
func rt_atomicModifyIORef[A, T, B any](r *rt_IORef[A], f func(A) T, fst func(T) A, snd func(T) B) B {
	for {
		old := r.p.Load()
		t := f(*old)
		x := fst(t)
		if r.p.CompareAndSwap(old, &x) {
			return snd(t)
		}
	}
}

// STRef: a cell, read and written by one goroutine.
type rt_STRef[S, A any] struct{ v A }

// The type parameters are in the order Hago's types first mention them.
func rt_newSTRef[A, S any](x A) *rt_STRef[S, A]     { return &rt_STRef[S, A]{x} }
func rt_readSTRef[S, A any](r *rt_STRef[S, A]) A     { return r.v }
func rt_writeSTRef[S, A any](r *rt_STRef[S, A], x A) { r.v = x }

func rt_modifySTRef[S, A any](r *rt_STRef[S, A], f func(A) A) { r.v = f(r.v) }

// A lock for a structure that threads may share: only one made in IO, by a
// program that may run on several goroutines.
func rt_newLock(shared bool) *rt_sync.Mutex {
	if rt_concurrent && shared {
		return new(rt_sync.Mutex)
	}
	return nil
}

// MVector: a Go slice whose length never changes, so only its elements need
// the lock.
type rt_MVector[S, A any] struct {
	xs []A
	mu *rt_sync.Mutex
}

// An index outside the vector ends the program, as it does in Go: the index
// comes from the algorithm, and a vector read out of its bounds is a bug in
// it, which no result could repair.
func rt_mvecCheck(i, n int) {
	if i < 0 || i >= n {
		panic(rt_fmt.Sprintf("index out of range: %d, in a vector of length %d", i, n))
	}
}

func rt_mvecReplicate[A, S any](shared bool, n int, x A) *rt_MVector[S, A] {
	xs := make([]A, max(n, 0))
	for i := range xs {
		xs[i] = x
	}
	return &rt_MVector[S, A]{xs, rt_newLock(shared)}
}

func rt_mvecGenerate[A, S any](shared bool, n int, f func(int) A) *rt_MVector[S, A] {
	xs := make([]A, max(n, 0))
	for i := range xs {
		xs[i] = f(i)
	}
	return &rt_MVector[S, A]{xs, rt_newLock(shared)}
}

func rt_mvecLength[S, A any](v *rt_MVector[S, A]) int { return len(v.xs) }

func rt_mvecRead[S, A any](v *rt_MVector[S, A], i int) A {
	rt_mvecCheck(i, len(v.xs))
	if v.mu == nil {
		return v.xs[i]
	}
	v.mu.Lock()
	x := v.xs[i]
	v.mu.Unlock()
	return x
}

func rt_mvecReadMaybe[S, A any](v *rt_MVector[S, A], i int) (A, error) {
	if i < 0 || i >= len(v.xs) {
		var zero A
		return zero, rt_outOfRange
	}
	return rt_mvecRead(v, i), nil
}

func rt_mvecWrite[S, A any](v *rt_MVector[S, A], i int, x A) {
	rt_mvecCheck(i, len(v.xs))
	if v.mu == nil {
		v.xs[i] = x
		return
	}
	v.mu.Lock()
	v.xs[i] = x
	v.mu.Unlock()
}

func rt_mvecModify[S, A any](v *rt_MVector[S, A], f func(A) A, i int) {
	rt_mvecCheck(i, len(v.xs))
	if v.mu == nil {
		v.xs[i] = f(v.xs[i])
		return
	}
	v.mu.Lock()
	defer v.mu.Unlock()
	v.xs[i] = f(v.xs[i])
}

func rt_mvecSwap[S, A any](v *rt_MVector[S, A], i, j int) {
	rt_mvecCheck(i, len(v.xs))
	rt_mvecCheck(j, len(v.xs))
	if v.mu != nil {
		v.mu.Lock()
		defer v.mu.Unlock()
	}
	v.xs[i], v.xs[j] = v.xs[j], v.xs[i]
}

// Writes x in every element.
func rt_mvecSet[S, A any](v *rt_MVector[S, A], x A) {
	if v.mu != nil {
		v.mu.Lock()
		defer v.mu.Unlock()
	}
	for i := range v.xs {
		v.xs[i] = x
	}
}

// A copy, which later writes do not change.
func rt_mvecFreeze[S, A any](v *rt_MVector[S, A]) []A {
	if v.mu != nil {
		v.mu.Lock()
		defer v.mu.Unlock()
	}
	return append([]A(nil), v.xs...)
}

func rt_mvecThaw[A, S any](shared bool, xs []A) *rt_MVector[S, A] {
	return &rt_MVector[S, A]{append([]A(nil), xs...), rt_newLock(shared)}
}

// HashTable: a Go map. Its keys must be comparable, which a type parameter
// of generated code is not (it is declared with any), so the map is kept
// as an any: the operations are only called from code specialised to a key
// type that Data.HashTable's class Key allows, which Go compares by value.
type rt_HashTable[S, K, V any] struct {
	m  any // map[K]V
	mu *rt_sync.Mutex
}

func rt_tableNew[S any, K comparable, V any](shared bool) *rt_HashTable[S, K, V] {
	return &rt_HashTable[S, K, V]{map[K]V{}, rt_newLock(shared)}
}

func (t *rt_HashTable[S, K, V]) lock() {
	if t.mu != nil {
		t.mu.Lock()
	}
}

func (t *rt_HashTable[S, K, V]) unlock() {
	if t.mu != nil {
		t.mu.Unlock()
	}
}

func rt_tableInsert[S any, K comparable, V any](t *rt_HashTable[S, K, V], k K, v V) {
	m := t.m.(map[K]V)
	t.lock()
	m[k] = v
	t.unlock()
}

func rt_tableLookup[S any, K comparable, V any](t *rt_HashTable[S, K, V], k K) (V, error) {
	m := t.m.(map[K]V)
	t.lock()
	v, ok := m[k]
	t.unlock()
	if !ok {
		return v, rt_outOfRange
	}
	return v, nil
}

func rt_tableMember[S any, K comparable, V any](t *rt_HashTable[S, K, V], k K) bool {
	m := t.m.(map[K]V)
	t.lock()
	_, ok := m[k]
	t.unlock()
	return ok
}

func rt_tableDelete[S any, K comparable, V any](t *rt_HashTable[S, K, V], k K) {
	m := t.m.(map[K]V)
	t.lock()
	delete(m, k)
	t.unlock()
}

func rt_tableSize[S any, K comparable, V any](t *rt_HashTable[S, K, V]) int {
	m := t.m.(map[K]V)
	t.lock()
	n := len(m)
	t.unlock()
	return n
}

// Inserts f new old if the key is there, new if it is not.
func rt_tableInsertWith[S any, K comparable, V any](t *rt_HashTable[S, K, V], f func(V, V) V, k K, v V) {
	m := t.m.(map[K]V)
	t.lock()
	defer t.unlock()
	if old, ok := m[k]; ok {
		v = f(v, old)
	}
	m[k] = v
}

// What f makes of the value at k (Nothing if there is none): a value to
// keep, or Nothing to delete it. Maybe is generated, so it comes with what
// the runtime needs to make one and look inside it.
func rt_tableAlter[S any, K comparable, V, M any](t *rt_HashTable[S, K, V], k K, f func(M) M, nothing M, just func(V) M, isJust func(M) bool, fromJust func(M) V) {
	m := t.m.(map[K]V)
	t.lock()
	defer t.unlock()
	before := nothing
	if old, ok := m[k]; ok {
		before = just(old)
	}
	after := f(before)
	if isJust(after) {
		m[k] = fromJust(after)
	} else {
		delete(m, k)
	}
}

// The pairs, in Go's order, which is different on each run.
func rt_tableToList[S any, K comparable, V, P any](t *rt_HashTable[S, K, V], pair func(K, V) P) List[P] {
	m := t.m.(map[K]V)
	t.lock()
	defer t.unlock()
	var l List[P]
	for k, v := range m {
		l = &Cons[P]{pair(k, v), rt_ready(l)}
	}
	return l
}
