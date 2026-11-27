# Hago

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
  runs in constant memory, in IO and in transformers over IO such as `StateT s IO`. An action
  that is run as soon as it is made (a statement of a `do` block, or what a function returns
  when the action of its call is run) is not made at all: a function that returns an action
  also has a Go function that does what the action would, and its call to itself at the end is
  a `for` loop, through `when` or `if` too. Functions that end calling each other are one
  `for` loop over which of them is running, and `main` runs its body instead of making its
  action, so `main = loop 0` is that loop. A call at the end to an action passed as an argument
  still goes through the trampoline, and stays flat (`examples/io-loops.hgo`).
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

- **A module `A.B` lives in `A/B.hgo`,** next to the main file, which is `Main`, or under a
  directory of the search path, or in the standard library, looked in in that order. The
  search path is each `-i DIR` given to `hago` (`build`, `run`, `check`, `repl`), then the
  directories of `HAGO_PATH`, separated as `PATH`'s are: `hago run -i engine/lib game/Main.hgo`.
- **Export and import lists, `qualified`, `as` and `hiding`** work as in Haskell. A type
  exported without `(..)` is abstract.
- **A module can re-export** names it imports, one by one or a whole module with `module M`.
  Two different things with the same name in one export list are an error.
- **Your own definitions shadow imported ones,** so a module can define its own `toList`. Two
  imports giving the same name a different meaning are ambiguous only where the name is used.
- **Instances are global,** as in Haskell.

### The standard library

