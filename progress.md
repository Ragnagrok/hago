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
- [ ] **`Enum`.** `[a..b]`, `[a,b..c]`, `succ`/`pred` for `Char`, `Double` and derived enumerations
      (`deriving Enum` for types whose constructors have no fields). Today ranges only work on `Int`.
- [ ] **Type-changing record updates.** `b { item = "x" }` from `Box Int` to `Box String`.
- [ ] **`Read`** (at least for `Int`, `Double` and derived types).
- [ ] **Share polymorphic top-level values.** `xs = []` becomes a generic Go function and is
      re-evaluated on each use; cache one value per instantiation.
- [ ] **Polymorphic local definitions.** `let`/`where` bindings are monomorphic because Go function
      literals cannot be generic; lift polymorphic ones to the top level.
- [ ] **Less visible `Lazy`.** A type error can still mention `Lazy` (`liftA2 (:)` is one; a lambda
      fixes it).
- [ ] **Multi-parameter classes with functional dependencies.** `class Monad m => MonadState s m | m -> s`,
      so `get`, `put`, `throwError` and `ask` work through any transformer stack without `lift`
      (mtl style). Specialisation already removes dictionaries, so this costs nothing at run time.
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
