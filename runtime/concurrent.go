//go:build hago_concurrent

// The runtime of a program that may run on several goroutines: thunks that
// any of them can force, and what Control.Concurrent, its Channel and Async,
// and Control.Parallel are built on. The compiler copies it instead of
// thunk_sequential.go into a program that starts goroutines. See runtime.go.
package main

import (
	rt_fmt "fmt"
	rt_os "os"
	rt_reflect "reflect"
	rt_runtime "runtime"
	rt_sync "sync"
	rt_atomic "sync/atomic"
	rt_syscall "syscall"
	rt_time "time"
)

// --- runtime ---

var _ = rt_reflect.Select
var _ = rt_runtime.Gosched
var _ = rt_syscall.Exec

// Thunks.
// A thunk is computed the first time it is forced and remembered. Several
// goroutines may force it at once: the first computes it holding the
// thunk's lock, the others wait for the value. Once computed, forcing it is
// one atomic load, which on amd64 is a plain one. A value defined in terms of
// itself waits for itself, and Go reports a deadlock.
type rt_thunk[T any] struct {
	f     func() T
	v     T
	state uint32 // 0 not computed, 2 computed; written under mu, read atomically
	mu    rt_sync.Mutex
}

func (t *rt_thunk[T]) force() T {
	if rt_atomic.LoadUint32(&t.state) == 2 {
		return t.v
	}
	return t.compute()
}

func (t *rt_thunk[T]) compute() T {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.state == 2 {
		return t.v
	}
	t.v = t.f()
	t.f = nil
	rt_atomic.StoreUint32(&t.state, 2)
	return t.v
}

func rt_lazy[T any](f func() T) *rt_thunk[T] { return &rt_thunk[T]{f: f} }

// A suspension of a value already computed.
func rt_ready[T any](v T) *rt_thunk[T] { return &rt_thunk[T]{v: v, state: 2} }

// When every goroutine is blocked, Go stops the program with "fatal error:
// all goroutines are asleep - deadlock!", followed by the trace of each one.
// Only GOTRACEBACK=none, read when the program starts, leaves the first line
// alone, so the program starts itself again with it set.
func init() {
	if rt_os.Getenv("GOTRACEBACK") != "" {
		return
	}
	exe, err := rt_os.Executable()
	if err != nil {
		return
	}
	// Exec only returns if it fails; the program then runs with the traces.
	rt_syscall.Exec(exe, rt_os.Args, append(rt_os.Environ(), "GOTRACEBACK=none"))
}

// Threads. A failure in any of them ends the program, as in the main one.
func rt_forkIO(m IO[struct{}]) {
	go func() {
		defer rt_failed()
		rt_run(m)
	}()
}

func rt_threadDelay(micros int) { rt_time.Sleep(rt_time.Duration(micros) * rt_time.Microsecond) }

func rt_yield() { rt_runtime.Gosched() }

func rt_numCapabilities() int { return rt_runtime.GOMAXPROCS(0) }

// An MVar is a box that is empty or holds one value. Taking from an empty
// one, or putting into a full one, waits.
type rt_MVar[T any] struct {
	mu      rt_sync.Mutex
	changed rt_sync.Cond
	full    bool
	v       T
}

func rt_newEmptyMVar[T any]() *rt_MVar[T] {
	m := &rt_MVar[T]{}
	m.changed.L = &m.mu
	return m
}

func rt_newMVar[T any](v T) *rt_MVar[T] {
	m := rt_newEmptyMVar[T]()
	m.full, m.v = true, v
	return m
}

func rt_takeMVar[T any](m *rt_MVar[T]) T {
	m.mu.Lock()
	defer m.mu.Unlock()
	for !m.full {
		m.changed.Wait()
	}
	return m.empty()
}

// Empties a full MVar, holding its lock.
func (m *rt_MVar[T]) empty() T {
	v := m.v
	var zero T
	m.v, m.full = zero, false
	m.changed.Broadcast()
	return v
}

func rt_putMVar[T any](m *rt_MVar[T], v T) {
	m.mu.Lock()
	defer m.mu.Unlock()
	for m.full {
		m.changed.Wait()
	}
	m.v, m.full = v, true
	m.changed.Broadcast()
}

func rt_readMVar[T any](m *rt_MVar[T]) T {
	m.mu.Lock()
	defer m.mu.Unlock()
	for !m.full {
		m.changed.Wait()
	}
	return m.v
}

var rt_emptyMVar = rt_fmt.Errorf("empty")

func rt_tryTakeMVar[T any](m *rt_MVar[T]) (T, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if !m.full {
		var zero T
		return zero, rt_emptyMVar
	}
	return m.empty(), nil
}

