# Hago

*[Leer en español](README.es.md)*

A prototype compiler for a language that looks like Haskell 98 but evaluates like Go: strict by
default, compiled to plain Go source, and able to call Go functions directly. The compiler is
written in Haskell.

```haskell
fibs :: [Int]
fibs = 0 : 1 : zipWith (+) fibs (drop 1 fibs)

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

There are also classes over type constructors, such as `Functor`, `Applicative`, `Monad`,
`Foldable` and `Traversable`, and you can write your own instances:

```haskell
data State s a = State (s -> (a, s))

instance Monad (State s) where
  m >>= k = State (\s -> case runState m s of
                           (a, s') -> runState (k a) s')

-- get and put as in examples/monads.hgo
label :: Tree a -> State Int (Tree (Int, a))
label t = traverse step t
  where
    step x = do
      n <- get
      put (n + 1)
      pure (n, x)
```

- **`do` works in any monad.** It compiles to straight-line Go in IO, and to `>>=` elsewhere.
- **Instances can be partial applications,** as in `Functor (Either e)`, `Monad ((->) r)` (a
  reader) and `Monoid w => Monad ((,) w)` (a writer).
- **`deriving (Eq, Ord, Show)`** expands into ordinary instances before type checking.
- **Integer literals** are overloaded through `fromInteger`, and decimal literals through
  `Fractional`. Ambiguous types default to `Int`, or to `Double` with `Fractional` or `Floating`,
  as in Haskell. Unsigned bindings without parameters follow the monomorphism restriction.

### How they compile

Classes compile by **specialisation**, as in Rust and MLton:

- **Every function with a constraint, or polymorphic over a type constructor, is a template.**
  The compiler makes one copy per instance or constructor it is used at: `nfib :: (Ord a, Num a)
  => a -> a` used at `Int` becomes `nfib__Int`, and `traverse` used at `State Int` gets its own
  copy.
- **Every method call is a direct call to the instance's function,** which Go inlines when it
  is small: `n + 1` on `Int` ends up as a plain `+`.
- **No dictionary exists at run time.** Go generics range over types, not type constructors
  (there is no `F[_]`), so a `Functor f` dictionary could not exist anyway.
- **Type variables without constraints stay Go generics,** so `map` is still one function.

## A hierarchy without Haskell's mistakes

The Prelude keeps Haskell's classes, but not the decisions that Haskell itself had to undo or
still lives with:

- **`Functor => Applicative => Monad` from the start.** `return` is not a method, just `pure`.
- **`Semigroup => Monoid`.** `<>` is the only way to combine, and there is no `mappend`.
- **`fail` lives in `MonadFail`,** not in `Monad`.
- **Folding and traversing go through `Foldable` and `Traversable`.** `sum`, `elem`, `length`,
  `mapM_` and friends work on any `Foldable`. `mapM_`, `traverse_` and `sequence_` only ask for
  `Applicative`, and `mapM` is just `traverse`.
- **`Num` is a ring:** `+`, `-`, `*`, `negate` and `fromInteger`. `abs` and `signum` only make
  sense with an order, so they are functions on `(Ord a, Num a)`. `Num` does not require `Eq`
  or `Show`. `Integral` requires `Ord`, and `Floating` has `sqrt`, `pi` and the rest.
- **No partial functions in the Prelude.** `head`, `tail`, `!!`, `maximum` and `minimum` return
  `Maybe`.
- **No `Foldable` instance for tuples,** so `length (1, 2)` is a type error, not `1`.
- **`foldl` is strict,** because the language is, so there is no `foldl'`.
- **`String` is not `[Char]`.**

### Loops and the stack

A strict language cannot rely on laziness to keep monadic recursion flat, and Go has no tail
calls. Hago handles this in two ways, following PureScript:

- **IO is trampolined.** Running an action yields its result or the next action, and the runtime
  loops over them. A `do` block that ends in another action, `>>=` and `*>` therefore use no
  stack: `loop n = do { ...; loop (n + 1) }` runs forever, and `mapM_` over a million elements
  runs in constant memory.
- **`MonadRec` and `tailRecM`** run loops in constant stack in other monads. `IO`, `Maybe` and
  `Either e` have instances, you can write one for your own monad (see `examples/monads.hgo`),
  and `forever` is built on it.

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
| `nfib 40 :: (Ord a, Num a) => a -> a`, Hago, at `Int` | 0.35 s | — |
| sum of the squares of the multiples of 3 up to 3,000,000, through lazy lists | 0.42 s | ~8 MB |
| `mapM_` over a million elements in IO | 0.17 s | ~9 MB |
| a recursive IO loop of five million iterations | 0.31 s | ~8 MB |

- **Strict code at concrete types** compiles to the Go you would write by hand, and runs like it.
- **Constrained and constructor-polymorphic code** (`Num a =>`, `Monad m =>`) costs nothing
  extra, because it is specialised. The price is code size: one copy per type it is used at.
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
monads (State, Maybe, Either, lists, reader, writer, Traversable), calls to Go, and loops. Each example has an `.out` file with its expected output. The `rejected/` folder has
programs the type checker must refuse, each with the error it expects.

## What is there and what isn't

It is a prototype. The pipeline (layout rule, parser, Hindley-Milner inference that elaborates
into a typed core, Go generation) works from end to end, but a lot of Haskell 98 is missing.

**Supported**
- `data` with lazy fields (`~`) and `deriving`, type signatures with contexts, multi-clause
  functions, guards, `where`, `let`, `case`, `if`, lambdas, `do` in any monad, as-patterns,
  `e :: t` annotations.
- `class` with superclasses, default methods and constrained methods, `instance` with contexts,
  classes over types and over type constructors. `Int`, `Double`, `Char`, `String`, `Bool`.
- Operators with `infixl`/`infixr`/`infix` declarations, sections, backquotes, tuples of two and
  three, list literals, `[a..]` and `[a..b]`.
- Let-polymorphism at the top level, with dependency analysis of unsigned bindings.
- `foreign import go`.

**Missing**
- **Type parameters of a higher kind in data types,** so no monad transformers like
  `StateT s m a` yet. Their Go types would have to be specialised as well.
- Multi-parameter classes, `deriving Functor`.
- **Polymorphic recursion through a constraint** (a function that calls itself at a bigger
  type) cannot be specialised, and is rejected.
- **`Read` and `Enum`.** `[a..b]` only works on `Int`.
- **`String` is Go's `string`, not `[Char]`.** Convert with `pack` and `unpack`.
- Modules and imports, records, `newtype` semantics, list comprehensions, `type` synonyms, tuples
  beyond three.
- **`traverse_` over long lists in a monad other than IO uses stack.** Write those loops with
  `tailRecM`.
- **Local bindings are monomorphic.** Go function literals cannot be generic.
- **Polymorphic top-level values are not shared.** `xs = []` becomes a generic function and is
  re-evaluated at each use.
- **`Lazy` is a real type.** Laziness only reaches where the types carry it. For example,
  `foldr` takes `a -> Lazy b -> b` so it can stop early, and `++` and `<>` suspend their second
  argument. The automatic adaptation covers passing strict functions, but you can still meet a
  type error that mentions `Lazy` (`liftA2 (:)` is one; a lambda fixes it).
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
| `src/Hago/Specialize.hs` | copies of code over type constructors; instance methods become functions |
| `src/Hago/CodeGen.hs` | Go generation |
| `runtime/runtime.go` | lists, tuples, thunks and trampolined IO, copied into every program |
| `prelude/Prelude.hgo` | the prelude, written in Hago |

## License

MIT. See [LICENSE](LICENSE).
