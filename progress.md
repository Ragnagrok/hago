# Progress

What is done, what is next, and what is left out on purpose. Update it in the same commit as the
work it describes.

## Next

From easiest to hardest, which is the order we take them in.

- [x] **Errors quote the source.** The line and a mark under the place, after file:line:column.
- [x] **Re-exports.** `module M` and imported names in an export list.
- [x] **Tuples up to fifteen.** Eq, Ord and Show for every size, `(,,)` as a function, `zip3`
      family; a bigger tuple is an error that suggests a record. Fixed on the way: a chain of `++`
      on strings took exponential time to compile.
- [x] **`Enum` and `Bounded`.** Total (`toEnum`, `succ`, `pred` return `Maybe`), all four range
      forms, instances for `Int`, `Char`, `Bool`, `Ordering`, `()`, `Bounded` tuples, `deriving
      (Enum, Bounded)`. No `Enum Double`, on purpose.
- [x] **Type-changing record updates.** `b { item = "x" }` from `Box Int` to `Box String`, with
      Haskell 98's rule. Fixed on the way: `case` on a constructor application made invalid Go.
- [x] **`Read`.** `read :: Read a => String -> Maybe a`; instances for numbers, `Char`, `String`,
      `Bool`, `()`, lists, tuples, `Maybe`, `Either`, `Ordering`, and `deriving Read` (records too).
      On the way: pattern bindings (`let (a, b) = e`), literals with exponents, `span`, `break`,
      `isSpace` and friends.
- [x] **Share polymorphic top-level values.** A polymorphic value is a template, one shared Go
      variable per concrete instantiation (5.2 s → 0.9 s on a 50-use benchmark). Still recomputed
      when used inside a generic function at its type variable. Fixed on the way: values are
      initialised in dependency order, functions included.
- [x] **Polymorphic local functions.** Generalised in the type checker, in context (so captured
      variables keep their real types, `Lazy` included), then lifted to the top with the local
      variables they use as parameters; constraints on their own variables become theirs. Values,
      and functions constrained on the outer function's types, stay monomorphic.
- [x] **Less visible `Lazy`.** A type variable never stands for `Lazy t`: a function with `Lazy`
      parameters passed where a plain one is expected takes plain arguments (`liftA2 (:)`,
      `map (False &&)`), and `f $ x` is `f x`. Fixed on the way: `foldr (+) 0 xs` and
      `foldr id` were rejected with an infinite type.
- [x] **Multi-parameter classes with functional dependencies.** `class Monad m => MonadState s m | m -> s`:
      the parameter on the left chooses the instance and fixes the others, also while checking
      (after `n <- get`, `n`'s type is known). `get`, `put` and `throwError` work through any
      stack without `lift`; `examples/transformers.hgo` runs one machine on two stacks. One
      dependency, from one parameter to all the others, is required. On the way: code generation
      lost its run-time dictionaries, which specialisation had made unreachable.
- [x] **Stack-safe pure monads.** A standard library compiled into hago: `Control.Monad.State`,
      `Reader`, `Except` and `Trans`, mtl style, over `Data.Functor.Identity`, which is
      trampolined like IO. Ten million steps in `State` run in 10 MB; a hand-written
      `s -> (a, s)` monad still needs `tailRecM` (Go has no tail calls).
- [x] **Separate compilation.** Each module is renamed and type checked on its own, with what its
      imports give it and nothing else, and the result (every type resolved) is cached under a
      key of the compiler, its source and its imports' keys. Specialisation and code generation
      still see the whole program, and now start from `main`: hello world went from 124 KB of Go
      to 5 KB. Compiling an example: 0.35 s cold, 0.15–0.25 s warm.

- [x] **A real program: JSON.** `examples/json.hgo`, a JSON parser on Parsec-style combinators
      (`Text.Parser`, errors with the place and everything expected there) and Wadler's pretty
      printer in Lindig's strict form (`Text.Pretty`). It found, and these are fixed: `'\b'`,
      `'\f'` and `'\x41'` were not escapes; a `where` in the column of a `case`'s alternatives
      was a syntax error; values defined in terms of each other compiled to nil or to wrong
      numbers (`x = y + 1; y = x + 1` printed 1), and now functions among them are computed on
      their first call and the rest are rejected; thunks cost seven allocations
      (`sync.OnceValue`), now two; there was no way to read a file, standard input or the
      arguments (`readFile`, `writeFile`, `getContents`, `System.Environment`), nor to read a
      `String` without unpacking it (`Data.String`). 3.7 MB of JSON: 10.3 s and 1.1 GB at first,
      3.5 s and 140 MB now; `jq .` takes 0.13 s.

- [x] **A REPL.** `hago repl`, for the book (`Ragnagrok/hago-book`), whose sessions it checks:
      definitions accumulate in a module checked as it grows, an expression becomes a program
      that prints or runs it, `:type` shows constraints (the expression typed is generalised
      even as a plain value), `:load` and `:{ :}`. A transcript without a terminal; `repl/`
      sessions are replayed by `check.sh`. The driver compiles modules given as text.

- [x] **Values from actions at the prompt, `:info`, `:browse`.** `pattern <- action` runs the
      action once and keeps what a variable, tuple, `@` or constructor pattern binds: the
      program that runs it also writes `show` of each value (checked to `read` back), and each
      becomes a definition `x :: T; x = read "..."` with the type the action gave it, so
      `:type` sees it. A value without Show and Read (an MVar, a function, an action, a Go
      value), a type left open, or a refutable pattern is refused before anything runs, with
      why and what to do instead; the action is never run again. Other ways to carry a value
      were weighed: replaying the action is wrong (`getLine`, `forkIO`); one long-lived Go
      process cannot load the next line's code (Go has no eval, and `plugin` cannot share a
      runtime's state across builds); serialising Go values (gob) would carry a few more types
      (a `Map` has Show but no Read) but none of those that matter (MVars, functions,
      goroutines) and needs a decoder for every type. Show and Read is the text the language
      already round-trips. `:info` gives a value's type, or a type's or class's declaration
      and instances; `:browse M` what M exports; `:help` lists them.
- [ ] **What the REPL still cannot do.** Keep a value without Show and Read; give an action
      that reads standard input anything without a terminal (the REPL reads all of it);
      redefining a type forgets the values kept of it instead of shadowing it, as GHCi does.
      Line editing: libtinfo is now installed, so haskeline could replace `rlwrap`.

- [x] **`Integer`, and what the book's first chapters use.** Any size, a `*big.Int` never
      modified; literals past `Int` are read from their digits; `toInteger` is a method of
      `Integral`. Also `last` and `init` (with `Maybe`), `words`, `lines`, `notElem`, `scanl`,
      `scanr`, `scanl1`, `scanr1`, `until`, `lcm`, `logBase`.

- [x] **`++` has an honest type.** It was a built-in `a -> Lazy a -> a` that failed at run time
      on anything but lists and Strings (`1 ++ 2` compiled); now it is
      `Semigroup a => a -> Lazy a -> a`. Using a `String` as a list says that it is not one, and
      how to convert.

- [x] **Errors at the operator.** An operator's application is located at the operator, so a
      constraint it raises (`Fractional Int` for `/`, `Eq` on functions for `==`) is reported
      there instead of at the start of the definition, or nowhere.

- [x] **Pattern matches cover every value.** Clauses, `case`, lambdas, pattern bindings and
      `p <- e` in `do` are checked (Maranget's usefulness, reduced to finding one uncovered
      value), and the error shows it. Guards count only if the last is `otherwise` or `True`.
      Found by the book's chapter 4: `describe 3` compiled and failed at run time.
- [x] **Local bindings where they are needed.** A `let` or `where` binding used by some
      branches moves into them, and an unused one is dropped (`Hago/Sink.hs`), so a `where`
      under guards does not fail before the guard that protects it. Also from chapter 4.

- [x] **Failures without Go's traces.** A program that fails (`error`, a division by zero, a
      stack overflow at the prompt) prints `error: ...` and exits with 1, instead of a panic
      with the trace of every goroutine. `hago run FILE ARGS...` passes arguments.

- [x] **`Data.List`, `Data.Char`, `Data.Ord`, `Data.Map`, `Data.Set`,** for the book's chapter on
      modules. Maps and sets are weight-balanced trees, as in containers; nothing partial
      (`!?` instead of `!`, `maximumBy` returns `Maybe`). `intercalate` joins any `Monoid`.
      A million inserts, half a million deletes and lookups took 2.6 s and 590 MB at first
      (see below for now).

