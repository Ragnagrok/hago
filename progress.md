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
- [ ] **A parser's `Ok | Failed` is still an interface:** its fields are more than eight words.
      Overlapping the constructors' fields in one struct would need unsafe tricks Go does not
      allow.
- [ ] **Runs of characters in one step.** `Data.String.span`/`takeWhile` over a `String`, and a
      parser that takes a run (`takeWhileP`), instead of one `satisfy` per character.
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
- [ ] **Ranges and comprehensions over `Iter`,** if code wants them: `[1 ..]` stays a list.

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
- [ ] **Cheaper mutable loops.** Each read or write is an IO action allocated and run by the
      trampoline; a loop over indices done by the runtime would avoid it.

- [x] **Go 1.27.** A type kept by value whose struct refers to itself through its alias (a
      list of itself) made Go 1.27's type checker panic ("incomplete alias", go.dev/issue/78296):
      the struct now takes the type's name, and the constructor's is the alias. CI runs on Go
      1.25 and on the newest. The README asked for Go 1.21; iterators and generic aliases need
      1.24, and 1.25 is what is tested.

Known rough edges, found on the way and not fixed yet:

- [ ] **Errors in type signatures have no location** (a context with the wrong number of types, an
      unknown class), only the file and the definition's name.
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
cache full and checks the Go is the same.
CI runs the same script on every push.
