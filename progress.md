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
- [ ] **Stack-safe pure monads.** Long loops in `State` grow the Go stack and need `tailRecM`; IO and
      transformers over IO are already trampolined.
- [ ] **Separate compilation.** Today every module is compiled together with the program.

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
with an `.out` next to it; the rest are modules) comparing its output with that `.out`, and checks that every program in `rejected/` fails with the error on its
`-- expects:` line.
CI runs the same script on every push.
