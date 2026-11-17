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

Next, found by the JSON program:

- [ ] **Small sum types without allocation.** A non-recursive sum type (`Maybe`, `Either`, a
      parser's `Ok | Failed`) is a Go interface, so building one allocates; as a struct with a
      tag, passed by value, it would not. Allocation and GC are most of the JSON parser's time.
- [ ] **Runs of characters in one step.** `Data.String.span`/`takeWhile` over a `String`, and a
      parser that takes a run (`takeWhileP`), instead of one `satisfy` per character.
- [ ] **Decide whether `Text.Parser` and `Text.Pretty` belong in the library.**

Known rough edges, found on the way and not fixed yet:

- [ ] **Errors in type signatures have no location** (a context with the wrong number of types, an
      unknown class), only the file and the definition's name.
- [ ] **The check for values defined in terms of each other counts every branch** of an `if` or
      `case` as evaluated, so it could reject a value whose cycle only goes through a branch
      that is never taken.
- [ ] **A binding a later guard uses is computed before the first guard,** even when the first
      guard holds and nothing uses it; guards could be split so that it is computed just
      before the first guard that needs it.
- [ ] **Coverage does not look inside guards,** so complementary conditions need `otherwise`.
- [ ] **A record update that changes a type parameter some other field fixes** is reported as the
      type mismatch it causes (`no instance for Num String`), not as the field that cannot change.

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