func rt_tryReadMVar[T any](m *rt_MVar[T]) (T, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if !m.full {
		var zero T
		return zero, rt_emptyMVar
	}
	return m.v, nil
}

func rt_tryPutMVar[T any](m *rt_MVar[T], v T) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.full {
		return false
	}
	m.v, m.full = v, true
	m.changed.Broadcast()
	return true
}

// Channels are Go's: a buffer of a fixed size (none for 0, when a send waits
// for a receive), and closing one tells the receivers nothing more will come.
type rt_Channel[T any] chan T

func rt_newChannel[T any](size int) rt_Channel[T] {
	if size < 0 {
		panic("newChannel: a negative size")
	}
	return make(rt_Channel[T], size)
}

func rt_send[T any](c rt_Channel[T], v T) {
	defer rt_onClosed("send on a closed channel")
	c <- v
}

func rt_close[T any](c rt_Channel[T]) {
	defer rt_onClosed("close of a closed channel")
	close(c)
}

// Go's own message names a "closed channel" too, but as a runtime error.
func rt_onClosed(msg string) {
	if r := recover(); r != nil {
		panic(msg)
	}
}

var rt_closedChannel = rt_fmt.Errorf("closed")

func rt_receive[T any](c rt_Channel[T]) (T, error) {
	v, ok := <-c
	if !ok {
		return v, rt_closedChannel
	}
	return v, nil
}

// One case of a select: a channel to receive from or send to, or a timer,
// and what to do when it is the one that happens.
type rt_Case[A any] struct {
	c    rt_reflect.SelectCase
	then func(v rt_reflect.Value, ok bool) IO[A]
}

func rt_onReceive[B, A any](c rt_Channel[B], got func(B) IO[A], closed IO[A]) rt_Case[A] {
	return rt_Case[A]{
		rt_reflect.SelectCase{Dir: rt_reflect.SelectRecv, Chan: rt_reflect.ValueOf(c)},
		func(v rt_reflect.Value, ok bool) IO[A] {
			if !ok {
				return closed
			}
			return got(v.Interface().(B))
		},
	}
}

func rt_onSend[B, A any](c rt_Channel[B], v B, sent IO[A]) rt_Case[A] {
	return rt_Case[A]{
		rt_reflect.SelectCase{Dir: rt_reflect.SelectSend, Chan: rt_reflect.ValueOf(c), Send: rt_reflect.ValueOf(&v).Elem()},
		func(rt_reflect.Value, bool) IO[A] { return sent },
	}
}

func rt_after[A any](micros int, then IO[A]) rt_Case[A] {
	timer := rt_time.After(rt_time.Duration(micros) * rt_time.Microsecond)
	return rt_Case[A]{
		rt_reflect.SelectCase{Dir: rt_reflect.SelectRecv, Chan: rt_reflect.ValueOf(timer)},
		func(rt_reflect.Value, bool) IO[A] { return then },
	}
}

// Waits until one of the cases can happen, makes it happen, and gives what
// to do next. If several can, one is chosen at random, as Go does. A send
// to a closed channel fails, as send does.
func rt_select[A any](cases List[rt_Case[A]]) IO[A] {
	var cs []rt_Case[A]
	for l := cases; l != nil; l = l.F1.force() {
		cs = append(cs, l.F0)
	}
	if len(cs) == 0 {
		panic("select with no cases")
	}
	sel := make([]rt_reflect.SelectCase, len(cs))
	for i, c := range cs {
		sel[i] = c.c
	}
	defer rt_onClosed("send on a closed channel")
	i, v, ok := rt_reflect.Select(sel)
	return cs[i].then(v, ok)
}

// Control.Parallel: f applied to every element, on as many goroutines as
// there are processors. f is pure, so the result is the same as map's.
func rt_parMap[A, B any](f func(A) B, xs List[A]) List[B] {
	var in []A
	for l := xs; l != nil; l = l.F1.force() {
		in = append(in, l.F0)
	}
	out := make([]B, len(in))
	workers := min(rt_runtime.GOMAXPROCS(0), len(in))
	var next rt_atomic.Int64
	var wg rt_sync.WaitGroup
	wg.Add(workers)
	for range workers {
		go func() {
			// a failure ends the program before wg.Wait can return
			defer wg.Done()
			defer rt_failed()
			for {
				i := int(next.Add(1) - 1)
				if i >= len(in) {
					return
				}
				out[i] = f(in[i])
			}
		}()
	}
	wg.Wait()
	var l List[B]
	for i := len(out) - 1; i >= 0; i-- {
		l = &Cons[B]{out[i], rt_ready(l)}
	}
	return l
}
