# Hago

*[Leer en español](README.es.md)*

A prototype compiler for a language that looks like Haskell 98 but evaluates like Go: strict by
default, compiled to plain Go source, and able to call Go functions directly. The compiler is
written in Haskell.

```haskell
fibs :: [Int]
fibs = 0 : 1 : zipWith (+) fibs (tail fibs)

foreign import go "strings.ToUpper" toUpper :: String -> String

main :: IO ()
main = do
  print (take 5 (repeat 1))      -- [1,1,1,1,1]
  print (take 10 fibs)           -- [0,1,1,2,3,5,8,13,21,34]
  putStrLn (toUpper "hello")     -- HELLO
```

## The idea

Haskell is slow and hard to mix with other languages mostly because of laziness, not because of
its syntax. Hago keeps the syntax and drops the default: every expression is evaluated when it
is bound, like in Go. Laziness only exists where a type asks for it.

- **Lazy fields.** In `data [a] = [] | a : ~[a]`, the `~` marks the tail as lazy. When you
  build a list, the compiler suspends whatever goes into that field, so `repeat x = x : repeat x`
  works. Your own types can use `~` too.
- **Lazy parameters.** `(&&) :: Bool -> Lazy Bool -> Bool` makes `&&` short-circuit as a plain
  library function. The caller writes `a && b` as usual, and the compiler suspends `b` because
  of the type.
- **Type-directed insertion.** You never write delay or force yourself. If an expression is
  checked against `Lazy t`, the compiler suspends it. If a variable of type `Lazy t` is used
  where a `t` is expected, the compiler forces it. A strict function passed where one with
  `Lazy` parameters is expected (`foldr insert Leaf xs`) is wrapped automatically.

Suspensions are memoised thunks (`sync.OnceValue`), so they are evaluated at most once and are
safe to share between goroutines.

## Type classes

```haskell
class Show a => Shape a where
  area :: a -> Double
  name :: a -> String
  name x = show x                      -- a default method

data Square = Square Double deriving (Show)
data Pair a = Pair a a deriving (Show)

instance Shape Square where
  area (Square s) = s * s

instance Shape a => Shape (Pair a) where
  area (Pair x y) = area x + area y

describe :: Shape a => a -> String
describe s = name s ++ " has area " ++ show (area s)
```

- **The Prelude** defines `Eq`, `Ord`, `Show`, `Num`, `Integral` and `Fractional`, with instances
  for `Int`, `Double`, `Char`, `String`, `Bool`, `()`, lists, tuples, `Maybe`, `Either` and
  `Ordering`.
- **`deriving (Eq, Ord, Show)`** expands into ordinary instances before type checking.
- **Integer literals** are overloaded through `fromInteger`, and ambiguous types default to `Int`
  (or `Double` when `Fractional` is involved), as in Haskell. Unsigned bindings without
  parameters follow the monomorphism restriction.

Classes compile to dictionary passing. Each class becomes a generic Go struct of uncurried
function fields, and a constrained function takes one dictionary pointer per constraint. When
the instance is known at compile time, the call goes straight to that instance's function, with
no dictionary: `n + 1` on `Int` becomes `inst_Num_Int_m_op_plus(n, 1)`, which Go inlines into a
plain `+`. Only code that stays polymorphic, like `(Ord a, Num a) => a -> a`, pays for indirect
calls.

Classes range over types of kind `*` only, and method types can only mention the class variable.
Go cannot be generic over type constructors, so there is no `Functor` or `Monad`.

## What the Go looks like

`map` compiles to a generic Go function. Data types become a Go interface with one struct per
constructor:

```go
func map_[T_a any, T_b any](_arg0 func(T_a) T_b, _arg1 List[T_a]) List[T_b] {
	...
		if hg_v9, hg_ok := _arg1.(Cons[T_a]); hg_ok {
			x := hg_v9.F0
			xs := hg_v9.F1
			return Cons[T_b]{f(x), rt_lazy(func() List[T_b] {
				return map_[T_a, T_b](f, xs())
			})}
		}
	...
}
```

- **Polymorphism** becomes Go generics.
- **Calls** to known functions are direct Go calls. Partial application and function values use
  curried closures.
- **Self tail calls** become a `for` loop, so `filter` skips elements and accumulator loops run
  in constant stack.

## Calling Go

```haskell
foreign import go "strings.Repeat" repeatString :: String -> Int -> String
foreign import go "strconv.Atoi"   parseInt     :: String -> Either String Int
foreign import go "fmt.Println"    goPrintln    :: String -> IO ()
foreign import go "math.MaxInt32"  maxInt32     :: Int
```

