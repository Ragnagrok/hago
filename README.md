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
  `Lazy` parameters is expected (`foldr insert Leaf xs`) is wrapped automatically. The other
  way round too: a type variable never stands for `Lazy t`, so a function with `Lazy`
  parameters passed where a plain function is expected (`liftA2 (:)`, `map (False &&)`) takes
  plain arguments there. `f $ x` is `f x`, so `x` stays lazy when `f` asks for it.

Suspensions are memoised thunks, evaluated at most once. A program that runs on one goroutine
gets thunks that take no lock. One that starts goroutines (see [Concurrency](#concurrency)) gets
thunks that any goroutine can force: the first computes the value holding the thunk's lock, and
once it is computed, forcing it is one atomic load. The lazy list benchmark below runs 2% slower
with them.

Top-level values are computed when the program starts, in order. Values whose computations need
each other (`x = y + 1`, `y = x + 1`) cannot be, and are rejected. Values that are functions can
refer to each other, as parsers built from combinators do: each starts as a function that
computes the value on its first call.

Local bindings, in a `let` or a `where`, are computed where they are needed: one that only some
branches use (of an `if`, a `case` or guards) is computed in those branches, and one that nothing
uses is not computed at all. So `safeDiv a b | b == 0 = Nothing | otherwise = Just q where
q = a `div` b` does not divide by zero, as it would if `q` were computed before the guards. The
code is pure, so computing a binding on fewer paths can only avoid failures, never change a
result. What a guard, a condition or a scrutinee uses is computed before it, and what only a
later guard uses, after the guards before it fail (unless an earlier guard needs some of the
same bindings, which would then be computed twice).

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
  `p <- e` can bind a pattern.
- **Data types can take a type constructor,** so monad transformers can be written:
  `data StateT s m a = StateT (s -> m (a, s))`. Go has no such type parameters, so each use gets
  its own Go type: `StateT s IO a` becomes `StateT__IO[S, A]`, generated only for the
  combinations the program uses. `examples/transformers.hgo` defines `StateT`, `ExceptT`,
  `MonadTrans`, `MonadIO`, `MonadState` and `MonadError`, and runs one stack machine on
  `StateT [Int] (ExceptT String IO)` and on `ExceptT String (StateT [Int] IO)`.
- **Classes can have several parameters, with a functional dependency** from one of them to
  the others, as in mtl: `class Monad m => MonadState s m | m -> s`. The monad chooses the
  instance and fixes the state's type, so with `MonadState Int m`, `n <- get` makes `n` an
  `Int`. Instances that pass the operations through other transformers
  (`MonadState s m => MonadState s (ExceptT e m)`) make `get`, `put` and `throwError` work
  anywhere in a stack without `lift`, and a function asks only for what it uses:
  `pop :: (MonadState [Int] m, MonadError String m) => m Int`. Each stack it is used with gets
  its own copy, so this costs nothing at run time.
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
- **A polymorphic value is a template too,** so it is computed once per type. `table :: Num a
  => [a]` used at `Int` and at `Double` becomes two Go variables, each computed once, as a
  monomorphic value would be. Only a use inside a generic function, at that function's own type
  variable, still recomputes it, because Go has no generic variables.

## A hierarchy without Haskell's mistakes

The Prelude keeps Haskell's classes, but not the decisions that Haskell itself had to undo or
still lives with:

- **`Functor => Applicative => Monad` from the start.** `return` is not a method, just `pure`.
- **`Semigroup => Monoid`.** `<>` is the only way to combine, and there is no `mappend`.
- **`fail` lives in `MonadFail`,** not in `Monad`.
- **Folding and traversing go through `Foldable` and `Traversable`.** `sum`, `elem`, `length`,
  `mapM_` and friends work on any `Foldable`. `traverse_` only asks for `Applicative`, and
  `mapM` is just `traverse`. `mapM_` and `forM_` use `>>=`, as in base, which keeps the rest of
  a loop suspended until it runs.
- **`Num` is a ring:** `+`, `-`, `*`, `negate` and `fromInteger`. `abs` and `signum` only make
  sense with an order, so they are functions on `(Ord a, Num a)`. `Num` does not require `Eq`
  or `Show`. `Integral` requires `Ord`, and `Floating` has `sqrt`, `pi` and the rest.
- **No partial functions in the Prelude.** `head`, `tail`, `!!`, `maximum` and `minimum` return
  `Maybe`, and so does `read`: `read "4x" :: Maybe Int` is `Nothing`, not a crash.
- **Pattern matches cover every value,** or the program is rejected: the clauses of a function,
  a `case`, a lambda's patterns, `let Just x = ...` and `Just x <- ...` in `do`. The error shows
  a value nothing matches (`nothing matches Nothing`, `nothing matches 0`). Guards count when one
  is `otherwise` (or `True`), or when they complement each other: a condition and its `not`,
  `even` and `odd` of the same number, or comparisons of the same two values that between them
  cover less, equal and greater (`n > 0`, `n < 0`, `n == 0`) at `Int`, `Integer`, `Char`,
  `String` or `Bool`. Not at `Double`, where `n < 0` and `n >= 0` are both false for NaN, nor
  at a type whose `Ord` someone wrote, which need not be lawful.
- **No `Foldable` instance for tuples,** so `length (1, 2)` is a type error, not `1`.
- **`Enum` is total.** `toEnum`, `succ` and `pred` return `Maybe`, so `succ maxBound` is
  `Nothing` instead of a crash, and `[x ..]` on a bounded type stops at its last value.
- **No `Enum Double`.** `[0.1, 0.2 .. 1.0]` goes past `1.0` in Haskell, because a range of
  floating-point numbers cannot be exact. Hago refuses it and suggests mapping over a range of
  `Int`.
- **`foldl` is strict,** because the language is, so there is no `foldl'`.
- **`String` is not `[Char]`.**

### Loops and the stack

A strict language cannot rely on laziness to keep monadic recursion flat, and Go has no tail
calls. Hago handles this in three ways, following PureScript and Scala's Cats:

- **IO is trampolined.** Running an action yields its result or the next action, and the runtime
  loops over them. A `do` block that ends in another action, `>>=` and `*>` therefore use no
  stack: `loop n = do { ...; loop (n + 1) }` runs forever, and `mapM_` over a million elements
  runs in constant memory, in IO and in transformers over IO such as `StateT s IO`.
- **So is `Identity`,** the library's pure monad, and with it every transformer over it: the
  library's `State s` is `StateT s Identity`, as are `Reader` and `Except`. Ten million steps of
  `loop n = do { modify (+ n); loop (n - 1) }` run in 10 MB, and a million run faster than in a
  hand-written `s -> (a, s)` monad, which grows the Go stack by a frame per step and dies near
  ten million, at Go's 1 GB limit.
- **`MonadRec` and `tailRecM`** run loops in constant stack in a monad of your own. `IO`,
  `Maybe`, `Either e` and the library's transformers have instances, you can write one (see
  `examples/monads.hgo`), and `forever` is built on it.

## Modules

```haskell
module Data.Stack (Stack, empty, push, pop) where   -- Stack is abstract

import qualified Data.Stack as S
import Geometry.Shapes (Shape(..), area)
import Geometry.Shapes hiding (perimeter)

module Geometry (module Geometry.Shapes, scale) where   -- re-exports Geometry.Shapes
```

- **A module `A.B` lives in `A/B.hgo`,** next to the main file, which is `Main`, or in the
  standard library.
- **Export and import lists, `qualified`, `as` and `hiding`** work as in Haskell. A type
  exported without `(..)` is abstract.
- **A module can re-export** names it imports, one by one or a whole module with `module M`.
  Two different things with the same name in one export list are an error.
- **Your own definitions shadow imported ones,** so a module can define its own `toList`. Two
  imports giving the same name a different meaning are ambiguous only where the name is used.
- **Instances are global,** as in Haskell.

### The standard library

Some modules come with the compiler, and a program imports them like its own (a module of the
program with the same name comes first):

| Module | What it has |
| --- | --- |
| `Control.Monad` | `foldM`, `replicateM`, `filterM`, `zipWithM`, `>=>`, `liftM2`, `ap`, `void`, and the Prelude's `when`, `unless`, `forM_`... |
| `Control.Monad.State` | `StateT`, `State`, `MonadState` (`get`, `put`), `modify`, `gets`, `runState`, `evalState`, `execState` |
| `Control.Monad.Reader` | `ReaderT`, `Reader`, `MonadReader` (`ask`, `local`), `asks` |
| `Control.Monad.Except` | `ExceptT`, `Except`, `MonadError` (`throwError`, `catchError`), `liftEither` |
| `Control.Monad.Writer` | `WriterT`, `Writer`, `MonadWriter` (`tell`), `runWriter`, `execWriter` |
| `Control.Monad.Trans` | `MonadTrans` (`lift`), `MonadIO` (`liftIO`) |
| `Data.Functor.Identity` | `Identity`, trampolined |
| `Data.String` | `uncons` in constant time (a Go string is sliced, not copied), `length`, `elem`, `isPrefixOf`, `stripPrefix`, `concat` in one pass, `intercalate`, `replicate`; import it qualified |
| `Data.List` | `sort` (a stable merge sort), `sortBy`, `sortOn`, `nub`, `group`, `partition`, `intercalate` (of any `Monoid`, so of `String`s too), `intersperse`, `transpose`, `isPrefixOf` and friends, `tails`, `inits`, `subsequences`, `permutations`, `delete`, `\\`, `union`, `intersect`, `elemIndex`, `findIndex`, `unfoldr`, `maximumBy` and `minimumBy` (with `Maybe`) |
| `Data.Char` | `toUpper`, `toLower`, Unicode's tests (`isPunctuation`, `isSymbol`...), `digitToInt` and `intToDigit` (with `Maybe`) |
| `Control.Applicative` | `ZipList`, `liftA3`, `optional` (`Applicative` and `Alternative` are in the Prelude) |
| `Data.Monoid` | `First`, `Last`, `Min`, `Max`, and the Prelude's `Sum`, `Product`, `Any`, `All` |
| `Data.Ord` | `comparing`, `Down`, `clamp` |
| `Data.Map` | balanced search trees from keys to values, as in containers: `fromList`, `fromListWith`, `insert`, `insertWith`, `lookup`, `!?` (no `!`), `adjust`, `alter`, `delete`, `unionWith`, folds, `Functor` and `Foldable`; import it qualified |
| `Data.Set` | the same for sets: `member`, `union`, `intersection`, `difference`, `isSubsetOf`; import it qualified |
| `System.Environment` | `getArgs`, `getProgName` |
| `System.IO` | `stdin`, `stdout`, `stderr`, `hPutStrLn`, `hPrint`, `isEOF`, and the rest of Haskell's names for the three standard handles |
| `System.Exit` | `exitWith`, `exitSuccess`, `exitFailure` |
| `System.Random` | `StdGen` (SplitMix64), `mkStdGen`, `randomR`, `random`, `randomRs`, `randoms`, `split`; in IO `newStdGen`, `randomRIO`, seeded by the clock or by `HAGO_RANDOM_SEED` |
| `Control.Concurrent` | `forkIO`, `threadDelay`, `yield`, `getNumCapabilities`; `MVar` with `takeMVar`, `putMVar`, `readMVar`, the `try` versions, `modifyMVar_`, `modifyMVar`, `withMVar` |
| `Control.Concurrent.Channel` | Go's channels: `newChannel` (with the size of its buffer), `send`, `receive` (`Nothing` once closed), `close`, `receiveAll`, and `select` over `onReceive`, `onSend` and `after` |
| `Control.Concurrent.Async` | `async`, `wait`, `poll`, `concurrently`, `race`, `mapConcurrently`, `forConcurrently` and their `_` versions |
| `Control.Parallel` | `parMap`: `map` with the elements computed on every processor |

The Prelude reads and writes files and standard input: `getContents` and `interact` (which
read the whole input first), and `readFile`, `writeFile` and `appendFile`, which return an
`Either String` since they can fail. `getLine` gives `""` at the end of the input, which
`System.IO.isEOF` tells apart from an empty line.

Each class passes through the other transformers, as in mtl, so a function can ask for
`(MonadReader Config m, MonadState Int m, MonadError String m)` and run on any stack that has
them. `examples/mtl.hgo` uses all of them.

A renaming pass resolves every name to an internal one qualified by its module
(`Geometry.Shapes.area`), so modules never clash once compiled.

### Separate compilation

Each module is renamed and type checked on its own, with what its imports give it (directly or
through other imports) and nothing else, which is also what decides which instances it sees.
What a module gives the modules after it (its names, synonyms, fixities, and its checked
declarations with every type resolved) is kept in a cache, under a key made of the compiler,
the module's source and its imports' keys. The next compilation reuses it while that key does
not change: the Prelude and the library are checked once, and so is every module you have not
touched or whose imports have not changed.

Specialisation and Go generation still see the whole program, as monomorphisation does in Rust:
a template is copied for the types each program uses it at. They start from `main` and only
emit what it reaches, so a program that prints a number is 5 KB of Go, not the whole Prelude.

The cache lives in `~/.cache/hago`; `HAGO_CACHE=dir` moves it, and `HAGO_CACHE=off` turns it
off. Compiling an example takes about 0.35 s the first time and 0.15 s to 0.25 s after that,
plus `go build`.

## Records, without Haskell's mistakes

```haskell
data Point = Point { x, y :: Double }
data Person = Person { name :: String, age :: Int, home :: Point }
data Company = Company { name :: String, staff :: [Person] }   -- name again: fine

ana = Person { name = "Ana", age = 30, home = Point { x = 1.0, y = 2.0 } }

ana.name                      -- "Ana"
map (.age) acme.staff         -- a field as a function
ana { age = 31 }              -- an update
ana { home.x = 3.5 }          -- an update of a field of a field
area (Circle { radius }) = 3.0 * radius * radius   -- match some fields
```

Haskell's records have well-known problems. Hago avoids each of them:

- **Fields are not functions.** In Haskell a field declares a top-level function, so two types
  in the same module cannot both have a `name`, and no one else can use that name. In Hago a
  field belongs to its type. You read it with `p.name`, and the type of `p` says which `name` it
  is. When you need a function, `(.name)` is one.
- **Reading a field cannot fail.** Haskell accepts `radius s` for a `Square` and fails at run
  time. Hago accepts `s.radius`, and an update of `radius`, only if every constructor of the type
  has that field. Otherwise it asks you to match on the constructor.
- **Building a record requires every field.** Haskell only warns about a missing field and
  leaves an error in its place. Hago refuses to compile it.
- **Fields respect abstraction.** They are visible wherever the type's constructors are, so a
  type exported without `(..)` keeps its fields hidden too.
- **Nested updates are short.** `p { home.x = 3.5 }` instead of
  `p { home = (home p) { x = 3.5 } }`.

Field puns work in patterns and when building (`Person { name, age }`), and `C {}` matches any
`C`. As in GHC's `OverloadedRecordDot`, a dot with no space on either side is a field access, so
`f.g` is no longer a composition; write `f . g`.

If the type of `p` is not known yet and two types have the field, the compiler asks for an
annotation instead of guessing. To make that rare, arguments that are lambdas are checked after
the others: in `map (.name) people`, the type of `people` is known before `(.name)` is checked.

As in Haskell 98, an update can change a type parameter that only the updated fields mention:
setting the `item` of a `Box Int` to a string gives a `Box String`.

## Newtypes are free

In a strict language, `newtype` means the same as `data` with one constructor and one field.
What the keyword adds is a promise that the wrapper costs nothing, and Hago keeps it. After
specialisation, when every instance has already been chosen by type, each newtype is replaced by
the type it wraps. Wrapping, unwrapping and the Go type disappear. `newtype Meters = Meters
Double` is a `float64` in the Go output, and it keeps its own instances.

With `data`, a loop that adds `Meters` allocates a box at each step. Fifty million additions
take 0.36 s and 10 MB with `data`, and 0.02 s and 3.7 MB with `newtype`. A `StateT` declared
with `newtype` compiles to plain closures.

A newtype stays a Go type only if it contains itself (`newtype Fix f = Fix (f (Fix f))`), or if
it is passed without all its arguments to a data type that takes a type constructor.

## Synonyms, comprehensions, deriving

```haskell
type Pair a = (a, a)

[(a, b) | a <- [1 .. 4], b <- ['x', 'y'], odd a]
[n * n | Just n <- maybes]                  -- elements that don't match are skipped
take 5 [n | n <- [1 ..], let sq = n * n, sq `mod` 3 == 1]

data Tree a = Leaf | Node (Tree a) a (Tree a)
  deriving (Show, Functor, Foldable, Traversable)
```

- **`type` synonyms** take parameters and can be exported. They must be given all their
  arguments, and a synonym that refers to itself is an error.
- **List comprehensions** have generators, guards and `let`, and they are lazy, like the lists
  they build.
- **`deriving`** covers `Eq`, `Ord`, `Show`, `Read`, `Enum`, `Bounded`, `Functor`, `Foldable` and
  `Traversable`. `Enum` needs constructors without fields; `[minBound .. maxBound]` lists every
  value of such a type. The last three map over the last type parameter. `Show` prints records with their fields, as Haskell
  does.

## What the Go looks like

`map` compiles to a generic Go function. A list is a pointer to its first cell, `nil` when it is
empty, and a `Lazy` value is a pointer to a thunk:

```go
func map_[T_a any, T_b any](_arg0 func(T_a) T_b, _arg1 List[T_a]) List[T_b] {
	...
		if _arg1 != nil {
			x := _arg1.F0
			xs := _arg1.F1
			return &Cons[T_b]{g(x), rt_lazy(func() List[T_b] {
				return map_[T_a, T_b](g, xs.force())
			})}
		}
	...
}
```

- **Data types** are kept the cheapest way their shape allows. One with a single constructor
  is that constructor's struct, passed by value, so `data Meters = Meters Double` costs what
  `newtype` does. A small sum that does not contain itself (`Maybe`, `Either`, `Ordering`) is
  one struct with a tag, also by value. One with two constructors, one without fields (a list,
  `Data.Map`'s trees), is a pointer, `nil` for the empty one. Anything else is a Go interface
  with a struct per constructor.

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
  the boundary unchanged. `Integer` is a `*big.Int` that is never modified.
- A Go function that returns `(T, error)` is declared as returning `Either String T`, or
  `IO (Either String T)` if it has effects. One that returns only an `error` is an
  `Either String ()`.
- `IO ()` means the Go function is called for its effects and its results are ignored.
- The package is imported from the path before the last dot: `"path/filepath.Join"` imports
  `path/filepath`.
- A function declared without `IO` is a promise you make that it is pure.
- A polymorphic one is a generic Go function, whose type parameters are the Hago type variables
  in the order they first appear in the signature.

A Go type that Hago code only passes around is declared with `foreign import go type`:

```haskell
foreign import go type "*net/url.URL" URL
foreign import go "net/url.Parse" parseURL :: String -> Either String URL
foreign import go type "*rt_MVar" MVar a       -- the runtime's, generic: *rt_MVar[T]
```

It has no constructors, so Hago code cannot look inside it or make one; Go functions do that, and
so do its fields and methods. A symbol that starts with a dot is a selector on the first
argument, followed by the other arguments if there are any:

```haskell
foreign import go ".Scheme"          scheme     :: URL -> String            -- u.Scheme
foreign import go ".Hostname()"      hostname   :: URL -> String            -- u.Hostname()
foreign import go ".Query().Get"     queryParam :: URL -> String -> String  -- u.Query().Get(k)
```

A Hago function or action given to a Go function becomes the Go function it expects, taking all
its arguments at once and running the action it makes:

```haskell
foreign import go "strings.Map" mapRunes :: (Char -> Char) -> String -> String
foreign import go ".HandleFunc" handleFunc
  :: ServeMux -> String -> (ResponseWriter -> Request -> IO ()) -> IO ()
```

Go may call it from any goroutine, so a program that gives Go a function gets the concurrent
runtime (see [Concurrency](#concurrency)). `examples/http-server.hgo` serves pages with
`net/http`, and asks itself for several at once.

## Concurrency

A Hago thread is a goroutine: starting one is cheap, and thousands can run at once.

```haskell
import Control.Concurrent
import Control.Concurrent.Async

main = do
  counter <- newMVar 0
  mapConcurrently (\_ -> modifyMVar_ counter (pure . (+ 1))) [1 .. 1000]
  readMVar counter >>= print                       -- 1000
  race (threadDelay 100000) (pure "fast") >>= print  -- Right "fast"
```

- **MVars** (`Control.Concurrent`) are boxes that are empty or hold one value: `takeMVar` waits
  until there is one, `putMVar` until there is room. **Channels**
  (`Control.Concurrent.Channel`) are Go's, buffer, `close` and `select` included.
  **`Control.Concurrent.Async`** runs actions at the same time and waits for their results,
  without handling threads. **`parMap`** (`Control.Parallel`) is a pure `map` computed on every
  processor, with the same result as `map`.
- **Values are immutable, so threads share them freely.** The only state they share and change
  is in MVars and channels. A lazy list can be shared too: its cells are computed once, by
  whichever thread forces them first. The examples run under Go's race detector in `check.sh`.
- **A failure in any thread ends the program,** with `error:` and the reason, as in the main one.
  Hago has no exceptions to catch, so there is nothing to hand to the thread that waits.
- **Go cannot stop a goroutine from outside,** so there is no `killThread`, and `race` does not
  cancel the action that loses: it runs to the end, and its result is dropped. A thread that
  should stop early has to be told, through an MVar or a channel.
- **When every thread is waiting for another,** Go stops the program with `fatal error: all
  goroutines are asleep - deadlock!`. Go would add the trace of every goroutine, unless
  `GOTRACEBACK=none` is set when the program starts, so a program that uses concurrency starts
  itself again with it.
- **Only programs that use concurrency pay for it.** A program gets the concurrent runtime when
  it calls a function from these modules, or a Go function that is given a Hago function or
  action, which Go could call from another goroutine.

## Performance

These numbers come from one machine, as a reference and not as a benchmark.

| Program | Time | Peak memory |
|---|---|---|
| `nfib 40`, hand-written Go | 0.34 s | — |
| `nfib 40 :: Int -> Int`, Hago | 0.34 s | — |
| `nfib 40 :: (Ord a, Num a) => a -> a`, Hago, at `Int` | 0.35 s | — |
| sum of the squares of the multiples of 3 up to 3,000,000, through lazy lists | 0.45 s | ~10 MB |
| `mapM_` over a million elements in IO | 0.19 s | ~8 MB |
| a recursive IO loop of five million iterations | 0.31 s | ~8 MB |
| `mapM_` over a million elements in `StateT Int IO` | 0.25 s | ~8 MB |
| fifty million additions of a `newtype Meters = Meters Double` | 0.02 s | ~4 MB |
| the same with `data Meters = Meters Double` | 0.02 s | ~4 MB |
| parse and pretty print 3.7 MB of JSON with `examples/Data/Json.hgo` (`jq .`: 0.13 s) | 2.6 s | ~140 MB |
| `fib 32` sixteen times with `map` | 0.11 s | — |
| the same with `parMap`, on 8 processors | 0.02 s | — |
| a million `Data.Map` inserts, then half a million deletes with `foldl`, and lookups | 1.45 s | ~170 MB |

- **Strict code at concrete types** compiles to the Go you would write by hand, and runs like it.
- **Constrained and constructor-polymorphic code** (`Num a =>`, `Monad m =>`) costs nothing
  extra, because it is specialised. The price is code size: one copy per type it is used at.
- **The lazy list pipeline** streams in constant memory, but every cell allocates a thunk, so it
  is much slower than a Go loop.
- **Parser combinators** are slow: every step returns a value of a sum type (`Ok` or `Failed`)
  too big to be kept by value, so each one is allocated, and so is every thunk of a lazy list.
  Most of the time is Go's garbage collector. Parsing the input as a
  `[Char]` (with `unpack`) was four times slower again; `Data.String.uncons` reads a `String`
  without a list.

## Using it

You need GHC (9.12 is tested) with cabal, and Go 1.21 or later.

```sh
cabal build
cabal run -v0 hago -- run examples/lazy.hgo                 # compile and run
cabal run -v0 hago -- build examples/lazy.hgo -o lazy.go    # just compile
cabal run -v0 hago -- repl                                  # evaluate expressions as you type them
./check.sh                                                  # every example and rejected program
```

### The REPL

```
hago> :t pure 3
pure 3 :: (Applicative f, Num a) => f a
hago> let double x = x + x
hago> double 2.5
5.0
hago> :load repl/Shapes.hgo
loaded repl/Shapes.hgo
hago> area (Rect 2.0 5.0)
10.0
```

`hago repl` keeps what you define (functions, `data`, classes, instances, imports) in a module
and type checks it as you go. An expression is compiled with that module into a small program
that prints it, or runs it if it is an action, and Go runs it: about a third of a second each.
`:type` shows the type with its constraints, `:load` brings in a file's definitions (and its
`main`), which a definition at the prompt replaces, and `:{ ... :}` spans several lines. There is
no line editing; `rlwrap hago repl` adds it. Without a terminal on its input it echoes each line
after the prompt, so its output is a transcript: `check.sh` replays the sessions in `repl/`.

The `examples/` folder has lazy lists, ADTs with pattern matching and guards, type classes,
monads (State, Maybe, Either, lists, reader, writer, Traversable), monad transformers, modules,
records, newtypes, tuples, ranges, list comprehensions, calls to Go, files, and loops.
`examples/json.hgo` is a bigger program: a JSON parser with errors that say where and what was
expected (`examples/Text/Parser.hgo`, Parsec-style combinators) and a pretty printer
(`examples/Text/Pretty.hgo`, Wadler's, in Lindig's strict form). Each example has an `.out` file with its expected output. The `rejected/` folder has
programs the type checker must refuse, each with the error it expects.

An error says where it is, quotes the line and marks the place:

```
rejected/mismatch.hgo:3:18: in main: type mismatch: expected String, got Int
  |
3 | main = putStrLn (length [1, 2, 3])
  |                  ^^^^^^
```

## What is there and what isn't

It is a prototype. The pipeline (layout rule, parser, Hindley-Milner inference that elaborates
into a typed core, Go generation) works from end to end, but a lot of Haskell 98 is missing.

**Supported**
- `data` with lazy fields (`~`) and `deriving`, records, `newtype`, `type` synonyms, list
  comprehensions, type signatures with contexts, multi-clause
  functions, guards, `where`, `let`, `case`, `if`, lambdas, `do` in any monad, as-patterns,
  pattern bindings (`let (q, r) = ...`), `e :: t` annotations, literals with exponents.
- `class` with superclasses, default methods and constrained methods, `instance` with contexts,
  classes over types and over type constructors, classes with several parameters and a
  functional dependency. `Int`, `Integer` (any size, Go's `*big.Int`), `Double`, `Char`, `String`, `Bool`.
- Operators with `infixl`/`infixr`/`infix` declarations, sections, backquotes, tuples of up to
  fifteen elements (as Haskell 98 asks; past that, a record), list literals, and ranges (`[a ..]`, `[a, b ..]`, `[a .. c]`, `[a, b .. c]`) over any `Enum`.
- Let-polymorphism, with dependency analysis of unsigned bindings, for local functions too: a
  local helper can be used at several types and have constraints. Go function literals cannot
  be generic, so such a function moves to the top level, taking the local variables it uses as
  extra parameters.
- `foreign import go`, and `foreign import go type`.
- Threads, MVars, Go's channels and `select`, `async`, and `parMap`.

**Missing**
- **Polymorphic recursion through a constraint** (a function that calls itself at a bigger
  type) cannot be specialised, and is rejected.
- **`String` is Go's `string`, not `[Char]`.** Convert with `pack` and `unpack`.
- **There is no package manager,** and the Go output is one file: specialisation needs the
  whole program, so only the type checking of each module is kept between compilations.
- **A monad you write as a function, like `newtype State s a = State (s -> (a, s))`, uses a Go
  stack frame per `>>=`,** because Go has no tail calls. Write long loops in it with `tailRecM`,
  or build it on the library's transformers, whose loops are flat.
- **A class with several parameters needs one functional dependency,** from one of them to all
  the others, which chooses the instance. `class Convert a b`, without one, is rejected.
- **Some local definitions stay monomorphic:** values (as with Haskell's monomorphism
  restriction, so they are computed once), and functions with constraints on the types of the
  function around them, whose dictionaries belong to that function.
- **A polymorphic value used inside a generic function is recomputed there,** at that
  function's type variable. At concrete types it is computed once.
- **`Lazy` is a real type.** Laziness only reaches where the types carry it. For example,
  `foldr` takes `a -> Lazy b -> b` so it can stop early, and `++` and `<>` suspend their second
  argument. Since a type variable never stands for `Lazy t`, a polymorphic function passed to
  `foldr` is strict in the accumulator: `foldr const 0 [1 ..]` never ends, and
  `foldr (\x _ -> x) 0 [1 ..]` is `1`, because a lambda takes the type it is checked against.

## Layout of the code

| File | What it does |
|---|---|
| `src/Hago/Lexer.hs` | tokens and the layout rule |
| `src/Hago/Parser.hs` | Parsec over tokens, fixity resolution |
| `src/Hago/Rename.hs` | modules: imports, exports and scopes, into qualified names |
| `src/Hago/Expand.hs` | `type` synonyms, expanded away |
| `src/Hago/Derive.hs` | `deriving (Eq, Ord, Show, Read, Enum, Bounded, Functor, Foldable, Traversable)` |
| `src/Hago/TcMonad.hs` | unification and the constraint solver (instances, defaulting) |
| `src/Hago/Typecheck.hs` | inference and elaboration, where `Lazy` and dictionaries are inserted |
| `src/Hago/Core.hs` | the typed core |
| `src/Hago/Specialize.hs` | copies of code over type constructors; instance methods become functions |
| `src/Hago/Newtype.hs` | newtypes replaced by the type they wrap |
| `src/Hago/CodeGen.hs` | Go generation |
| `src/Hago/Cache.hs` | separate compilation: what each module gives, kept on disk |
| `src/Hago/Driver.hs` | finding modules, compiling each, then the whole program |
| `runtime/runtime.go` | lists and trampolined IO, copied into every program |
| `runtime/thunk_sequential.go` | thunks for a program on one goroutine |
| `runtime/concurrent.go` | thunks any goroutine can force, threads, MVars, channels, `select`, `parMap`, for a program that uses them |
| `prelude/Prelude.hgo` | the prelude, written in Hago |
| `lib/` | the standard library (`Control.Monad.State` and friends), written in Hago |

## License

MIT. See [LICENSE](LICENSE).