- [x] **What the book's chapter on types needed.** `:kind` at the prompt; constructors that
      are operators take applied types on both sides (`a :+: Chain a`), and a derived `Show`
      writes them between their operands, at their declared precedence; a file loaded at the
      prompt shadows the Prelude, as it does in the file itself.

- [x] **Input and output for the book's chapter 9.** `interact`, `appendFile`, `System.IO` (the
      three standard handles under Haskell's names, `isEOF`), `System.Exit`, `getProgName`, and
      `System.Random` (SplitMix64; `HAGO_RANDOM_SEED` repeats a run). No handles on files yet:
      files are read and written whole.

- [x] **`Control.Applicative` (`ZipList`) and `Data.Monoid` (`First`, `Last`, `Min`, `Max`),** for
      the book's chapter 11.

- [x] **`Control.Monad`:** `foldM`, `replicateM`, `filterM`, `zipWithM`, `>=>`, `liftM2`, `ap`,
      `void`, and the Prelude's `when`, `forM_` and the rest, for the book's chapter 12.

- [x] **`Control.Monad.Writer`,** for the book's chapter 13.

Next, found by the JSON program:

- [x] **Data types without allocation, where their shape allows it.** One constructor: its
      struct, by value. A small sum that does not contain itself (up to eight words): one
      struct with a tag, by value. Two constructors, one without fields (lists, trees): a
      pointer, nil for the empty one. A `Lazy` is one pointer to a thunk instead of a closure
      over one, a suspension of a value that is already computed costs one allocation instead
      of three, and the Prelude's `&&` and `||` are Go's. Measured on one machine, each program
      three times, before and after:

      | Program | Before | After |
      | --- | --- | --- |
      | JSON, 3.7 MB, parse and pretty print | 3.6 s, 150 MB | 2.6 s, 145 MB |
      | `Data.Map`: 1M inserts, 500k deletes with `foldr`, lookups | 2.6 s, 570 MB | 1.65 s, 410 MB |
      | the same, deleting with `foldl` | 2.5 s, 220 MB | 1.45 s, 170 MB |
      | `data Meters = Meters Double`, 50M additions | 0.38 s, 10 MB | 0.02 s, 4 MB |

      Most of what is left is Go's garbage collector (half of the CPU time in both). The
      `foldr` version's extra memory is the stack: `foldr` with a strict function recurses
      500k deep.
- [x] **A parser's reply without allocation.** Not by overlapping `Ok`'s and `Failed`'s fields
      (Go has no unions), but by needing fewer: `Reply (Maybe a) String [String]`, one
      constructor of seven words, kept by value. Whether a parser consumed input is whether what
      it left is what it was given (both are suffixes of the input, so `/=` is immediate), and
      the line and column of an error are counted from the input only when `parse` returns it,
      so the parser carries no position. `liftA2`, `*>` and `<*` run both parsers directly
      instead of through `>>=`, which made a parser on every run.
- [x] **Runs of characters in one step.** `Data.String.span`, `break`, `takeWhile`,
      `dropWhile` (slices, found by one Go loop) and `stripSuffix`; `takeWhileP` and
      `takeWhile1P` in `Text.Parser`, which name what was expected where the run stops, as
      `many (satisfy f <?> name)` did, and `match`, what a parser consumed, as a slice.
- [x] **The JSON benchmark, measured with pprof and taken from 1.86 s to 0.32 s.** The input is
      `bench/json-input.go`'s, always the same (3.7 MB of records, with escapes, characters
      outside ASCII, numbers of every form, nesting); `examples/json.hgo FILE` pretty prints a
      file. Each change measured on its own, on an i7-12700K pinned to its performance cores, the
      median of nine runs, all in one interleaved round:

      | Change | Time | CPU | Peak memory |
      | --- | --- | --- | --- |
      | before | 1.86 s | 5.6 s | 98 MB |
      | the reply by value; `liftA2`, `*>`, `<*` without `>>=` (library) | 1.00 s | 3.2 s | 97 MB |
      | runs: white space, the characters of a string, digits (library) | 0.85 s | 2.8 s | 113 MB |
      | `quote` by runs, instead of a `String` per character (library) | 0.60 s | 1.7 s | 87 MB |
      | `null` a method of `Foldable`, without `foldr`'s suspension for lists (Prelude) | 0.53 s | 1.5 s | 84 MB |
      | the pretty printer's stack a type of its own, not a list of triples (library) | 0.51 s | 1.4 s | 89 MB |
      | a list cell and the thunk of its tail in one allocation (compiler) | 0.47 s | 1.3 s | 82 MB |
      | what a parser expects made once, with the parser (library) | 0.43 s | 1.2 s | 83 MB |
      | a number as the slice it matched; the document at hand apart from the printer's stack; documents joined without lists; a string without escapes quoted at once (library) | 0.32 s | 0.8 s | 82 MB |
      | `jq .` | 0.09 s | 0.1 s | 28 MB |

      pprof showed the garbage collector at more than half of the CPU time at first, from 2.2 GB
      allocated (a reply per step, a thunk per list cell, a `String` per character quoted); now
      270 MB. What is left is mostly the pretty printer's documents and lists of pieces, and
      merging what is expected at a choice (`e1 ++ e2`, 10%). On the way, the compiler counted a
      field of a type that contains itself as too big to keep by value, so a record with a `Map`
      or a tree in it was an interface; it now counts as the pointer or interface it is. The
      README's Performance programs were measured before and after on the same machine: the
      lazy list pipeline went from 0.23 s to 0.21 s, the rest did not change.

      **`debug.SetGCPercent(200)` was measured and left out.** It took a third of the CPU and an
      eighth of the time off JSON (0.49 s → 0.43 s) and `Data.Map` (1.30 s → 1.09 s), for half
      again as much memory at the peak (86 → 129 MB, 94 → 145 MB), but made the small IO loops
      up to twice as slow (`mapM_` 0.08 → 0.12 s, the recursive loop 0.09 → 0.17 s, a few KB
      alive in both). Go's default stays; `GOGC=200` can be given to one program.
- [ ] **Decide whether `Text.Parser` and `Text.Pretty` belong in the library.**

Next, concurrency (decided 2026-11-18), in this order:

- [x] **A runtime safe on several goroutines.** Two versions of the thunks: a program that uses
      concurrency gets ones with a lock, taken only to compute, and an atomic load once computed
      (2% slower on the lazy list benchmark); the others keep the ones without. The global
      random seed is stepped atomically, and standard input is read under a lock. A failure in
      any thread ends the program with `error:`. A deadlock is Go's one line
      (`all goroutines are asleep`), without the traces: the program starts itself again with
      `GOTRACEBACK=none`, which Go only reads at start.
- [x] **`Control.Concurrent`:** `forkIO` (no `ThreadId`: Go cannot kill a goroutine), MVars
      (a mutex and a condition, so `readMVar` is atomic), `threadDelay`, `yield`.
- [x] **`Control.Concurrent.Channel`:** Go's channels, with a buffer, `close`, `receive` giving
      `Nothing` once closed, and `select` over `onReceive`, `onSend` and `after`
      (`reflect.Select`).
- [x] **`Control.Concurrent.Async`:** `async`, `wait`, `poll`, `concurrently`, `race` (the loser
      runs to the end), `mapConcurrently`, `forConcurrently`.
- [x] **`Control.Parallel`:** `parMap`, on as many goroutines as processors (16 × `fib 32`:
      0.11 s → 0.02 s on 8).
      On the way: `foreign import go type` for Go types Hago only passes around, and polymorphic
      foreign imports, which call a generic Go function with its types given. The concurrent
      examples run under Go's race detector in `check.sh`, and `failing/` holds programs that
      must fail at run time with a given message.
- [x] **More of Go.** A foreign symbol that starts with a dot is a selector on the first
      argument (`".Query().Get"`), so fields and methods of Go types are reachable. A Hago
      function or action given to a Go function from outside the runtime becomes the Go
      function it expects (all arguments at once, the action run, `defer rt_failed()`), and
      turns on the concurrent runtime. A Go function that returns only an `error` is an
      `Either String ()`. `examples/http-server.hgo` serves pages with `net/http` and asks for
      several at once, under the race detector too; `examples/foreign-types.hgo` has the rest.
- [x] **Chapter 16 of hago-book, "Concurrency"** (first written as 15). On the way: `parMap` computes an element
      only as far as it is strict, so a list element gets only its first cell; the chapter says so.