Some modules come with the compiler, and a program imports them like its own (a module of the
program with the same name comes first). [The library's reference](docs/library/README.md) has
every name each one exports, with its type and what it does:

| Module | What it has |
| --- | --- |
| `Control.Monad` | `foldM`, `replicateM`, `filterM`, `zipWithM`, `>=>`, `liftM2`, `ap`, `void`, and the Prelude's `when`, `unless`, `forM_`... |
| `Control.Monad.State` | `StateT`, `State`, `MonadState` (`get`, `put`), `modify`, `gets`, `runState`, `evalState`, `execState` |
| `Control.Monad.Reader` | `ReaderT`, `Reader`, `MonadReader` (`ask`, `local`), `asks` |
| `Control.Monad.Except` | `ExceptT`, `Except`, `MonadError` (`throwError`, `catchError`), `liftEither` |
| `Control.Monad.Writer` | `WriterT`, `Writer`, `MonadWriter` (`tell`), `runWriter`, `execWriter` |
| `Control.Monad.Trans` | `MonadTrans` (`lift`), `MonadIO` (`liftIO`) |
| `Data.Functor.Identity` | `Identity`, trampolined |
| `Data.String` | `uncons` in constant time (a Go string is sliced, not copied), `length`, `elem`, `isPrefixOf`, `stripPrefix`, `stripSuffix`, `span`, `break`, `takeWhile` and `dropWhile` (slices, in one pass), `concat` in one pass, `intercalate`, `replicate`; import it qualified |
| `Data.List` | `sort` (a stable merge sort), `sortBy`, `sortOn`, `nub`, `group`, `partition`, `intercalate` (of any `Monoid`, so of `String`s too), `intersperse`, `transpose`, `isPrefixOf` and friends, `tails`, `inits`, `subsequences`, `permutations`, `delete`, `\\`, `union`, `intersect`, `elemIndex`, `findIndex`, `unfoldr`, `maximumBy` and `minimumBy` (with `Maybe`), `foldl'` (which is `foldl`: Hago computes as it goes) |
| `Data.Char` | `toUpper`, `toLower`, Unicode's tests (`isPunctuation`, `isSymbol`...), `digitToInt` and `intToDigit` (with `Maybe`) |
| `Control.Applicative` | `ZipList`, `liftA3`, `optional` (`Applicative` and `Alternative` are in the Prelude) |
| `Data.Monoid` | `First`, `Last`, `Min`, `Max`, and the Prelude's `Sum`, `Product`, `Any`, `All` |
| `Data.Ord` | `comparing`, `Down`, `clamp` |
| `Data.Map` | balanced search trees from keys to values, as in containers: `fromList`, `fromListWith`, `insert`, `insertWith`, `lookup`, `!?` (no `!`), `adjust`, `alter`, `delete`, `unionWith`, folds, `Functor` and `Foldable`; import it qualified |
| `Data.Set` | the same for sets: `member`, `union`, `intersection`, `difference`, `isSubsetOf`; import it qualified |
| `Data.IntMap` | `Data.Map` with `Int` keys, under containers' name (`IntMap v` is `Map Int v`); `Data.Map.Strict` and `Data.IntMap.Strict` are the same maps, since Hago's values are computed when they are put in |
| `Data.Sequence` | sequences with `<\|`, `\|>`, `><`, `lookup` and `!?` (with `Maybe`), `update`, `insertAt`, `deleteAt`, `splitAt`, `take`, `drop`, `viewl`, `viewr`, all in logarithmic time: a balanced tree by position, not containers' finger tree, which Hago's specialisation cannot copy; import it qualified |
| `Data.Foldable` | `Foldable` and its functions, the Prelude's, under that name, with `foldl'` |
| `Data.Maybe` | `isJust`, `isNothing`, `catMaybes`, `mapMaybe`, `listToMaybe`, `maybeToList`, `fromMaybe` (no `fromJust`) |
| `Data.Bits` | `.&.`, `.\|.`, `xor`, `complement`, `shiftL`, `shiftR`, `testBit`, `setBit`, `clearBit`, `popCount`, `bit`, `countLeadingZeros`, for `Int` and the integers below |
| `Data.Word`, `Data.Int` | `Word8` to `Word64` and `Word`, `Int8` to `Int64`: Go's integers of those sizes, which wrap around; `Num`, `Integral`, `Enum`, `Bounded`, `Bits` |
| `Data.Vector` | `Vector a`, a Go slice Hago never changes: `fromList`, `!?`, `generate`, `map`, `imap`, `filter`, `foldl`, `slice` (without copying), `sort`, `sortOn`, `zipWith`, `Foldable`; import it qualified |
| `Data.Iter` | `Iter a`, Go's `iter.Seq`: `from`, `range`, `iterate`, `lines`, `words`, `map`, `filter`, `takeWhile`, `take`, `zipWith`, `foldl`, `sum`, `find`, `mapM_`, `singleton`; a `Monad` and a `Monoid`; import it qualified |
| `Data.Ratio` | `Rational` (Go's `*big.Rat`), exact: `%`, `numerator`, `denominator`, `Num`, `Fractional`, `fromRational`, `toRational` |
| `Data.String.Builder` | `Builder`, a `Monoid` of pieces joined in one pass by `toString`, for long texts built from many pieces |
| `Text.Regex` | Go's `regexp` (RE2, linear time): `compile`, `matches`, `find`, `findAll`, `groups`, `replaceAll` (with `$1`), `replaceAllWith`, `split`; import it qualified |
| `Data.Time` | Go's `time.Time`: `getCurrentTime`, `diffSeconds`, `addSeconds`, `format` and `parse` with Go's layouts, `year`, `month`, `day`... |
| `Crypto.Hash`, `Data.Encoding` | `sha1`, `sha256`, `sha512` in hexadecimal; `base64Encode`, `base64Decode`, `hexEncode`, `hexDecode` |
| `System.Process` | `readProcess`: runs a program with arguments and input, and gives its output |
| `Network.HTTP` | `get` and `post` with Go's `net/http`, giving a `Response` with its `status` and `body` |
| `System.Environment` | `getArgs`, `getProgName` |
| `System.IO` | `stdin`, `stdout`, `stderr`, `hPutStrLn`, `hPrint`, `isEOF`, and the rest of Haskell's names for the three standard handles |
| `System.Exit` | `exitWith`, `exitSuccess`, `exitFailure` |
| `System.Random` | `StdGen` (SplitMix64), `mkStdGen`, `randomR`, `random`, `randomRs`, `randoms`, `split`; in IO `newStdGen`, `randomRIO`, seeded by the clock or by `HAGO_RANDOM_SEED` |
| `Control.Concurrent` | `forkIO`, `threadDelay`, `yield`, `getNumCapabilities`; `MVar` with `takeMVar`, `putMVar`, `readMVar`, the `try` versions, `modifyMVar_`, `modifyMVar`, `withMVar` |
| `Control.Concurrent.Channel` | Go's channels: `newChannel` (with the size of its buffer), `send`, `receive` (`Nothing` once closed), `close`, `receiveAll`, and `select` over `onReceive`, `onSend` and `after` |
| `Control.Concurrent.Async` | `async`, `wait`, `poll`, `concurrently`, `race`, `mapConcurrently`, `forConcurrently` and their `_` versions, and `Concurrently`, whose `<*>` runs both sides at once and `<\|>` races them |
| `Control.Parallel` | `parMap`: `map` with the elements computed on every processor |
| `Data.IORef` | `IORef`, a reference threads can share: `newIORef`, `readIORef`, `writeIORef`, `modifyIORef'` and `atomicModifyIORef'` (atomic) |
| `Control.Monad.ST`, `Data.STRef` | `ST s`, `runST` (pure), `STRef` with `newSTRef`, `readSTRef`, `writeSTRef`, `modifySTRef'`; `PrimMonad`, the class of IO and `ST s` |
| `Data.Vector.Mutable` | `MVector s a` (`IOVector a`, `STVector s a`), a Go slice changed in place: `replicate`, `generate`, `read`, `readMaybe`, `write`, `modify`, `swap`, `set`, `length`, `freeze` and `thaw` (copying to and from a `Vector`); import it qualified |
| `Data.HashTable` | `HashTable s k v` (`IOHashTable k v`), a Go map: `new`, `fromList`, `insert`, `insertWith`, `alter`, `lookup` (with `Maybe`), `member`, `delete`, `size`, `toList`; keys are the types Go compares by value (`Key`); import it qualified |

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
- **Guards** have several qualifiers, as in Haskell 2010: conditions, patterns
  (`| Just v <- Map.lookup k m, v > 10 = ...`) and `let`s; when one fails, the next guard is tried,
  then the next clause (`examples/pattern-guards.hgo`). The expression a pattern is matched
  against is computed once.
- **List comprehensions** have generators, guards and `let`, and they are lazy, like the lists
  they build. A generator is a `foldr` that puts each element before the rest or skips it, as
  GHC translates them, so a comprehension kept as a list is a loop that skips what the guards
  drop and makes a cell for each element when it is reached.
- **`deriving`** covers `Eq`, `Ord`, `Show`, `Read`, `Enum`, `Bounded`, `Functor`, `Foldable` and
  `Traversable`. `Enum` needs constructors without fields; `[minBound .. maxBound]` lists every
  value of such a type. The last three map over the last type parameter. `Show` prints records with their fields, as Haskell
  does.

## What the Go looks like

`map` compiles to a generic Go function. A list is a pointer to its first cell, `nil` when it is
empty, and a `Lazy` value is a pointer to a thunk. A cell and the thunk of its tail are one
allocation (the closure that computes the tail is another):

```go
func map_[T_a any, T_b any](_arg0 func(T_a) T_b, _arg1 List[T_a]) List[T_b] {
	...
		if _arg1 != nil {
			x := _arg1.F0
			xs := _arg1.F1
			return func() List[T_b] {
				hg_c := &struct {
					c  Cons[T_b]
					t1 rt_thunk[List[T_b]]
				}{c: Cons[T_b]{F0: g(x)}, t1: rt_thunk[List[T_b]]{f: func() List[T_b] {
					return map_[T_a, T_b](g, xs.force())
				}}}
				hg_c.c.F1 = &hg_c.t1
				return &hg_c.c
			}()
		}
	...
}
```

- **Data types** are kept the cheapest way their shape allows. One with a single constructor
  is that constructor's struct, passed by value, so `data Meters = Meters Double` costs what
  `newtype` does; if it is too big for that (more than eight words) or contains itself, a
  pointer to the struct, whose fields are read through it. A small sum that does not contain
  itself (`Maybe`, `Either`, `Ordering`) is one struct with a tag, also by value. One with two
  constructors, one without fields (a list, `Data.Map`'s trees), is a pointer, `nil` for the
  empty one. Anything else is a Go interface with a struct per constructor. A field of a type that contains itself counts as the pointer
  or interface it is, so a record with a `Map` in it is still kept by value.

- **Polymorphism** becomes Go generics.
- **Calls** to known functions are direct Go calls. Partial application and function values use
  curried closures.
- **Self tail calls** become a `for` loop, so `filter` skips elements and accumulator loops run
  in constant stack. Functions that end calling each other in a circle (a state machine,
  `isEven` and `isOdd`) are one `for` loop over which of them is running, at the top level or
  local (`examples/loops.hgo`).

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
runtime (see [Concurrency](#concurrency)). A Go function that calls the functions it is given
one at a time, never from two goroutines at once, as `strings.Map` does on its own goroutine or a
game library its update and draw, is declared `foreign import go sequential "strings.Map" ...`,
and the program keeps the runtime for one goroutine, whose thunks take no lock. `examples/http-server.hgo` serves pages with
`net/http`, and asks itself for several at once.

A package from outside Go's standard library (`github.com/...`) needs a `go.mod` that says
which version to use. `hago run` looks for one next to the program and in the directories above
it, and builds the program in that Go module, so what it requires and replaces holds, and the
program can import the module's own Go packages (`search-path/` does). Without one, it names the
packages and refuses. `hago build` only writes the Go file; building it is up to you.

## Lists, iterators and vectors

Hago has three kinds of sequence, each for its own job:

| | `[a]` | `Iter a` (`Data.Iter`) | `Vector a` (`Data.Vector`) |
|---|---|---|---|
| What it is | cells with a lazy tail | Go's `iter.Seq` | a Go slice |
| Patterns (`x : xs`) and recursion | yes | no | no |
| Adding in front, sharing the rest | O(1) | no | copies |
| Consumed twice | computed once, shared | computed twice | stored |
| Infinite | yes | yes | no |
| A pipeline over millions of values | one allocation per cell, none when folded where it is made | no allocation per value | stores them all |
| Reaching the n-th element | O(n) | O(n) | O(1) |

- **A list is a data structure:** for recursion and patterns, for building a result one element
  at a time, and for values that share parts (a zipper, a stack). Its tail is lazy, so it can be
  infinite, and what has been computed of it is kept for whoever reads it next.
- **An `Iter` is a computation:** a pipeline of `map`, `filter` and `takeWhile` over something
  big or endless, consumed once. It cannot be taken apart with a pattern, because it has no
  "rest" to give: a `uncons` would have to run it again from the start, or keep what it computed,
  which is what a list is.
- **A `Vector` is data already computed,** reached by position, and the type Go functions give
  and take for slices: `foreign import go "strings.Split" split :: String -> String -> Vector String`.

**A list made only to be folded is never made.** When `sum`, `length`, `foldl`, `maximum`,
`any`, `all`, `elem`, `find`, `and`, `or`, `mapM_`, `forM_` or `traverse_` is given a list
built right there from ranges, `map`, `filter`, `take`, `takeWhile`, `repeat`, `iterate`,
`replicate`, `++`, `concatMap`, `if`, `let` and literals, or a comprehension of them, the
compiler generates the Go loops that visit its elements, nested for a comprehension, and no
cell is allocated: `length [(a, b, c) | c <- [1 .. 400], b <- [1 .. c], a <- [1 .. b], a * a
+ b * b == c * c]` is three `for` loops. What is computed is what the list would hold, in the
same order: every element (a cell's head is strict, so `length (map f xs)` still computes
each `f x`), and no more than the fold asks for (`take 5 (iterate f x)` calls `f` four times,
`any p [1 ..]` stops). `zip` and `zipWith` are loops too: one list is visited by its loops and
the other a step at a time, the first one's cell reached before the second's, as `zip` does.
So is `mapM_` in a monad that passes a state, as `StateT s IO` does: the state is a variable
of the loop. `drop`, `dropWhile`, `zip3`, `zipWith3`, and a `foldr` whose step drops its rest
(it ends the list there) make lists the same way. A `foldr` whose step needs the rest to
compute its own value (`foldr (+) 0 xs`, `foldr max 0 xs`, ``foldr (\x acc -> f x `div` acc) 1 xs``)
is recursion, not a loop. When the step forces the rest outside branches and lambdas, what it
computes before the rest is computed on the way forward, with the elements, and kept with
each one (what cannot fail is left for later), and the rest of the step is taken from the last
element back: everything in the recursion's order, so ten million elements need neither the
Go stack nor a suspension each. The elements are kept in blocks that are never copied, and not
at all when they are a range: it is visited from its end. A list in a variable, or given to a
function, is a list as before (`examples/fusion.hgo`).

A function given to a Go function, as `map`, `filter` and `foldl` give theirs, is generated as a
Go function of all its arguments, so a pipeline over an `Iter` runs like the Go loop it stands
for (see [Performance](#performance)).

`Iter` is a `Monad`, an `Alternative` and a `Monoid`, as lists are, so `do` over iterators is a
comprehension that builds no list:

```haskell
triples :: Int -> Iter (Int, Int, Int)
triples n = do
  c <- Iter.range 1 n
  b <- Iter.range 1 c
  a <- Iter.range 1 b
  guard (a * a + b * b == c * c)
  pure (a, b, c)
```

It is a value that can be passed around and consumed later. A `do` made of `Data.Iter`'s
functions, as this one, compiles to one Go function with the three loops, which gives each
triple to whoever consumes it and allocates nothing per value; a fold (`length`, `sum`,
`foldl`, `find`, `any`, `all`, `elem`) or a `mapM_` of an `Iter` made where it is consumed is
the loops themselves.
Comprehensions and ranges
(`[x | x <- xs]`, `[1 ..]`) are always lists: making them `Iter`s when the type asks for one
would make their type a choice that most uses (`length`, `sum`, `mapM_`) leave open.

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
  without handling threads; through its `Concurrently` applicative, `traverse` does too.
  **`parMap`** (`Control.Parallel`) is a pure `map` computed on every processor, with the same
  result as `map`.
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
  action, which Go could call from another goroutine, unless it is declared `sequential` (see
  [Calling Go](#calling-go)).

## Mutable state

```haskell
import Control.Monad.ST
import Data.STRef
import Data.IORef

sumST :: [Int] -> Int           -- a pure function that mutates inside
sumST xs = runST $ do
  total <- newSTRef 0
  mapM_ (\x -> modifySTRef' total (+ x)) xs
  readSTRef total

main = do
  counter <- newIORef 0
  mapM_ (\x -> modifyIORef' counter (+ x)) [1 .. 10]
  readIORef counter >>= print   -- 55
  print (sumST [1 .. 10])       -- 55
```

- **Most code does not need it:** a fold, a `Data.Map` or the `State` monad say the same without
  changing anything. Mutation pays when the algorithm is written in terms of it, reaching and
  changing elements by position or by key: a sieve, a dynamic programming table, the visited
  set of a graph search, counts in buckets. `examples/sieve.hgo` is 6 to 10 times faster on a
  mutable vector than with a `Data.Map`, and `examples/frequencies.hgo` 3 times faster on a hash
  table (see [Performance](#performance)).
- **In IO:** `Data.IORef`, `Data.Vector.Mutable` (`IOVector a`) and `Data.HashTable`
  (`IOHashTable k v`).
- **In ST, pure from outside.** An `ST s a` is a computation on structures of its own, of
  state `s`: `STRef s a`, `STVector s a`, `HashTable s k v`. `runST` runs it and gives its result,
  and is pure because nothing made inside it is used outside. The type checker gives each
  `runST` a state of its own, a rigid `s` that may appear neither in its result
  (`runST (newSTRef 0)` is rejected: the reference would outlive the computation) nor in the
  types of the variables it uses from outside (a structure of one `runST` cannot be used by
  another). The same arguments give the same result. Haskell writes `runST`'s type as
  `(forall s. ST s a) -> a`; Hago has no such types, and checks `runST` with a rule of its own,
  as GHC once did, so it must be applied to its argument (`runST (do ...)`, `runST $ do ...`)
  rather than passed around.
- **The same functions in both.** A vector is an `MVector s a` and a table a `HashTable s k v`,
  as in Haskell's vector (`IOVector = MVector RealWorld`), and their operations run in any
  `PrimMonad s m`: IO, whose state is `RealWorld`, and `ST s`. A function written once runs in
  both (`histogram` in `examples/mutable.hgo`). References have a type each, as in Haskell,
  because an `IORef` is atomic and an `STRef` does not need to be. At run time an ST action is an
  IO action (newtypes are free), which `runST` runs.
- **An index out of range ends the program,** with `error: index out of range: 10, in a vector of
  length 10`, as in Go. Pure code has no partial functions, but here the index comes from the
  algorithm: one out of bounds is a bug in it, which no result could repair, and a `Maybe` at
  every read in a loop would only be matched to stop. A division by zero ends the program for
  the same reason. `readMaybe` is for an index that comes from outside. There is no `new` with
  elements still undefined: `replicate` and `generate` give each one its value.
- **The keys of a hash table are the types Go compares by value:** `Int`, `Char`, `String`,
  `Bool`, `()`, and tuples of keys, the instances of the class `Key`, which only
  `Data.HashTable` can give. A Go map compares keys with `==`, which for a list or a tree, kept
  as a pointer, is identity, and so it is for an `Integer`; a `Double` can be NaN, which is not
  equal to itself. Other keys go in a `Data.Map`. Generated generic functions take their types
  as `any`, and a Go map needs `comparable`, so the table keeps its map as an `any`: its
  operations are only called from code specialised to a key type, which `Key k` ensures.
- **Threads.** An `IORef` is an atomic pointer to its value, and `modifyIORef'` and
  `atomicModifyIORef'` try again when another thread wrote in between, so no change is lost. A
  vector or table made in IO, in a program that has threads, has a lock that each operation
  takes, so no thread sees half of a value another is writing, and a Go map is never written by
  two at once: each operation is atomic (`insertWith` and `alter` too), a sequence of them is
  not. A program without threads, and anything made in ST, has no lock; nor has a vector or
  table that no other thread can reach: one that the action that made it only gives to the
  operations of its module, in its own statements, the folds that run there and the
  functions it calls that do the same (the compiler checks it, across functions;
  `examples/concurrent-escapes.hgo` has the ways one escapes, under the race detector).
- **Each operation is a call to Go.** `read` and `write` are small functions of the library,
  copied into the code that calls them, and an action run as soon as it is made is not made
  (see [Loops and the stack](#loops-and-the-stack)), so a loop over a vector, in ST or in IO,
  is a Go loop. A read or a write run at once is written out where it is, the index checked
  and the vector indexed in one test, with the runtime's function only for the lock and the
  error: the sieve up to ten million takes 0.03 s, as Go's loop does.

## Performance

These numbers come from one machine (an i7-12700K, Go 1.27, on its eight performance cores),
as a reference and not as a benchmark: each is the median of nine runs. The programs are in
`bench/` (and `examples/`), and `bench/run.sh` measures them, with the compiler of the tree or
side by side with others (`bench/run.sh OLD_HAGO NEW_HAGO`).

| Program | Time | Peak memory |
|---|---|---|
| `nfib 40`, hand-written Go | 0.35 s | — |
| `nfib 40 :: Int -> Int`, Hago | 0.37 s | — |
| `nfib 40 :: (Ord a, Num a) => a -> a`, Hago, at `Int` | 0.36 s | — |
| sum of the squares of the multiples of 3 up to 3,000,000, through lazy lists | <0.01 s | ~2 MB |
| the same with `Data.Iter` (`Iter.sum (Iter.map ... (Iter.from 1))`) | <0.01 s | ~2 MB |
| the same over a `Data.Vector` of 3,000,000 elements | 0.02 s | ~58 MB |
| Pythagorean triples up to 400, as a list comprehension | <0.01 s | ~2 MB |
| the same as `do` over `Iter` | <0.01 s | ~2 MB |
| the same with `Iter.filter` for the last generator and the guard | <0.01 s | ~2 MB |
| `foldr (+) 0 [1 .. 10000000]` | <0.01 s | ~2 MB |
| ``foldr (\x r -> x `mod` 7 + r) 0 [1 .. 10000000]`` (`mod` may fail: kept, computed forward) | 0.03 s | ~81 MB |
| `mapM_` over a million elements in IO | <0.01 s | ~2 MB |
| a recursive IO loop of five million iterations | <0.01 s | ~2 MB |
| the same as two functions that call each other | <0.01 s | ~2 MB |
| two pure functions that end calling each other, a hundred million times | 0.03 s | ~2 MB |
| `mapM_` over a million elements in `StateT Int IO` | <0.01 s | ~2 MB |
| fifty million additions of a `newtype Meters = Meters Double` | 0.02 s | ~2 MB |
| the same with `data Meters = Meters Double` | 0.02 s | ~2 MB |
| parse and pretty print 3.7 MB of JSON with `examples/json.hgo` (`jq .`: 0.09 s, 28 MB) | 0.20 s | ~102 MB |
| `fib 32` sixteen times with `map` | 0.13 s | — |
| the same with `parMap`, on 16 processors | 0.03 s | — |
| a million `Data.Map` inserts, then half a million deletes with `foldl`, and lookups | 0.36 s | ~80 MB |
| the same with a `Data.Set` | 0.34 s | ~81 MB |
| the primes up to a million, sieve of Eratosthenes on an `STVector` (`examples/sieve.hgo`) | <0.01 s | ~3 MB |
| the same with a `Data.Map` (the incremental sieve) | 0.37 s | ~35 MB |
| the primes up to ten million, on an `STVector` | 0.03 s | ~11 MB |
| the same on an `IOVector` | 0.03 s | ~11 MB |
| the same on an `IOVector`, in a program with threads | 0.04 s | ~11 MB |
| the same with a `Data.Map` | 5.2 s | ~120 MB |
| the same, hand-written Go | 0.03 s | ~12 MB |
| how often each of a million numbers appears, in a `HashTable` in ST (`examples/frequencies.hgo`) | 0.12 s | ~35 MB |
| the same with a `Data.Map` | 0.42 s | ~35 MB |

The JSON is the one `bench/json-input.go` writes, always the same:
`go run bench/json-input.go > input.json`, then `hago run examples/json.hgo input.json`.

- **Strict code at concrete types** compiles to the Go you would write by hand, and runs like it.
  `nfib`'s function is the one in the hand-written program; the difference between the two is
  where Go places it, which moves its time by a tenth from one build to another.
- **Small functions are copied into their callers** (`src/Hago/Inline.hs`): the library's
  wrappers (`when`, `unsafePrimIO`, the instances' methods of IO and ST, a vector's `read`)
  leave no call behind, and with them an action run where it is made is not built, so a loop
  in IO or ST is a Go loop (see [Loops and the stack](#loops-and-the-stack)).
- **Local functions that are only called become top-level functions** (`src/Hago/Lift.hs`),
  given what they use from around them as parameters, as GHC does: a `go` in a `where` is not
  a closure made again on each call. A function that only makes local functions and cheap
  values and gives one (`eval c s = go`) takes that function's argument too, so its `go` is
  only called (`examples/lift.hgo`). A third of what Hugen's core allocated. And a value
  written out in the code, a constructor applied to constants (a list of constants, a record
  of literals), is made once, as a top-level value, instead of each time the code around it
  runs; a call is not, even of constants, since keeping its result for the whole run could
  keep a long list alive.
- **Constrained and constructor-polymorphic code** (`Num a =>`, `Monad m =>`) costs nothing
  extra, because it is specialised. The price is code size: one copy per type it is used at.
- **A list folded where it is made** (the pipeline of squares, the comprehension of triples,
  `mapM_` over a range) is a Go loop and allocates nothing (see
  [Lists, iterators and vectors](#lists-iterators-and-vectors)). A list kept in a variable and
  folded later is made: every cell allocates its thunk with it, and the closure that computes
  the rest; the fold is a loop over its cells. A cell known to be the last shares one thunk
  with every other for its empty tail, and `[x] ++ ys` is one cell whose tail is `ys`.
- **Parser combinators** need care. `Text.Parser`'s reply to each step is one constructor small
  enough to be kept by value (the value as a `Maybe`, the input left, what was expected there),
  so a step allocates nothing; whether it consumed input is whether what it left is what it was
  given, and the line and column of an error are only counted when `parse` returns one. A run of
  characters is one step (`takeWhileP`, on `Data.String.span`), and what a parser consumed is a
  slice of the input (`match`), so a number is never put together from its pieces. That took
  the JSON benchmark from 1.86 s to 0.32 s; most of what is left is the pretty printer's
  documents and lists, and Go's garbage collector.
- **Go's garbage collector is not generational:** each cycle marks everything alive, so what
  it costs grows with what a program allocates, and a functional program allocates much and
  briefly. Two things make it cheaper. Programs run with `GOGC=200` unless `GOGC` is set:
  the heap reaches three times what is alive, as GHC's does by default, and the cycles are
  half as many (`Data.Map` 1.79 s → 1.44 s, JSON 0.24 s → 0.22 s, a third more memory); and
  never less than 32 MB, since with little alive Go's least goal made a cycle every few
  megabytes, each waking a worker on every processor (Hugen's core, below a megabyte alive,
  took half the time). And
  **a map built by a fold or a loop is built in place:** inserting into a persistent tree
  copies the path to the key, twenty nodes in a map of a million, but the nodes a fold made
  itself cannot be seen by anything else, so the fold changes them instead (each node keeps
  the owner that made it; see `Data.Map`). The map it starts from, and every map made
  before, stay as they were (`examples/map-in-place.hgo`). A million inserts and deletes
  allocated 1.4 GB; now 22 MB. `alter` and `adjust` are built in place too, and so is a
  `Data.Set`, which is a map whose values are `()`.
- **A recursive function given a known function is copied for it.** One that passes a function
  parameter as it is to every call to itself, as `insertWith` passes its `f`, would call it
  through a curried closure on every step; given a lambda that uses no local variable, or a
  top-level function, at concrete types, it gets a copy without that parameter, the function
  put in its place, and its calls copied in (`examples/specialise.hgo`). The list functions
  that fusion makes loops of are left as they are.
- **Mutable structures** are faster than the trees of `Data.Map` for what they are for, and a
  loop over a mutable vector is Go's loop. In a program with threads, a vector made in IO takes
  a lock on each access, unless no other thread can reach it, which the sieve's cannot (0.03 s
  alone, 0.04 s in a program with threads).

### Against GHC

The same programs written for GHC 9.12 (`ghc -O2`) are in `bench/ghc/`, and
`bench/ghc/run.sh` builds both and times them side by side, on the same machine. They do the
same work: the same algorithms, Hago's strict fields as strict fields in Haskell, and JSON's
combinators, reply and pretty printer ported line by line onto `Data.Text`.

| Program | Hago | GHC |
|---|---|---|
| `nfib 40` | 0.37 s | 0.35 s |
| `nfib 40 :: (Ord a, Num a) => a -> a`, at `Int` | 0.37 s | 0.35 s |
| sum of the squares of the multiples of 3 up to 3,000,000, through lazy lists | <0.01 s | <0.01 s |
| the same over a `Data.Vector` (unboxed in GHC) | 0.02 s | 0.01 s |
| Pythagorean triples up to 400, as a list comprehension | <0.01 s | <0.01 s |
| `foldr (+) 0 [1 .. 10000000]` | <0.01 s, 2 MB | 0.14 s, 169 MB |
| `foldr max 0 [1 .. 10000000]` | <0.01 s, 2 MB | 0.14 s, 169 MB |
| ``foldr (\x r -> x `mod` 7 + r) 0 [1 .. 10000000]`` | 0.03 s, 81 MB | 0.15 s, 169 MB |
| `mapM_` over a million elements in IO | <0.01 s | <0.01 s |
| a recursive IO loop of five million iterations | <0.01 s | 0.01 s |
| the same as two functions that call each other | <0.01 s | 0.01 s |
| two pure functions that end calling each other, a hundred million times | 0.03 s | 0.02 s |
| `mapM_` over a million elements in `StateT Int IO` | <0.01 s | <0.01 s |
| fifty million additions of a `Meters`, `newtype` or `data` | 0.02 s | 0.02 s |
| JSON, 3.7 MB, the same combinators and printer | 0.20 s, 100 MB | 0.29 s, 93 MB |
| `fib 32` sixteen times with `map` (GHC computes it once) | 0.13 s | 0.01 s |
| the same, GHC without full laziness | 0.12 s | 0.13 s |
| the same with `parMap`, on 16 processors | 0.04 s | 0.05 s |
| a million `Data.Map` inserts, half a million deletes, lookups | 0.34 s, 81 MB | 1.40 s, 218 MB |
| a million `Data.Set` inserts, half a million deletes, lookups | 0.35 s, 80 MB | 1.20 s, 156 MB |
| the primes up to a million with a `Data.Map` | 0.37 s | 0.31 s |
| the primes up to ten million, on an `STVector` (`STUArray` in GHC) | 0.03 s | 0.04 s |
| the same on an `IOVector` (`IOUArray`) | 0.03 s | 0.03 s |
| the same, in a program with threads | 0.04 s | 0.04 s |
| frequencies of a million numbers, in a hash table in ST | 0.10 s, 35 MB | 0.20 s, 44 MB |
| the same with a `Data.Map` | 0.41 s | 0.57 s |

- **Even:** strict code at concrete types, newtypes, folds of lists made where they are
  folded (both make loops of them, in IO and in `StateT` too), recursive IO loops, functions
  that end calling each other, mutable arrays, in ST, in IO and in a program with threads,
  `parMap`.
- **Hago ahead:** a `Data.Map` or a `Data.Set` built by a fold or a loop, which Hago builds in
  place (three to four times faster, a third to a half of the memory); a `foldr` that is
  recursion, taken from the last element back (five times faster, with half the memory, or
  none over a range); the JSON parser and printer; the hash table; and memory where much is
  alive.
- **GHC ahead:** the sieve on a map, by a fifth: what is left is the map's own work, the nodes
  of the keys it inserts and the rebalancing, where GHC's generational collector does better
  than Go's. A program with little alive that allocates much takes up to 35 MB, the heap's
  floor.

## Using it

You need GHC (9.12 is tested) with cabal, and Go 1.25 or later (CI tests 1.25 and the newest).

```sh
cabal build
cabal run -v0 hago -- run examples/lazy.hgo                 # compile and run
cabal run -v0 hago -- build examples/lazy.hgo -o lazy.go    # just compile
cabal run -v0 hago -- check examples/lazy.hgo              # just type check
cabal run -v0 hago -- doc                                   # the library's reference, into docs/library
cabal run -v0 hago -- fmt --check examples/*.hgo            # which files hago fmt would change
cabal run -v0 hago -- repl                                  # evaluate expressions as you type them
./check.sh                                                  # every example and rejected program
```

`hago check FILE` type checks a file and the modules it imports, and stops there: no Go is
generated or built. It prints the first error as the compiler does and exits with 1, or exits
with 0 and prints nothing. With the cache full it takes about 0.05 s, so an editor can run it on
every save. The file can be a program, one of its modules (`hago check examples/Data/Json.hgo`
looks for `Data.Json`'s imports from `examples/`, since the module lives in `Data/Json.hgo`), a
module of the standard library (its imports are read from `lib/` next to it, so a library being
edited is checked as it is on disk) or the Prelude.

`hago doc` writes the reference of the Prelude and the standard library into `docs/library`
(`-o DIR` puts it elsewhere): a Markdown file per module and an index. Each page lists what the
module exports, in the order of its source and under the sections the source marks with
`-- Title -----` lines: functions with their types, data types with their exported
constructors and every instance of them, classes with their methods. The names and types are the
type checker's, so they are exact (a synonym appears expanded, as `StateT s Identity`). The text
is the comment block right above each declaration, and the comment at the top of the file
introduces the module. `check.sh` fails if the committed pages are not what `hago doc` makes.

`hago fmt FILE...` changes the whitespace of files in place, and `hago fmt --check FILE...`
names the files it would change and exits with 1, for CI. It does only what cannot move a token
or a comment: a tab in code becomes the spaces up to the column the layout rule gives it,
whitespace at the end of a line goes, blank lines in a row become one, and the file ends with
one newline. String and character literals and comments are left as they are (but for spaces at
the end of a line). It does not lay code out anew, which needs a syntax tree that keeps comments
and the forms the parser desugars (see `progress.md`). Before writing, it parses the result and
checks that the syntax tree and the comments are the same and that formatting it again changes
nothing, and refuses otherwise. `check.sh` runs it over every `.hgo` file of the repository.

### Editors

`editors/vscode` is a VS Code extension, plain JavaScript that installs from the folder (see
[its README](editors/vscode/README.md)): highlighting, comments, brackets and indentation for
`.hgo` files, and the error of `hago check` in the editor every time a file is saved. Its
TextMate grammar, `editors/vscode/syntaxes/hago.tmLanguage.json`, knows Hago's own forms
(`foreign import go` and `foreign import go type`, `Lazy`, the `~` of a lazy field, `p.name`),
and other tools that read TextMate grammars can use it too.

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
hago> name <- getLine
Ada
hago> "hello, " ++ name
"hello, Ada"
```

`hago repl` keeps what you define (functions, `data`, classes, instances, imports) in a module
and type checks it as you go. An expression is compiled with that module into a small program
that prints it, or runs it if it is an action, and Go runs it: about a third of a second each.
`:type` shows the type with its constraints, `:load` brings in a file's definitions (and its
`main`), which a definition at the prompt replaces, and `:{ ... :}` spans several lines.
`:info` says what a name is (a type and its instances, a class and its methods), `:browse`
lists what a module exports, and `:help` lists the commands. There is no line editing;
`rlwrap hago repl` adds it. Without a terminal on its input it echoes each line after the
prompt, so its output is a transcript: `check.sh` replays the sessions in `repl/`.

`pattern <- action` runs the action once and keeps what the pattern binds for the next lines.
Every line is a program of its own, so a value cannot stay in memory: it is kept as the text
`show` gives, in a definition that reads it back with `read` at the type it had. That needs Show
and Read; an MVar, a function, an action or a Go value cannot be kept, and the REPL says so
before running anything. The action is never run again: the next lines see the value, not the
action. A type the action leaves open (`xs <- pure []`) has to be given, and defining a type
again forgets the values kept of it. Without a terminal, an action that reads standard input
finds nothing: the REPL reads all of it.

The `examples/` folder has lazy lists, ADTs with pattern matching and guards, type classes,
monads (State, Maybe, Either, lists, reader, writer, Traversable), monad transformers, modules,
records, newtypes, tuples, ranges, list comprehensions, calls to Go, files, and loops.
`examples/json.hgo` is a bigger program: a JSON parser with errors that say where and what was
expected (`examples/Text/Parser.hgo`, Parsec-style combinators) and a pretty printer
(`examples/Text/Pretty.hgo`, Wadler's, in Lindig's strict form); given a file
(`hago run examples/json.hgo FILE`), it pretty prints it, as `jq .` does. Each example has an `.out` file with its expected output. The `rejected/` folder has
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
- Vectors (Go slices) and iterators (Go's `iter.Seq`).
- Mutable references, vectors and hash tables, in IO and in ST, with a pure `runST`.

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
| `src/Hago/Inline.hs` | small functions copied into the code that calls them |
| `src/Hago/Lift.hs` | local functions that are only called, moved to the top |
| `src/Hago/CodeGen.hs` | Go generation |
| `src/Hago/Cache.hs` | separate compilation: what each module gives, kept on disk |
| `src/Hago/Driver.hs` | finding modules, compiling each, then the whole program |
| `src/Hago/Doc.hs` | `hago doc`: the library's reference, from the type checker and the comments |
| `src/Hago/Format.hs` | `hago fmt`: whitespace only, checked to keep the syntax tree and the comments |
| `runtime/runtime.go` | lists and trampolined IO, copied into every program |
| `runtime/thunk_sequential.go` | thunks for a program on one goroutine |
| `runtime/concurrent.go` | thunks any goroutine can force, threads, MVars, channels, `select`, `parMap`, for a program that uses them |
| `runtime/lib_*.go` | what hashes, encodings, processes, the HTTP client and the mutable structures need, copied only into a program that uses it, so that every program does not import `net/http` or `crypto` |
| `prelude/Prelude.hgo` | the prelude, written in Hago |
| `lib/` | the standard library (`Control.Monad.State` and friends), written in Hago |
| `docs/library/` | the library's reference, made by `hago doc` |
| `editors/vscode/` | the VS Code extension: the TextMate grammar, and `hago check` on save |
| `search-path/` | a program whose modules are found through `-i` and `HAGO_PATH`, run in its own Go module |
| `bench/json-input.go` | writes the JSON of the benchmark in [Performance](#performance) |
| `bench/run.sh` | the programs of [Performance](#performance), built and timed, with one compiler or several side by side |
| `bench/ghc/` | the same programs for GHC, and `run.sh`, which times them against Hago's |

## License

MIT. See [LICENSE](LICENSE).