- `Int`, `Bool`, `Char` and `String` are Go's `int`, `bool`, `rune` and `string`, so values cross
  the boundary unchanged.
- A Go function that returns `(T, error)` is declared as returning `Either String T`, or
  `IO (Either String T)` if it has effects.
- `IO ()` means the Go function is called for its effects and its results are ignored.
- The package is imported from the path before the last dot: `"path/filepath.Join"` imports
  `path/filepath`.
- A function declared without `IO` is a promise you make that it is pure.

## Performance

These numbers come from one machine, as a reference and not as a benchmark.

| Program | Time | Peak memory |
|---|---|---|
| `nfib 40`, hand-written Go | 0.34 s | — |
| `nfib 40 :: Int -> Int`, Hago | 0.34 s | — |
| `nfib 40 :: (Ord a, Num a) => a -> a`, Hago, at `Int` | 1.88 s | — |
| sum of the squares of the multiples of 3 up to 3,000,000, through lazy lists | 0.41 s | ~10 MB |

- **Strict code at concrete types** compiles to the Go you would write by hand, and runs like it.
- **Constrained polymorphic code** is about 5.5 times slower because of the calls through
  dictionaries. Specialising it to the types it is used at is the obvious next step.
- **The lazy list pipeline** streams in constant memory, but every cell allocates a thunk, so it
  is much slower than a Go loop.

## Using it

You need GHC (9.12 is tested) with cabal, and Go 1.21 or later.

```sh
cabal build
cabal run -v0 hago -- run examples/lazy.hgo                 # compile and run
cabal run -v0 hago -- build examples/lazy.hgo -o lazy.go    # just compile
./check.sh                                                  # every example and rejected program
```

The `examples/` folder has lazy lists, ADTs with pattern matching and guards, type classes,
calls to Go, and loops. Each example has an `.out` file with its expected output. The `rejected/` folder has
programs the type checker must refuse, each with the error it expects.

## What is there and what isn't

It is a prototype. The pipeline (layout rule, parser, Hindley-Milner inference that elaborates
into a typed core, Go generation) works from end to end, but a lot of Haskell 98 is missing.

**Supported**
- `data` with lazy fields (`~`) and `deriving`, type signatures with contexts, multi-clause
  functions, guards, `where`, `let`, `case`, `if`, lambdas, `do` for IO, as-patterns, `e :: t`
  annotations.
- `class` with superclasses and default methods, `instance` with contexts. `Int`, `Double`,
  `Char`, `String`, `Bool`.
- Operators with `infixl`/`infixr`/`infix` declarations, sections, backquotes, tuples of two and
  three, list literals, `[a..]` and `[a..b]`.
- Let-polymorphism at the top level, with dependency analysis of unsigned bindings.
- `foreign import go`.

**Missing**
- **Constructor classes** (`Functor`, `Monad`), multi-parameter classes, and specialisation of
  constrained code.
- **`Read` and `Enum`.** `[a..b]` only works on `Int`.
- **`String` is Go's `string`, not `[Char]`.** Convert with `pack` and `unpack`. Double
  literals are always `Double`, not overloaded through `Fractional`.
- Modules and imports, records, `newtype` semantics, list comprehensions, `type` synonyms,
  monads other than IO, tuples beyond three.
- **Local bindings are monomorphic.** Go function literals cannot be generic.
- **Polymorphic top-level values are not shared.** `xs = []` becomes a generic function and is
  re-evaluated at each use.
- **`Lazy` is a real type.** Laziness only reaches where the types carry it. For example,
  `foldr` takes `a -> Lazy b -> b` so it can stop early, and `++` suspends its second argument.
  The automatic adaptation covers passing strict functions, but you can still meet a type error
  that mentions `Lazy`.
- **Error messages are minimal** and have no source positions in the type checker.

## Layout of the code

| File | What it does |
|---|---|
| `src/Hago/Lexer.hs` | tokens and the layout rule |
| `src/Hago/Parser.hs` | Parsec over tokens, fixity resolution |
| `src/Hago/Derive.hs` | `deriving (Eq, Ord, Show)` |
| `src/Hago/TcMonad.hs` | unification and the constraint solver (instances, defaulting) |
| `src/Hago/Typecheck.hs` | inference and elaboration, where `Lazy` and dictionaries are inserted |
| `src/Hago/Core.hs` | the typed core |
| `src/Hago/CodeGen.hs` | Go generation |
| `runtime/runtime.go` | lists, tuples, thunks and IO, copied into every program |
| `prelude/Prelude.hgo` | the prelude, written in Hago |

## License

MIT. See [LICENSE](LICENSE).