Next, sequences (decided 2026-11-18): lists stay as they are, lazy cells for recursion,
patterns and sharing; two more kinds of sequence come from Go.

- [x] **Functions given to Go as Go functions of all their arguments.** A lambda, a known
      function, or one given some of its arguments becomes a direct Go function, without the
      curried closures that would allocate on every call.
- [x] **`Data.Vector`:** a Go slice Hago never changes, `Vector String` is Go's `[]string`
      (`foreign import go type "[]" Vector a`), so `strings.Split` returns one.
- [x] **`Data.Iter`:** Go's `iter.Seq`. The README's lazy list benchmark: 0.43 s, 10 MB with
      lists; 0.01 s, 4 MB with `Iter`; 0.01 s, 60 MB with a `Vector`. Not `Foldable`: `foldr`
      would need a lazy rest, which an `Iter` cannot give without running again or keeping
      what it computed (a list).
- [x] **Chapter 15 of hago-book, "Data structures":** lists, vectors, iterators, maps and sets,
      and when each fits.
- [x] **`do` over `Iter`, instead of ranges and comprehensions.** `Iter` is a `Monad`
      (`>>=` is `concatMap`, `pure` is `singleton`), an `Applicative`, an `Alternative` and a
      `MonadFail` (`empty`, `append`), and a `Semigroup` and `Monoid`, so `do` with `guard` is a
      comprehension that builds no list. Pythagorean triples up to 400 (10.7 million inner
      steps): 1.34 s as a list comprehension, 0.63 s as `do` over `Iter`, 0.03 s with
      `Iter.filter` for the last generator and the guard, all in ~10 MB. The `do` still
      allocates per value the `Iter` each step returns (`pure`, `guard`) and the closures over
      the bound variables. Comprehensions and ranges stay lists, on purpose: they are desugared
      by the parser, and to give an `Iter` they would need either GHC's monad comprehensions,
      which make every comprehension over a parameter of unknown type
      `(Monad m, Alternative m) => m a -> ...` (in inferred types, at the REPL's `:type`, and in
      errors), or a choice made by the type checker that most uses leave open (`length`,
      `sum`, `mapM_` take any `Foldable`), so it would need a defaulting rule of its own. A
      pattern that can fail on the left of `<-` is still rejected, for `Iter` as for lists.

Next, more of Go's library (decided 2026-11-18), the easy ones first:

- [x] **`Data.Ratio`** (`*big.Rat`), **`Data.String.Builder`**, **`Text.Regex`** (`regexp`),
      **`Data.Time`** (`time.Time`), **`Crypto.Hash`** and **`Data.Encoding`**,
      **`System.Process`** (`os/exec`), **`Network.HTTP`** (a client). The runtime has optional
      parts (`runtime/lib_*.go`), copied only into programs that call one of their functions,
      so a program that does not use them does not import `net/http` or `crypto`.
- [x] **Mutable structures in a monad.** `Data.IORef` (an atomic pointer to the value;
      `modifyIORef'` and `atomicModifyIORef'` are CAS loops), `Data.STRef`,
      `Data.Vector.Mutable` (`MVector s a` over a Go slice) and `Data.HashTable`
      (`HashTable s k v` over a Go map), and `Control.Monad.ST`. Decided on the way:
      - Vectors and tables are parameterised by a state, as in Haskell's vector
        (`IOVector = MVector RealWorld`), and their operations run in any `PrimMonad s m`
        (`class Monad m => PrimMonad s m | m -> s`, IO and `ST s`), so one function serves
        both; specialisation makes it free. References are two types, because an `IORef` must
        be atomic and an `STRef` need not. No `stToIO`: what ST makes has no lock.
      - `ST s a` is a newtype over `IO a`, in `Control.Monad.ST.Unsafe` (with `unsafeIOToST`
        and the class's methods); `runST` is `primRunIO`, as `runIdentity` is.
      - `runST` has its own rule in the type checker: its argument is checked against
        `ST s a` for a new rigid `s` (a type variable no program can write), which may appear
        neither in `a` nor in the types of the local variables in scope, after improvement by
        functional dependencies. Unapplied, `runST` is an error. The rigid variable becomes `()`
        once the module is checked (`closeUp`), since nothing at run time depends on it.
        `rejected/runst-*.hgo` hold the escapes.
      - An index out of range ends the program (`error: index out of range: 5, in a vector of
        length 5`, `failing/index-out-of-range.hgo`), as in Go and as a division by zero does;
        `readMaybe` is there for indices from outside. No `new` with undefined elements.
      - Keys are the instances of `Data.HashTable.Key`: `Int`, `Char`, `String`, `Bool`, `()`
        and tuples of keys up to four. Only `Data.HashTable` may give instances (the type
        checker rejects others), since a type kept as a pointer would be compared by identity.
        The Go table keeps its map as an `any` and asserts it to `map[K]V` in functions with
        `K comparable`: generated generic code declares its type parameters `any`, and
        a `Key k` constraint makes every call to those functions specialised to a concrete key.
      - A vector or table made in IO, in a program that has threads, has a mutex; one made in
        ST, or in a program without threads (`rt_concurrent` is a constant), has none.
        `examples/concurrent-mutable.hgo` runs under the race detector.
      Measured (one machine, noisy): the primes up to 1M, sieve on an `STVector` 0.26 s against
      1.65 s with the incremental `Data.Map` sieve; up to 10M, 2.3 s against 23 s (Go: 0.03 s).
      Frequencies of 1M numbers: `HashTable` in ST 0.33 s, `Data.Map` 1.0 s. Each operation is
      an IO action, some 60 ns; the sieve in IO takes 2 s, and 3.1 s in a program with threads.
- [ ] **Keys that are newtypes over keys,** and maybe `Integer` (by its digits): `Key` is closed
      for now.
- [ ] **`PrimMonad` through the transformers** (`StateT s IO`), which now have to `lift`.
- [x] **Cheaper mutable loops.** Each read or write was an IO action allocated and run by the
      trampoline. Done by the compiler instead of the runtime: see "Actions run where they are
      made" below.

- [x] **Go 1.27.** A type kept by value whose struct refers to itself through its alias (a
      list of itself) made Go 1.27's type checker panic ("incomplete alias", go.dev/issue/78296):
      the struct now takes the type's name, and the constructor's is the alias. CI runs on Go
      1.25 and on the newest. The README asked for Go 1.21; iterators and generic aliases need
      1.24, and 1.25 is what is tested.

Next, performance (decided 2026-11-25): first the distance to Go, which was ten to seventy
times on the programs that use IO, ST or small library functions in loops, and only then
whether a second backend (C, with reference counting that reuses cells in place, as Koka and
Lean do) is worth its cost (Go's libraries, goroutines). Go is within one to three times of
Rust on most programs; GHC's generational collector does better than Go's on code that
allocates much and briefly (`Data.Map`, parsers), so those are where Hago has most to gain.

- [x] **Actions run where they are made, and small functions copied in.** Measured on the
      sieve to ten million on an `STVector`: 2.0 s, against 0.06 s for the same loop written in
      Go by hand inside the program, and 0.03 s for Go's own. Two parts:
      - **`Hago.Inline`**, after specialisation and newtypes: a function that is not recursive
        and whose body is small (16 nodes) is copied where it is called, and what that leaves
        is simplified (a suspension forced at once, a lambda applied at once, a `case` that
        only names its scrutinees). An argument goes into the body only if that computes the
        same thing at the same time: a variable or a literal anywhere; a value that cannot
        fail (a lambda, a suspension) where it is used once, not inside a lambda (a lambda
        anywhere it is used once); anything else, one per call, where it is used once,
        outside lambdas and `do` blocks. Otherwise the call stays (`failing/argument-before-action.hgo`).
        Names bound in a copied body are renamed (`x#n`), and the bindings are taken callees
        first, since specialisation adds its copies after their callers. Only an action or a
        body without `case`, `if` or `let` is copied, which in an expression would be a Go
        function called on the spot. `&&` and `||` stay Go's. The library's wrappers vanish:
        `when`, `unsafePrimIO`, ST's and IO's `>>=`, `pure` and `*>`, `read` and `write`.
      - **Run forms** (`genRun` in `Hago.CodeGen`): a function that returns an action also
        gets `hgrun_f`, a Go function that does what the action would and returns its result,
        and an action run as soon as it is made (a statement of a `do` block, the action a run
        form returns, `primBindIO` and `primThenIO`, `runST`) is generated as the statements
        that run it: a call to Go, a call to a run form, an `if`, a `case`, a `let`. Stack:
        a tail call to itself is a `for`; to a function outside its group of mutually
        recursive ones (and the functions around a local one), a direct call, so a chain of
        them is as long as the program has functions; to one inside it, or to an action whose
        source is not known, the trampoline, which keeps the loop flat from there on.
        `examples/io-loops.hgo` runs ten million steps of each kind in constant memory.
      On the way: a Go function's parameter declared `a -> b` was given a Go function of all
      the arguments when `b` was a function (`Iter.map (,)`), now of one, as declared; a self
      tail call in a local function whose parameters were not `_arg0...` assigned the wrong
      variables (renamed locals made it reachable); `rt_iterConcatMap` is not inlined by Go,
      whose copy of its loops over functions ran `do` over `Iter` with `Iter.filter` in 0.05 s
      instead of 0.03 s. The README's programs are now in `bench/`, and `bench/run.sh` times
      them with one compiler or several side by side. Before and after, on one machine, the
      median of nine runs, interleaved:

      | Program | Before | After |
      | --- | --- | --- |
      | sieve to 10M, `STVector` | 2.04 s, 24 MB | 0.06 s, 11 MB |
      | sieve to 10M, `IOVector` | 0.87 s, 24 MB | 0.06 s, 11 MB |
      | the same, in a program with threads (a lock per access) | 1.34 s | 0.37 s |
      | frequencies of 1M, `HashTable` in ST | 0.22 s | 0.17 s |
      | JSON, 3.7 MB | 0.32 s, 91 MB | 0.24 s, 72 MB |
      | recursive IO loop, 5M | 0.08 s | 0.05 s |
      | `mapM_` over 1M in IO | 0.09 s | 0.06 s |
      | `mapM_` over 1M in `StateT Int IO` | 0.18 s | 0.12 s |
      | Pythagorean triples, comprehension | 1.23 s | 1.14 s |
      | `nfib 40` | 0.34 s | 0.37 s |

      The rest did not change. `nfib`'s Go function is now the one written by hand (which
      takes 0.35 s): its time moves by a tenth with where Go places the code, as two builds of
      the same body in different programs show. The generated Go is a little smaller (JSON:
      116 KB → 111 KB). The README's rows whose programs were not in the repository are
      measured with the ones now in `bench/`, close to the earlier ones but not the same: the
      keys of the `Data.Map` program are scattered, so it takes 2.1 s where the earlier one
      took 1.57 s, with either compiler.
- [x] **A tail call between functions that call each other** (2026-11-25) went through the
      trampoline (`ping`/`pong` in `examples/io-loops.hgo`). Two parts:
      - **One loop for the group** (`genRunLoop` in `Hago.CodeGen`). Of a group of mutually
        recursive functions, those with a run form that give the same type and have the same
        type parameters get one Go function, `hgloop_f`: a `for` around a `switch` over which
        of them is running, each with its own variables for the next round's arguments. A
        call at the end to one of them (at those type parameters) assigns its arguments, says
        which, and goes round again, as a call to itself already did; each one's run form
        enters the loop at its own case. Local functions too (`evenStep`/`oddStep` in ST). A
        call in the middle is still a direct call; a call at the end to one that gives
        another type, or to an action passed as an argument (`hop`/`bounce`), still goes
        through the trampoline; and a group in which none calls another at the end keeps its
        run forms apart. `examples/io-loops.hgo` adds three functions in a ring that give a
        value, over a list, with `case`; a polymorphic pair; a group with one that gives
        another type, called in the middle by the others and calling them; and closures made
        in each round, which keep that round's arguments. GHC prints the same.
      - **`main` runs its body.** Measuring showed that neither this nor a loop calling itself
        was reached from `main = loop 5000000 0` (`bench/loop-io.hgo`): `main` was an action,
        made in `init` and run by the trampoline, so it was `loop`'s action that ran, not its
        run form, and every step went through the trampoline. A `main` that nothing refers to
        is no longer a value: `main()` runs its body (`genRun`). One that something refers to
        is still made and run (`examples/loops.hgo`).
      Only these two programs' hot code changed; the rest of `bench/` differs in `main()`
      alone. Before and after, nine runs interleaved; GHC 9.12 with `-O2`:

      | Program | Before | After | GHC |
      | --- | --- | --- | --- |
      | recursive IO loop, 5M | 0.05 s, 11 MB | <0.01 s, 2 MB | 0.01 s, 4 MB |
      | the same, two functions calling each other (`bench/loop-io-mutual.hgo`) | 0.05 s, 12 MB | <0.01 s, 2 MB | 0.01 s, 4 MB |
      | `examples/io-loops.hgo` (two rounds) | 2.7 s, 3.2 s | 2.0 s, 1.7 s | |
- [x] **Pure functions that end calling each other** (2026-11-25) were Go calls, a stack frame
      each: `isEven`/`isOdd` of ten million took 250 MB of stack, a hundred million went past
      Go's 1 GB. The same loop as the run forms' (`genRunLoop`, given whether its functions
      are pure): of a group of mutually recursive functions that are not actions and give the
      same type, one `hgloop_f` with a `switch` over which is running, and each function a
      call that enters it at its case; local ones too. Only those that go round a circle of
      tail calls, two or more, are put in it, for the run forms as well: a chain of tail calls
      that ends (`Eq` of JSON, whose calls round go through `&&`) is as deep as the program,
      and direct calls are faster. A function that builds a map in place in its own loop is
      left out. `examples/loops.hgo` adds even and odd, a state machine over a string, local
      functions that use a variable around them, a polymorphic pair, and closures made in each
      round; GHC prints the same. Only `examples/loops.hgo` changed its Go.

      | Program | Before | After | GHC |
      | --- | --- | --- | --- |
      | two pure functions calling each other, 100M (`bench/mutual-pure.hgo`) | stack overflow, 1.9 s, 1 GB | 0.03 s, 2 MB | 0.02 s, 3 MB |
- [x] **Lists made only to be folded are loops** (2026-11-25). Against GHC 9.12 with `-O2`,
      on the same programs, the largest gaps were its fusion: the pipeline of squares 0.13 s
      against under 0.01 s, the comprehension of Pythagorean triples 1.10 s against under
      0.01 s, `mapM_` over a million 0.06 s against under 0.01 s. Done in `Hago.CodeGen`, not
      with rewrite rules: once `Hago.Inline` has copied the Prelude's folds in, every
      consumer of `Foldable` over a list is `listFoldl` (`sum`, `length`, `maximum`, `foldl`)
      or `listFoldr` (`any`, `all`, `elem`, `find`, `and`, `or`, `null`; `mapM_`, `forM_`,
      `traverse_` for actions), and when the list it gets is made by producers (ranges and
      the `Enum Int` methods, `map`, `filter`, `take`, `takeWhile`, `repeat`, `iterate`,
      `++`, `if`, `let`, literals, and `listFoldr` steps that end in their rest, which is
      what `concatMap` and comprehensions become) it is generated as nested `for` loops that
      visit the elements. A `listFoldr` is a loop when its step either ends in its rest or
      does not use it (it stops there, returning from a Go function called on the spot), or,
      for actions, runs some and then its rest (run with `genRun`). Every element a cell
      would hold is still computed, in order (`failing/fusion-strict-elements.hgo`), and no
      more than the fold asks for: `take` and `takeWhile` break out of all the loops, and
      `iterate` computes its next element only after the fold took the last one. The names
      the fold binds are renamed first (`Hago.Inline.renameBinders`), so nested Go blocks
      never hide one another. `examples/fusion.hgo` checks the edges (steps, empty ranges,
      the ends of `Int`, infinite lists cut by `take` or a fold that stops) against GHC's
      output. A `listFoldr` over a list that exists is a loop too, since the Prelude's
      allocates a suspension per element; a `listFoldl` over one is not, since the Prelude's
      is already a loop. Measured, before and after:

      | Program | Before | After |
      | --- | --- | --- |
      | squares of multiples of 3, lists | 0.12 s, 8 MB | <0.01 s, 2 MB |
      | Pythagorean triples, comprehension | 1.1 s, 8 MB | <0.01 s, 2 MB |
      | `mapM_` over 1M in IO | 0.06 s, 8 MB | <0.01 s, 2 MB |
      | frequencies of 1M, `HashTable` (`mapM_` over a list) | 0.17 s, 18 MB | 0.11 s, 13 MB |
      | `Data.Map`, 1M inserts, deletes, lookups (`length (filter ...)`) | 2.09 s, 102 MB | 1.78 s, 94 MB |

      The rest did not change.
- [x] **What fusion did not reach at first**, in this order:
      - **`mapM_` in `StateT s IO`.** Once its newtype is gone, the fold makes a function of
        the state, applied to the first one: `listFoldr (\x rest s -> ... rest s') z xs s0`.
        Generated as a loop with the state in a variable. For the fold to meet its list,
        `Hago.Inline` now copies a function whose body is a fold whatever its size (64 nodes
        at most), one that returns a lambda up to 32 (a transformer's action: `modify`), and a
        value that is a lambda (`get`); and a call with more arguments than parameters gives
        the rest to the lambdas the body returns, so `put (s + x)` is copied. 0.12 s → <0.01 s.
      - **`zip` and `zipWith`.** One list visited by its loops, the other a step at a time (a
        range, a list that exists, `repeat`, `iterate`, a `map` of those): the second when it
        can be, else the first, a step ahead, so that its cell is always reached before the
        second's and an empty one ends it before the second is looked at, as `zip` does. A
        list that exists moves to its tail only when the next pair is asked for. When neither
        can be visited a step at a time, the second list is made and its cells visited.
      - **`do` over `Iter`.** An `Iter` is Go's `iter.Seq`, so a do made of `Data.Iter`'s
        functions (`concatMap` as `>>=`, `singleton`, `range`, `guard`) compiles to one Go
        function with the loops, which gives each value to `yield` and returns when it says
        to stop; `Iter.foldl` (and with it `length`, `sum`, `maximum`) and `Iter.mapM_` of an
        Iter made right there are the loops. On the way: a `case` makes a list too (each row
        its loops, then out), as `guard` is two clauses; a function whose result is a Go type
        (`Iter`) is copied even with a `case` or an `if`; and a value that only names another
        (`Iter`'s `empty` is `none`) is replaced by it. 0.59 s → <0.01 s; with `Iter.filter`,
        0.04 s → <0.01 s.
      `examples/fusion.hgo` checks each against the same computed with lists or by hand.
- [x] **The rest of what fusion did not reach:**
      - **A step that drops its rest** ends the list there (`foldr (\x rest -> if x < 5 then
        x : rest else []) [] [1 ..]`): its elements, then a labelled break out of the fold's
        loops, the end of the fold too, which foldr would never reach.
      - **`drop` and `dropWhile`,** of lists and of `Iter`s: a counter, and a flag that stops
        computing the test once it failed. **`zip3` and `zipWith3`:** the first list visited
        by its loops, the other two a step at a time (made, when they cannot be).
        **`Iter.find`,** and with it `any`, `all`, `elem` and `head`: a loop that returns the
        first value that satisfies the test.
      - **A `foldr` that is recursion** (`foldr (+) 0 xs`): when the step forces its rest once,
        outside branches, lambdas and suspensions, and everything else in it is total
        (variables, constructors, suspensions, the primitives that cannot fail: `+`, `-`,
        `*`, comparisons, `/` of `Double`), its elements go into a Go slice and the step is
        taken from the last back, the rest being the value so far. Nothing but the rest can
        fail, so the order of the steps cannot be seen. `foldr (+) 0 [1 .. 10000000]` ran out
        of the Go stack (1 GB) before; now 0.10 s and 190 MB, GHC 0.13 s and 169 MB.
      `examples/fusion.hgo` checks the lists' cases against GHC and the `Iter`s' by hand.
- [x] **Left as recursion** (2026-11-25): a `foldr` whose step called a function not known
      to be total (`max x rest`, `x `div` rest`, even `x + rest` when `+` stayed a call to the
      `Num Int` method) ran out of the Go stack at ten million; and the backwards fold's slice
      held every element and grew by doubling, 215 MB for ten million. Three changes, in
      `strictStepOf` and `fuseFoldrBack`:
      - **Before the rest, forward; after it, back.** In `listFoldr g z (x : xs)`, what the
        step computes before it forces its rest is computed from the first element on, as
        the cells are made, and what it computes after, from the last back. So the step is
        split where the rest is first forced (the function and earlier arguments of a call,
        the bindings before a let's body, the condition of an `if`, the scrutinee of a
        `case`): what comes before is computed on the way forward and kept with its element,
        unless it is total (then on the way back, which nothing can tell); what comes after,
        any call, on the way back. Everything happens in the recursion's order, so the step
        no longer needs to be total: `failing/foldr-before-rest.hgo` fails at the second
        element, `failing/foldr-after-rest.hgo` at the fourth, as the recursion does. The
        rest may be used again after it is forced, anywhere, since it is then a value; each
        round has its own variable for it, which closures keep. Only what the way back uses
        is kept.
      - **Blocks, not a slice that doubles.** The elements go onto a stack of blocks (32 to
        16384 elements), never copied, each let go on the way back: no garbage is left for
        the collector while the elements are kept.
      - **A range from its end.** When nothing is kept but the element and the list is a
        range whose step is a literal, through maps and filters of total functions, it is
        visited from its last element back (counted in `uint`, so the ends of `Int` hold),
        and nothing is kept.
      `examples/fusion.hgo` checks steps with `max`, `mod`, a recursive function, `let`s,
      an `if` and a `case` on the rest, a map that may fail, closures that keep the rest, and
      ranges at the ends of `Int`, against GHC. Library code gained too: `replicateM` and
      `traverse` in applicatives that are not IO (the parser's `count`) are such folds.
      Measured, before and after, nine runs interleaved; GHC 9.12 with `-O2`:

      | Program | Before | After | GHC |
      | --- | --- | --- | --- |
      | `foldr (+) 0 [1 .. 10000000]` | 0.11 s, 220 to 310 MB | <0.01 s, 2 MB | 0.14 s, 169 MB |
      | `foldr max 0 [1 .. 10000000]` (`bench/foldr-max.hgo`) | out of Go stack (1.45 s, 1 GB) | <0.01 s, 2 MB | 0.14 s, 169 MB |
      | ``foldr (\x r -> x `mod` 7 + r) 0 [1 .. 10000000]`` (`bench/foldr-mod.hgo`) | out of Go stack (1.40 s, 1 GB) | 0.03 s, 81 MB | 0.15 s, 169 MB |
- [ ] **A `foldr` left as recursion:** a step whose rest is forced only in a branch
      (`if x > 0 then x + rest else rest - 1`), or in a lambda or a suspension, or passed on
      unforced: `foldl` written with `foldr` (`foldr (\x k acc -> k (acc + x)) id xs 0`) makes
      a closure per element and calls them nested.
- [x] **What the garbage collector costs, and `Data.Map`** (2026-11-25). pprof had Go's
      collector marking at two thirds of the CPU of the `Data.Map` programs, and the nodes of
      the tree at 84 % to 97 % of what they allocated (2.3 GB for the sieve to a million): a
      persistent insert copies the path to its key. GHC allocates as much; its generational
      collector makes most of it free. Two changes:
      - **`GOGC=200` by default** (`debug.SetGCPercent` in the generated `main`, unless
        `GOGC` is set): what marking costs is what is allocated times 100/GOGC. Measured at
        100, 200, 300, 400, nine runs interleaved: 200 takes a fifth off `Data.Map` and a
        tenth off JSON for half again as much memory, which is about GHC's own default (a
        heap three times what is alive); 400 takes a third off for two and a half times the
        memory, and made the backwards `foldr` slower.
      - **Maps built in place.** Each `Bin` keeps the owner that made it (for `Map Int Int`
        that word fits in the size class Go already gave the node). `insertWith`, `delete`,
        `deleteMin`, `deleteMax`, the rebalancing and the rotations take an owner (`...T` in
        `Data.Map`); given `noOwner`, as the persistent operations give them, every node is
        new. A node whose owner is the one given, and active, is changed in place
        (`rt_overwrite`, which Go inlines, so the node it copies from stays off the heap).
        Code generation gives an owner of its own to a fused `foldl` whose step is such an
        operation on the accumulator, used nowhere else (fromList, fromListWith, folds of
        inserts), and to a loop (a function calling itself at the end) whose map parameter
        is only read before (given at once to functions whose result has no map) and then
        given back through such operations or such a fold; the owner ends when the fold
        ends or the call returns (`defer`). The map a fold starts from is never changed,
        whoever else holds it. `examples/map-in-place.hgo` checks kept maps, two folds from
        one map, a map given from one fold to another, a loop from a kept map, and twenty
        thousand random inserts and deletes against `alter`, which is never in place, and
        `Data.Map.valid` (new, as containers' `valid`); GHC's containers print the same.
      Allocated: a million inserts and deletes, 1.4 GB → 22 MB; the sieve to a million, 2.3 GB
      → 254 MB. Measured, before and after:

      | Program | Before | After | GHC |
      | --- | --- | --- | --- |
      | `Data.Map`, 1M inserts, deletes, lookups | 1.69 s, 93 MB | 0.48 s, 66 MB | 1.43 s, 218 MB |
      | sieve to 1M, `Data.Map` | 1.48 s | 0.61 s | 0.31 s |
      | sieve to 10M, `Data.Map` | 27 s | 8.7 s | |
      | frequencies of 1M, `Data.Map` | 1.11 s | 0.49 s | 0.60 s |
      | JSON, 3.7 MB | 0.24 s, 71 MB | 0.22 s, 101 MB | 0.31 s, 93 MB |
- [x] **The three where GHC was ahead** (2026-11-25):
      - **A vector in IO in a program with threads** (0.36 s, GHC 0.04 s) took a lock on each
        access. A vector or table that the action that made it only gives to the operations
        of its module, in its own statements, binds, `if`s, `case`s, folds and the local
        functions it only calls, reaches no other thread, and is unshared (`rt_mvecUnshare`,
        `rt_tableUnshare`) as soon as it is made. Across functions: for each top-level
        function, which of its structure parameters it keeps so, the greatest such (local
        functions lifted to the top get the vector as a parameter); a value that is only
        another name for it is it too. `examples/concurrent-escapes.hgo` runs, under the race
        detector, the ways one escapes (an action given to `forkIO`, a local function given
        to other threads, an `MVar`, a function that gives it back) and one that does not.
        0.36 s → 0.04 s.
      - **Mutable arrays** (0.06 s, GHC and Go 0.03 s): pprof had `rt_mvecWrite` and
        `rt_mvecRead` at two fifths of the time, not inlined, since Go calls a generic
        function's shape through a dictionary here. A read or a write run at once is now
        written out where it is, the lock and the index tested as `v.mu == nil && uint(i) <
        uint(len(v.xs))`, after which Go checks nothing more, and the runtime's function is
        kept for the lock and for the error, whose message stays. 0.06 s → 0.03 s.
      - **The sieve on a map** (0.61 s, GHC 0.31 s). A recursive function that passes a
        function parameter as it is to every call to itself (`insertWith`'s `f`), given a
        lambda that uses no local variable or a top-level function, at concrete types, gets
        a copy without the parameter (`Hago.Inline`, `specialiseOn`): no curried closure
        per step. That did little here (0.61 s → 0.60 s); pprof then had `rt_overwrite` at a
        quarter of the time, `*dst = *src` being a `typedmemmove` with a write barrier per
        pointer, and a node changed in place now has its fields assigned (0.60 s → 0.43 s
        measured alone; 0.55 s in the interleaved round). What is left is the lists each step
        keeps (`[p]`, `++`), which GHC allocates too.
      Found on the way, by `examples/specialise.hgo`: a loop (a function calling itself at
      the end) assigned its parameters for the next round, and a closure made in a round that
      used a parameter (the inliner had put the parameter for the name a pattern gave it)
      saw the next round's value, and called itself forever. Each round now copies the
      arguments into new variables, which closures keep. And a `case` whose scrutinee was a
      constructor given fewer arguments than it has fields declared it as a value of the
      data type, not as the function it is. Measured, before and after:

      | Program | Before | After | GHC |
      | --- | --- | --- | --- |
      | sieve to 10M, `STVector` | 0.07 s | 0.03 s | 0.04 s |
      | the same, `IOVector` | 0.06 s | 0.03 s | 0.03 s |
      | the same, in a program with threads | 0.36 s | 0.04 s | 0.04 s |
      | `Data.Map`, 1M inserts, deletes, lookups | 0.48 s | 0.36 s | 1.43 s |
      | sieve to 1M, `Data.Map` | 0.68 s | 0.55 s | 0.31 s |
      | sieve to 10M, `Data.Map` | 8.7 s | 5.9 s | |
      | frequencies of 1M, `Data.Map` | 0.50 s | 0.42 s | 0.58 s |
- [x] **What was left of the map programs** (2026-11-25):
      - **The sieve's lists.** pprof had `[p]` and `++` at 213 of the 265 MB the sieve to a
        million allocated. A cell whose tail is `[]` computed already points to one thunk
        every list shares (`rt_nilTail`: a `rt_thunk[List[T]]` is laid out alike for every
        `T`), so `[p]` is one allocation of 16 bytes instead of 48. And `append` asks
        whether the rest of its first list is computed and empty (`primNilNow`, only for
        definitions whose two branches mean the same), and if so gives the last cell `ys`
        itself as its tail, without a suspension of `append [] ys`: `[p] ++ ps` is one cell.
        265 MB → 120 MB; what is left is the map's own work.
      - **`alter` and `adjust`** walk the tree once and take an owner (`alterT`, `adjustT`), as
        `insertWith` does, so folds and loops build with them in place. A loop got no owner
        when its call to `alter` had two arguments that were expressions, since the inliner
        copied a call only with one: a function whose body is a call given its parameters
        as they are, once each, in their order, as `alter f k m = alterT noOwner f k m`, is
        now copied whatever its arguments, each still computed once, where the call was,
        in the same order.
      - **`Data.Set`** is a `newtype` of `Map a ()` (a `()` takes no room in Go), and has
        everything a map has in place.
      - **A `foldl` over a list that exists** (a variable, a parameter) is a loop over its
        cells too; it was a call to `listFoldl`, which called the step's curried closure,
        one allocation per element (a fold of three million cells, 0.41 s → 0.34 s).
      - Not done: `map f xs` that is not folded calls `f` through a closure. Specialised by
        hand in the Go of three million elements it took the same time and a fifth less
        memory, which is not worth the copies.
      `examples/map-in-place.hgo` checks `alter` and `adjust` in loops and folds against the
      persistent ones (GHC's containers print the same), `examples/lazy.hgo` that `++`
      demands no more than before. Measured, before and after:

      | Program | Before | After | GHC |
      | --- | --- | --- | --- |
      | sieve to 1M, `Data.Map` | 0.59 s, 25 MB | 0.42 s, 17 MB | 0.31 s, 16 MB |
      | sieve to 10M, `Data.Map` | 5.8 s, 188 MB | 5.2 s, 120 MB | |
      | `Data.Set`, 1M inserts, deletes, lookups | 1.10 s, 96 MB | 0.35 s, 66 MB | 1.12 s, 156 MB |
- [x] **Hugen's core, a real program** (2026-11-26). Hugen's fighting game engine, its pure
      core ported line by line to Hago in `hago-examples` (thirteen modules, a driver that
      prints the match tick by tick and matches the Haskell original over a million ticks),
      took 10.1 s for a million ticks where GHC takes 1.5 s. Three causes, each fixed:
      - **Go's collector ran every few megabytes.** Less than a megabyte is alive, so Go's
        least goal, 8 MB at `GOGC=200`, made 2,200 cycles a million ticks, each waking a mark
        worker on every processor: with one processor the run took 2.6 s where sixteen took
        4.2 s, and without a collector 2.2 s. The goal is now never less than 32 MB
        (`rt_tuneGC`, from a finalizer after each cycle: the percentage that gives that goal
        for what is alive, at most 800, since Go's least goal grows with it, and 200 once three
        times what is alive is more). 4.2 s → 2.2 s at 300,000 ticks. The cost is memory:
        a program with little alive that allocates much takes up to 35 MB (the sieve on a map
        17 → 35 MB, frequencies 12 → 35 MB, `Data.Map` 66 → 81 MB); the hash table went from
        0.26 s to 0.12 s.
      - **A record of many fields was an interface:** a type of one constructor too big to be
        kept by value (`Fighter`, `Match`) was a Go interface, and every field read asserted
        it to its struct and copied the struct out. It is now a pointer to the struct
        (`dataReprs`), as the trees of `Data.Map` were: 8 % fewer bytes allocated.
      - **A comprehension kept as a list** was `concatMap`: a curried closure and a suspended
        rest for every element, kept or not, and `[x] ++ rest` for each kept. Comprehensions
        are now translated as GHC does, a generator a `foldr` whose step puts an element before
        the rest or skips to it (a generator inside another still joins its list with `++`,
        since Hago's `foldr` computes its end first), a `case` in a step fuses as `if` does,
        and a `foldr` whose list is kept and whose step makes at most one element is a loop
        that skips without allocating, and for each element kept a cell whose tail goes on
        from the next cell (`fuseFoldrLazy`). 9 % fewer allocations. `examples/lazy.hgo`
        checks an infinite source, an error in a cell never reached, nested generators over an
        infinite list, patterns that drop elements.
      The per-tick output is still the original's. A million ticks, five runs, cores 0-15:

      | | Before | After | GHC |
      | --- | --- | --- | --- |
      | Hugen's core, 1M ticks | 10.1 s, 14 MB | 6.4 s, 37 MB | 1.5 s, 9 MB |

- [x] **Local functions lifted** (2026-11-26). A third of what Hugen allocated was
      `evalTerm`'s local functions, closures made again on each call (`evalTerm c sight self =
      go`, `go` capturing them, and on the heap, since a closure that calls itself holds the
      variable that holds it). `Hago.Lift`, after inlining: a function whose body only makes
      local functions and cheap values (variables, constructors, a field of a type of one
      constructor, arithmetic that cannot fail) and gives one of them takes that function's
      argument too; then a group of local functions whose every use is a call with all its
      arguments moves to the top, its free variables first among its parameters and in each
      call, the type variables those of the function around it, after binders are made
      unique. A local function given as a value stays a closure, and one whose `where`
      computes something costly is not expanded, so that it is computed once.
      `examples/lift.hgo` checks those, mutual recursion, a polymorphic function around, a
      `do`, and shadowing; GHC prints the same. Nothing else in `bench/` moved. Hugen, a
      million ticks, cores 0-15: 7.0 s → 5.5 s (GHC 1.5 s), allocations 350 → 206 a tick.
- [x] **Constants made once** (2026-11-26). A value written out in the code, a constructor
      applied to literals and to such values at a type with no type variable (Hugen's list of
      buttons in `Input.relative`, built twice a tick), is a top-level value made at start
      (`floatStatics` in `Hago.Lift`), the same one wherever it is written twice. A call is
      not moved, even of constants: keeping its result for the whole run could keep a long
      list alive, as GHC's full laziness can. Hugen: 5.5 s → 5.0 s, 206 → 192 allocations a
      tick; in `bench/` only the sieve and frequencies have one (a `[Char]` of the Prelude's),
      and did not move.
- [ ] **What is left of Hugen** (three times GHC): it allocates 192 times a tick, each a
      call to Go's allocator. `Command.matches` (lazy lists searched with `any` and `take 1`),
      the `zip` of `Input.relative`, the record updates of `Match.step`, and the driver's own
      hash.
- [x] **Go that calls back one call at a time** (2026-11-26). A program that gives Go a
      function got the concurrent runtime, since Go may call it from any goroutine; but
      `strings.Map`, a regex's replace, or a game library's update and draw (Hög, on
      Ebitengine) call it one call at a time. `foreign import go sequential "strings.Map" ...`
      says so (`fSequential`, Haskell's FFI has `safe` and `unsafe` in the same place), and
      the program keeps the runtime for one goroutine, whose thunks take no lock.
      `Text.Regex.replaceAllWith` is declared so; `examples/foreign.hgo` uses `strings.Map`.
- [x] **Two bugs the Hugen port found** (2026-11-26):
      - **An import list could name what the module does not export** (`import Data.List
        (noSuchThing, sort)` compiled). It is an error now, as in GHC, for values, types and
        a type's constructors; in a hiding clause it is not (GHC only warns).
        `rejected/import-not-exported*.hgo`.
      - **A local value with a polymorphic signature stayed monomorphic** (`where ev :: b -> b;
        ev = id`, used at two types, was a type mismatch at a use). Local functions are
        generalised by lifting them to the top, which only happened to those with
        parameters: Haskell's monomorphism restriction, which does not apply when the
        signature asks for the polymorphism. A value with a signature is lifted too, given
        the variables it uses as parameters. `examples/locals.hgo`; GHC prints the same.
- [x] **The libraries the Hugen port missed** (2026-11-26): `Data.Bits` (a class, for `Int`);
      `Data.Word` and `Data.Int` (`Word8` to `Word64`, `Word`, `Int8` to `Int64`: Go's
      integers, declared with `foreign import go type` and given the instances with the
      Prelude's primitives, which are Go's operators, and `runtime/lib_bits.go`, generic
      over Go's integers, for division as Haskell's, bits and conversions); `Data.Maybe`;
      `foldl'` in `Data.List`; `Data.IntMap` (`Map Int`), and `Data.Map.Strict` and
      `Data.IntMap.Strict` under containers' names. `examples/bits.hgo`; GHC prints the same
      but for `succ` and `toEnum`, which give a `Maybe` in Hago. A field used as a function
      (`name p`) now says what to write instead. Then `Data.Sequence`: containers' is a finger
      tree, a type nested in itself (`FingerTree (Node a)`), which specialisation cannot make
      copies of; Hago's is a balanced tree by position, Data.Map's balancing with sizes and no
      keys, everything logarithmic (adding at an end too, where containers' is constant).
      `examples/sequence.hgo` runs three thousand random operations against a list and checks
      the tree after each (twenty thousand passed). And `Data.Foldable`, the Prelude's under
      that name.
- [x] **Operators of one precedence and different associativities** side by side (`0 <| s |>
      11`, infixr 5 and infixl 5) were accepted and grouped somehow, and `a == b == c` too
      (`infix 4`, neither associative); Haskell refuses them. Two operators of one
      precedence, every operator between them binding tighter, that are of different
      associativities or neither associative, are now an error, with GHC's words ("cannot mix
      ... in the same infix expression"), checked before fixities are resolved
      (`fixityConflict`). `rejected/fixity-*.hgo`. A minus after such an operator is still
      negation (see below).
- [x] **Pattern guards** (2026-11-26), which the Hugen port missed (`Match.throws` became nested
      `case`s; the error was "unexpected `<-`"). A guard is qualifiers separated by commas, as
      Haskell 2010's: conditions, patterns with `<-`, and `let`s. The parser makes one with
      more than a condition into a condition that the qualifiers hold in turn (`case e of p ->
      ...; _ -> False`) and puts the body where they bind their variables, so the guards,
      their order and the fall through to the next clause are the ones there were. Code
      generation (`genRow`) sees a condition and a body of that shape, the same expression and
      pattern but for the names of its variables, and makes one block: the expression
      computed once, matched once, the rest of the condition and the body inside, a failure
      falling through to the next guard. The layout
      closes a `let` opened in a guard at the comma after it, as the Report's parse-error(t)
      does. `examples/pattern-guards.hgo`; GHC prints the same.
- [x] **A minus after an operator** (2026-11-26): `x < -0.4` was a syntax error ("unexpected
      operator -"), where Haskell reads the minus as negation; and a minus at the start was
      `negate` of the first operand alone, so `-2 ^ 2` was 4 where Haskell gives -4. Found
      writing Hög's Asteroids. A minus before an operand, at the start or after an operator, is
      now a mark that fixity resolution reads as negation of precedence 6: the operand takes
      the operators after it that bind tighter (7 and up) before `negate` applies. After an
      operator of 6 or more, which the Report refuses (`a - - b`, `a * - b`), it negates what
      follows. `examples/syntax-definitions.hgo` checks them; GHC prints the same where it
      accepts them.
- [x] **The same programs in GHC** (`bench/ghc/`, `bench/ghc/run.sh`; the README's "Against
      GHC"). Even on strict code and on folds of lists made where they are folded; Hago ahead
      on JSON (0.23 s against 0.28 s, the combinators and printer ported line by line) and on
      the hash table (0.11 s against 0.20 s), and in memory everywhere; GHC ahead on what
      allocates much (`Data.Map` 1.37 s against 1.80 s, the sieve on a map 0.32 s against
      1.77 s), on mutable arrays (twice), and on `mapM_` in `StateT`.

Next, tools around the language, in this order:

- [x] **`hago check FILE`:** type checks a program, a module of one, a module of the library or
      the Prelude, with what it imports, and generates no Go: about 0.05 s with the cache full,
      for editors to run on save. The first error only, as the compiler stops there.
      `check.sh` runs it over every example and module, and over `rejected/`.
- [x] **`hago doc`:** the reference of the Prelude and the library in `docs/library/`, a page per
      module and an index. What is exported and every type come from the type checker; the text
      from the comment above each declaration, read from the source text since the lexer drops
      comments, with sections from `-- Title -----` lines and instances listed under their
      type. Synonyms appear expanded (`runState :: StateT s Identity a -> ...`): the checker
      does not keep them. The Prelude has no export list, so its helpers (`readParens`,
      `goAtoi`) are listed too. `check.sh` regenerates the pages and compares.
- [x] **Editor support:** `editors/vscode`, a VS Code extension in plain JavaScript, installed
      from the folder. A TextMate grammar (Haskell's forms, and `foreign import go`, `foreign
      import go type`, `Lazy`, `~` on fields, `p.name` against `f . g`), tried with
      vscode-textmate on every `.hgo` file of the repository; comments, brackets, folding and
      indentation; the error of `hago check` as a diagnostic on open and on save, also on the
      saved file when it is in a module it imports. One error at a time, as `hago check` gives.
- [x] **`hago fmt`, the part that needs no new syntax tree:** whitespace only, so that every
      token keeps its column as the lexer counts it and its line among the lines that are not
      blank: tabs in code become spaces, trailing whitespace goes, blank lines in a row become
      one, one final newline. Literals and comments are untouched (blank lines inside a block
      comment too). It checks every result itself (same syntax tree but for locations, same
      comments in the same columns, the same file when run again) and refuses to write
      otherwise; that check found its first bug, a block comment rebuilt backwards.
      `--check` for CI. `check.sh` runs it on a copy of every `.hgo` but `rejected/`'s. The
      repository's own files are not reformatted (two have a double blank line).
- [ ] **`hago fmt` that lays code out,** as gofmt or ormolu do. Not done: keeping comments needs
      the lexer and the parser to carry them, and the parser's tree is not a concrete one, so it
      is a large change. The plan:
      1. **The lexer keeps trivia.** A `lexTrivia` that gives every token its end column, and the
         comments as tokens of their own (line or block, text, start and end); `lexer` drops
         them, so the parser does not change. Small: the lexer already finds both.
      2. **A concrete syntax tree.** Today's tree cannot be printed back as the source: the
         parser desugars list literals into `:`, ranges into `enumFrom*`, comprehensions into
         `concatMap` and `if`, sections and `(.name)` into lambdas, `-x` into `negate`, and
         `p <- e` in `do` into a bind and a `case`, and it forgets parentheses, backquotes and
         explicit braces. A printer from it would rewrite the forms, not only the layout. So the
         Parsec grammar builds a `Hago.Cst` that keeps every form, each node with its first and
         last token, and today's `Module` becomes `desugar :: Cst -> Module`, so the two cannot
         drift apart. This is the large part: every production of `Parser.hs` (740 lines)
         changes, and `rejected/syntax.hgo` and the `examples/syntax-*.hgo` must keep their
         behaviour and messages.
      3. **Comments attached to nodes,** by position, as ormolu does: a comment on lines of its own
         goes with the declaration, statement, alternative, guard, field or element that follows
         it, and one at the end of a line with the node that ends on that line.
      4. **A printer** from the tree with comments to text, with Wadler's documents (the
         algorithm of `examples/Text/Pretty.hgo`): blocks indented by two, `do`, `let`,
         `where`, `case` and guards with their items aligned as the layout rule needs, breaking
         applications, operator chains and lists that do not fit in 100 columns, and one blank
         line between top-level declarations. To decide first: whether to keep the author's
         alignment of `=`, `->` and end-of-line comments (the README's examples align them), and
         how export lists and records break.
      5. **The same checks as now,** over every `.hgo` of the repository: the tree desugared from
         the printed text is the original's but for locations, the comments are the same and
         attached to the same nodes, and printing again gives the same text.

Known rough edges, found on the way and not fixed yet:

- [x] **Errors in type signatures have a location.** A signature keeps where it starts, as the
      other declarations do, so a context with the wrong number of types, an unknown class or an
      unknown type is reported at `file:line:column` and quoted, in a top-level, local or
      method signature (`rejected/signature-*.hgo`). Fixed on the way: a local signature's
      context was not checked at all, so an unknown class there compiled.
- [ ] **The check for values defined in terms of each other counts every branch** of an `if` or
      `case` as evaluated, so it could reject a value whose cycle only goes through a branch
      that is never taken.
- [ ] **A binding a later guard uses is computed before the first guard when an earlier guard
      shares a binding with it** (otherwise it is computed after the earlier guards fail).
      Splitting there would compute the shared binding twice; doing better needs bindings
      between guards in the core.
- [ ] **A record update that changes a type parameter some other field fixes** is reported as the
      type mismatch it causes (`no instance for Num String`), not as the field that cannot change.
- [ ] **A local function moved to the top is called through curried closures, and its self tail
      call is not a loop.** The incremental sieve with a local `go` over `(Ord, Num)` (generalised,
      so lifted) ran out of Go's stack at ten million; as a top-level function it is a loop.

## Syntax: where Hago parts from the Haskell 2010 Report

The parser follows chapter 10 of the Report (the context-free grammar and the layout algorithm
L); `examples/syntax-*.hgo` hold the tricky cases. Where it differs:

- **The layout rule's parse-error(t) is approximated** by the tokens that cannot continue an
  implicit block: a closing bracket or a comma of an enclosing bracket, an `in` whose `let` is
  outside the block (`let y = let x = 1 in x + 1`), a `then` or `else` whose `if` is outside it
  (`if c then case x of ... else e`), and a `where` after `do` or in the block's column. A block
  that some other token could only close by a parse error needs explicit braces or a new line.
- **`f.g` is not composition:** `.` with no spaces is a record field (`p.name`), so composition
  is written `f . g`.
- **A string literal is a `String`, never a `[Char]`,** so it is not a list pattern.
- **No `n+k` patterns, no `(x <+> y) = e` pattern binding of an operator,** as in Haskell 2010.

## Out of scope, on purpose

- **Running existing Haskell code unchanged.** Hago is strict; laziness is opt-in (`~` fields and
  `Lazy a`).
- **`String` as `[Char]`.** `String` is Go's `string`; `pack`/`unpack` convert.
- **Polymorphic recursion through a constraint.** It cannot be specialised and is rejected; allowing
  it would bring back run-time dictionaries.
- **Record fields as functions.** `p.name` and `(.name)` instead; see the README.
- **`Enum Double`.** Floating-point ranges cannot be exact; map over a range of `Int`.
- **Partial Prelude functions** (`head`, `tail`, `fromJust`, ...) and Haskell's old class hierarchy.

## Done

| Commit | What |
| --- | --- |
| `27d8225` | Lexer with layout, parser, Hindley-Milner, typed core, Go generation; `~` lazy fields and `Lazy a`; `foreign import go` |
| `04214a5` | Type classes, `deriving (Eq, Ord, Show)`, `Double`, overloaded literals with defaulting |
| `876043a` | Fixed class hierarchy (AMP, Semigroup ⊂ Monoid, MonadFail, Foldable/Traversable, no partial functions); constructor classes; trampolined IO; `MonadRec`/`tailRecM` |
| `3c4a49f` | Full specialisation: no dictionaries at run time |
| `0f2c254` | Monad transformers (data types with higher-kinded parameters, one Go type per instantiation); patterns in `do` |
| `dde8eb2` | Errors with file:line:column |
| `12b2c00` | Modules: exports, abstract types, qualified and hiding imports |
| `7920e46` | Records without Haskell's mistakes, free newtypes, type synonyms, list comprehensions, `deriving Functor/Foldable/Traversable` |

## How to check

`./check.sh` builds the compiler, compiles and runs every example program (each `examples/*.hgo`
with an `.out` next to it; the rest are modules) comparing its output with that `.out`, replays
the REPL sessions in `repl/`, and checks that every program in `rejected/` fails with the error on its
`-- expects:` line. It compiles with an empty cache, then compiles every example again with the
cache full and checks the Go is the same. `hago check` must pass every example and module of the
library, and fail every program in `rejected/` with its error. The pages in `docs/library` must be
what `hago doc` makes, and `hago fmt`, run on a copy of every `.hgo` but `rejected/`'s, must change
nothing but whitespace and give the same file when run again.
CI runs the same script on every push.
