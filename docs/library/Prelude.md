# Prelude

The Hago prelude, compiled together with every program.

The class hierarchy is Haskell's with its known mistakes fixed:
  * Functor => Applicative => Monad, and return is just pure.
  * Semigroup => Monoid, and <> is the only way to combine.
  * fail lives in MonadFail, not in Monad.
  * Folding and traversing work on any Foldable or Traversable;
    traverse_ only asks for Applicative, and mapM is traverse.
  * Num is a ring: abs and signum need an order, so they are functions
    on (Ord a, Num a). Decimal literals are overloaded through Fractional.
  * No partial functions: head, tail, !!, maximum and minimum return Maybe.
  * No Foldable instance for tuples, so length (1, 2) is a type error.
  * foldl is strict, because the language is.
  * Long monadic loops have MonadRec (tailRecM), and IO is trampolined,
    since a strict language cannot rely on laziness to keep the stack flat.

Its source is [`prelude/Prelude.hgo`](../../prelude/Prelude.hgo).

```haskell
data Maybe a = Nothing | Just a

instance Alternative Maybe
instance Applicative Maybe
instance Eq a => Eq (Maybe a)
instance Foldable Maybe
instance Functor Maybe
instance Monad Maybe
instance MonadFail Maybe
instance MonadRec Maybe
instance Semigroup a => Monoid (Maybe a)
instance Ord a => Ord (Maybe a)
instance Read a => Read (Maybe a)
instance Semigroup a => Semigroup (Maybe a)
instance Show a => Show (Maybe a)
instance Traversable Maybe
```

```haskell
data Either a b = Left a | Right b

instance Applicative (Either e)
instance MonadError e (Either e)  -- in Control.Monad.Except
instance (Eq a, Eq b) => Eq (Either a b)
instance Functor (Either e)
instance Monad (Either e)
instance MonadRec (Either e)
instance (Ord a, Ord b) => Ord (Either a b)
instance (Read a, Read b) => Read (Either a b)
instance (Show a, Show b) => Show (Either a b)
```

```haskell
data Ordering = LT | EQ | GT

instance Bounded Ordering
instance Enum Ordering
instance Eq Ordering
instance Monoid Ordering
instance Ord Ordering
instance Read Ordering
instance Semigroup Ordering
instance Show Ordering
```

## Functions

```haskell
id :: a -> a
const :: a -> b -> a
flip :: (a -> b -> c) -> b -> a -> c
infixr 9 .
(.) :: (b -> c) -> (a -> b) -> a -> c
infixr 0 $
($) :: (a -> b) -> a -> b
curry :: ((a, b) -> c) -> a -> b -> c
uncurry :: (a -> b -> c) -> (a, b) -> c
undefined :: a
```

```haskell
infixr 3 &&
(&&) :: Bool -> Lazy Bool -> Bool
```

The second argument is suspended, so these short-circuit.

```haskell
infixr 2 ||
(||) :: Bool -> Lazy Bool -> Bool
not :: Bool -> Bool
otherwise :: Bool
fst :: (a, b) -> a
snd :: (a, b) -> b
maybe :: b -> (a -> b) -> Maybe a -> b
fromMaybe :: a -> Maybe a -> a
either :: (a -> c) -> (b -> c) -> Either a b -> c
```

## Equality, order, showing

```haskell
class Eq a where
  (==) :: a -> a -> Bool
  (/=) :: a -> a -> Bool
```

Methods with a default definition: `(/=)`, `(==)`.

```haskell
class Eq a => Ord a where
  compare :: a -> a -> Ordering
  (<) :: a -> a -> Bool
  (<=) :: a -> a -> Bool
  (>) :: a -> a -> Bool
  (>=) :: a -> a -> Bool
  max :: a -> a -> a
  min :: a -> a -> a
```

Methods with a default definition: `compare`, `(<)`, `(<=)`, `(>)`, `(>=)`, `max`, `min`.

```haskell
class Show a where
  show :: a -> String
  showsPrec :: Int -> a -> String
```

Methods with a default definition: `show`, `showsPrec`.

```haskell
thenCmp :: Ordering -> Lazy Ordering -> Ordering
```

Used by derived instances.

```haskell
showParenString :: Bool -> String -> String
```

## Semigroups and monoids

```haskell
class Semigroup a where
  (<>) :: a -> Lazy a -> a
```

The right operand is lazy, as for ++.

```haskell
class Semigroup a => Monoid a where
  mempty :: a
```

```haskell
infixr 5 ++
(++) :: Semigroup a => a -> Lazy a -> a
```

One after the other: two lists, two Strings, or two values of any other
Semigroup. The second is only computed when it is needed.

```haskell
mconcat :: Monoid a => [a] -> a
```

```haskell
data Sum a = Sum a

instance Eq a => Eq (Sum a)
instance Num a => Monoid (Sum a)
instance Ord a => Ord (Sum a)
instance Num a => Semigroup (Sum a)
instance Show a => Show (Sum a)
```

```haskell
data Product a = Product a

instance Eq a => Eq (Product a)
instance Num a => Monoid (Product a)
instance Ord a => Ord (Product a)
instance Num a => Semigroup (Product a)
instance Show a => Show (Product a)
```

```haskell
data All = All Bool

instance Eq All
instance Monoid All
instance Ord All
instance Semigroup All
instance Show All
```

```haskell
data Any = Any Bool

instance Eq Any
instance Monoid Any
instance Ord Any
instance Semigroup Any
instance Show Any
```

```haskell
getSum :: Sum a -> a
getProduct :: Product a -> a
getAll :: All -> Bool
getAny :: Any -> Bool
```

## Numbers

```haskell
class Num a where
  (+) :: a -> a -> a
  (-) :: a -> a -> a
  (*) :: a -> a -> a
  negate :: a -> a
  fromInteger :: Int -> a
```

A ring: no abs or signum, which only make sense with an order.

Methods with a default definition: `(-)`, `negate`.

```haskell
class (Num a, Ord a) => Integral a where
  div :: a -> a -> a
  mod :: a -> a -> a
  quot :: a -> a -> a
  rem :: a -> a -> a
  toInt :: a -> Int
  toInteger :: a -> Integer
```

Methods with a default definition: `toInteger`.

```haskell
class Num a => Fractional a where
  (/) :: a -> a -> a
  fromDouble :: Double -> a
```

```haskell
class Fractional a => Floating a where
  pi :: a
  sqrt :: a -> a
  exp :: a -> a
  log :: a -> a
  sin :: a -> a
  cos :: a -> a
  (**) :: a -> a -> a
```

```haskell
abs :: (Ord a, Num a) => a -> a
signum :: (Ord a, Num a) => a -> a
fromIntegral :: (Integral a, Num b) => a -> b
```

```haskell
divMod :: Integral a => a -> a -> (a, a)
```

The quotient and the remainder together: div and mod, and quot and rem.

```haskell
quotRem :: Integral a => a -> a -> (a, a)
```

The quotient and the remainder together: div and mod, and quot and rem.

```haskell
even :: Integral a => a -> Bool
odd :: Integral a => a -> Bool
subtract :: Num a => a -> a -> a
gcd :: Integral a => a -> a -> a
lcm :: Integral a => a -> a -> a
logBase :: Floating a => a -> a -> a
infixr 8 ^
(^) :: (Num a, Integral b) => a -> b -> a
goSqrt :: Double -> Double
goExp :: Double -> Double
goLog :: Double -> Double
goSin :: Double -> Double
goCos :: Double -> Double
goPow :: Double -> Double -> Double
goFloor :: Double -> Double
goCeil :: Double -> Double
goRound :: Double -> Double
goPi :: Double
truncate :: Double -> Int
floor :: Double -> Int
ceiling :: Double -> Int
round :: Double -> Int
```

```haskell
integerFromInt :: Int -> Integer
```

Integer, of any size, is Go's *big.Int.

```haskell
integerFromString :: String -> Integer
integerParse :: String -> Either String Integer
integerAdd :: Integer -> Integer -> Integer
integerSub :: Integer -> Integer -> Integer
integerMul :: Integer -> Integer -> Integer
integerNeg :: Integer -> Integer
integerDiv :: Integer -> Integer -> Integer
integerMod :: Integer -> Integer -> Integer
integerQuot :: Integer -> Integer -> Integer
integerRem :: Integer -> Integer -> Integer
integerCompare :: Integer -> Integer -> Int
integerShow :: Integer -> String
integerToInt :: Integer -> Int
integerToDouble :: Integer -> Double
```

## Functor, Applicative, Monad

```haskell
class Functor f where
  fmap :: (a -> b) -> f a -> f b
  (<$) :: a -> f b -> f a
```

Methods with a default definition: `(<$)`.

```haskell
infixl 4 <$>
(<$>) :: Functor f => (a -> b) -> f a -> f b
```

```haskell
class Functor f => Applicative f where
  pure :: a -> f a
  (<*>) :: f (a -> b) -> f a -> f b
  liftA2 :: (a -> b -> c) -> f a -> f b -> f c
  (*>) :: f a -> Lazy (f b) -> f b
  (<*) :: f a -> f b -> f a
```

Methods with a default definition: `(<*>)`, `liftA2`, `(*>)`, `(<*)`.

```haskell
class Applicative m => Monad m where
  (>>=) :: m a -> (a -> m b) -> m b
```

```haskell
class Monad m => MonadFail m where
  fail :: String -> m a
```

```haskell
class Applicative f => Alternative f where
  empty :: f a
  (<|>) :: f a -> Lazy (f a) -> f a
```

```haskell
return :: Monad m => a -> m a
infixl 1 >>
(>>) :: Monad m => m a -> Lazy (m b) -> m b
infixr 1 =<<
(=<<) :: Monad m => (a -> m b) -> m a -> m b
join :: Monad m => m (m a) -> m a
when :: Applicative f => Bool -> Lazy (f ()) -> f ()
unless :: Applicative f => Bool -> Lazy (f ()) -> f ()
guard :: Alternative f => Bool -> f ()
```

```haskell
class Monad m => MonadRec m where
  tailRecM :: (a -> m (Either a b)) -> a -> m b
```

In a strict language a monadic loop grows the stack unless the monad can
run it as a loop. MonadRec is that promise (as in PureScript): tailRecM
runs in constant stack. IO is trampolined, so plain recursion in IO is
already safe; for other monads, write long loops with tailRecM.

```haskell
forever :: MonadRec m => m a -> m b
```

## Foldable and Traversable

```haskell
class Foldable t where
  foldr :: (a -> Lazy b -> b) -> b -> t a -> b
  foldMap :: Monoid m => (a -> m) -> t a -> m
  foldl :: (b -> a -> b) -> b -> t a -> b
  toList :: t a -> [a]
  null :: t a -> Bool
```

foldr's accumulator is lazy, so it can stop early on infinite structures.

Methods with a default definition: `foldMap`, `toList`, `foldl`, `null`.

```haskell
class (Functor t, Foldable t) => Traversable t where
  traverse :: Applicative f => (a -> f b) -> t a -> f (t b)
```

```haskell
length :: Foldable t => t a -> Int
sum :: (Foldable t, Num a) => t a -> a
product :: (Foldable t, Num a) => t a -> a
elem :: (Foldable t, Eq a) => a -> t a -> Bool
notElem :: (Foldable t, Eq a) => a -> t a -> Bool
and :: Foldable t => t Bool -> Bool
or :: Foldable t => t Bool -> Bool
any :: Foldable t => (a -> Bool) -> t a -> Bool
all :: Foldable t => (a -> Bool) -> t a -> Bool
maximum :: (Foldable t, Ord a) => t a -> Maybe a
minimum :: (Foldable t, Ord a) => t a -> Maybe a
find :: Foldable t => (a -> Bool) -> t a -> Maybe a
concat :: Foldable t => t [a] -> [a]
concatMap :: Foldable t => (a -> [b]) -> t a -> [b]
traverse_ :: (Foldable t, Applicative f) => (a -> f b) -> t a -> f ()
for_ :: (Foldable t, Applicative f) => t a -> (a -> f b) -> f ()
sequenceA_ :: (Foldable t, Applicative f) => t (f a) -> f ()
```

```haskell
mapM_ :: (Foldable t, Monad m) => (a -> m b) -> t a -> m ()
```

The monadic versions keep the rest of the loop inside a continuation,
so it is only built as it runs: long loops stay flat in any monad whose
\>>= is (IO, and transformers over it).

```haskell
forM_ :: (Foldable t, Monad m) => t a -> (a -> m b) -> m ()
sequence_ :: (Foldable t, Monad m) => t (m a) -> m ()
sequenceA :: (Traversable t, Applicative f) => t (f a) -> f (t a)
mapM :: (Traversable t, Applicative f) => (a -> f b) -> t a -> f (t b)
forM :: (Traversable t, Applicative f) => t a -> (a -> f b) -> f (t b)
sequence :: (Traversable t, Applicative f) => t (f a) -> f (t a)
```

## Lists

```haskell
listFoldr :: (a -> Lazy b -> b) -> b -> [a] -> b
listFoldl :: (b -> a -> b) -> b -> [a] -> b
head :: [a] -> Maybe a
tail :: [a] -> Maybe [a]
```

```haskell
append :: [a] -> Lazy [a] -> [a]
```

What ++ means on lists. The second list is only demanded once the first runs out.

```haskell
map :: (a -> b) -> [a] -> [b]
filter :: (a -> Bool) -> [a] -> [a]
reverse :: [a] -> [a]
take :: Int -> [a] -> [a]
drop :: Int -> [a] -> [a]
splitAt :: Int -> [a] -> ([a], [a])
takeWhile :: (a -> Bool) -> [a] -> [a]
dropWhile :: (a -> Bool) -> [a] -> [a]
span :: (a -> Bool) -> [a] -> ([a], [a])
break :: (a -> Bool) -> [a] -> ([a], [a])
infixl 9 !!
(!!) :: [a] -> Int -> Maybe a
zip :: [a] -> [b] -> [(a, b)]
zipWith :: (a -> b -> c) -> [a] -> [b] -> [c]
unzip :: [(a, b)] -> ([a], [b])
zip3 :: [a] -> [b] -> [c] -> [(a, b, c)]
zipWith3 :: (a -> b -> c -> d) -> [a] -> [b] -> [c] -> [d]
unzip3 :: [(a, b, c)] -> ([a], [b], [c])
lookup :: Eq a => a -> [(a, b)] -> Maybe b
repeat :: a -> [a]
replicate :: Int -> a -> [a]
iterate :: (a -> a) -> a -> [a]
cycle :: [a] -> [a]
last :: [a] -> Maybe a
```

```haskell
init :: [a] -> Maybe [a]
```

Everything but the last element.

```haskell
scanl :: (b -> a -> b) -> b -> [a] -> [b]
scanl1 :: (a -> a -> a) -> [a] -> [a]
scanr :: (a -> b -> b) -> b -> [a] -> [b]
scanr1 :: (a -> a -> a) -> [a] -> [a]
until :: (a -> Bool) -> (a -> a) -> a -> a
words :: String -> [String]
lines :: String -> [String]
```

## Characters

```haskell
isSpace :: Char -> Bool
isAlpha :: Char -> Bool
isUpper :: Char -> Bool
isLower :: Char -> Bool
isDigit :: Char -> Bool
isAlphaNum :: Char -> Bool
```

## Read

```haskell
class Read a where
  readsPrec :: Int -> [Char] -> Maybe (a, [Char])
```

Values that can be read back from what show prints. readsPrec d reads
one at precedence d (11 is an argument of a constructor) from the start of
the text, and gives what is left. Unlike Haskell's read, read says Nothing
when the text is not a value of the type, instead of failing.

```haskell
read :: Read a => String -> Maybe a
```

```haskell
lexToken :: [Char] -> Maybe ([Char], [Char])
```

The next token, Haskell style, after any spaces: a name, a number, a
string or character literal, a parenthesis or bracket, or an operator.

```haskell
lexNumber :: [Char] -> ([Char], [Char])
```

digits, then maybe a fraction, then maybe an exponent

```haskell
expectToken :: String -> [Char] -> Maybe [Char]
```

The text after the token t, if t comes next.

```haskell
readParens :: (Int -> [Char] -> Maybe (a, [Char])) -> Int -> [Char] -> Maybe (a, [Char])
```

A reader that also takes its value in parentheses, at any precedence.

```haskell
readSigned :: (String -> Maybe a) -> Int -> [Char] -> Maybe (a, [Char])
```

A number with an optional sign; a negative one only where show would
leave it without parentheses.

```haskell
goAtoi :: String -> Either String Int
goParseFloat :: String -> Int -> Either String Double
goUnquote :: String -> Either String String
fromRight :: Either e a -> Maybe a
```

```haskell
readItems :: Read a => [a] -> [Char] -> Maybe ([a], [Char])
```

the rest of a list, after its first element

```haskell
readConstant :: String -> a -> [Char] -> Maybe (a, [Char])
```

a constructor's name: Just, or (:|) for an operator

```haskell
readApply :: String -> a -> Int -> [Char] -> Maybe (a, [Char])
```

The constructor's name, at a precedence where an application needs no
parentheses.

```haskell
readArg :: Read a => Maybe (a -> b, [Char]) -> Maybe (b, [Char])
```

```haskell
readRecord :: String -> a -> Int -> [Char] -> Maybe (a, [Char])
```

C {, as show prints a record.

```haskell
readField :: Read a => String -> Bool -> Maybe (a -> b, [Char]) -> Maybe (b, [Char])
```

field = value, after a comma unless it is the first.

```haskell
readClose :: Maybe (a, [Char]) -> Maybe (a, [Char])
```

## Enum and Bounded

```haskell
class Enum a where
  fromEnum :: a -> Int
  toEnum :: Int -> Maybe a
  succ :: a -> Maybe a
  pred :: a -> Maybe a
  enumFrom :: a -> [a]
  enumFromThen :: a -> a -> [a]
  enumFromTo :: a -> a -> [a]
  enumFromThenTo :: a -> a -> a -> [a]
```

Values that can be counted, and so used in ranges: [a ..], [a, b ..],
[a .. c], [a, b .. c]. Unlike Haskell's, every method is total: toEnum,
succ and pred give Nothing past the ends, so a range of a bounded type
stops at its last value. Double is not an Enum, because a range of
floating-point numbers is not exact; map over a range of Int instead.

Methods with a default definition: `succ`, `pred`, `enumFrom`, `enumFromThen`, `enumFromTo`, `enumFromThenTo`.

```haskell
class Bounded a where
  minBound :: a
  maxBound :: a
```

```haskell
justs :: [Maybe a] -> [a]
```

the values up to the first Nothing

```haskell
intsTo :: Int -> Int -> Int -> [Int]
```

n, n + step, ... while not past the limit, without overflowing

```haskell
intsFrom :: Int -> Int -> [Int]
integersFrom :: Integer -> Integer -> [Integer]
integersTo :: Integer -> Integer -> Integer -> [Integer]
unwords :: [String] -> String
unlines :: [String] -> String
```

## IO

```haskell
print :: Show a => a -> IO ()
```

```haskell
getContents :: IO String
```

All of standard input.

```haskell
readFile :: String -> IO (Either String String)
```

Reading or writing a file can fail, so the error comes back as a value.

```haskell
writeFile :: String -> String -> IO (Either String ())
appendFile :: String -> String -> IO (Either String ())
```

```haskell
interact :: (String -> String) -> IO ()
```

The whole of standard input, given to f, and what f gives printed. The
input is read in full first: Hago is strict.

## Instances for the types the language has

Also for every tuple up to fifteen elements, as for pairs.

```haskell
instance Alternative []
instance Monoid w => Applicative ((,) w)
instance Applicative ((->) r)
instance Applicative IO
instance Applicative []
instance Bounded ()
instance (Bounded t1, Bounded t2) => Bounded (t1, t2)
instance Bounded Bool
instance Bounded Char
instance Bounded Int
instance Enum ()
instance Enum Bool
instance Enum Char
instance Enum Int
instance Enum Integer
instance Eq ()
instance (Eq t1, Eq t2) => Eq (t1, t2)
instance Eq Bool
instance Eq Char
instance Eq Double
instance Eq Int
instance Eq Integer
instance Eq String
instance Eq a => Eq [a]
instance Floating Double
instance Foldable []
instance Fractional Double
instance Functor ((,) w)
instance Functor ((->) r)
instance Functor IO
instance Functor []
instance Integral Int
instance Integral Integer
instance Monoid w => Monad ((,) w)
instance Monad ((->) r)
instance Monad IO
instance Monad []
instance MonadFail IO
instance MonadFail []
instance MonadRec IO
instance Monoid ()
instance (Monoid a, Monoid b) => Monoid (a, b)
instance Monoid String
instance Monoid [a]
instance Num Double
instance Num Int
instance Num Integer
instance Ord ()
instance (Ord t1, Ord t2) => Ord (t1, t2)
instance Ord Bool
instance Ord Char
instance Ord Double
instance Ord Int
instance Ord Integer
instance Ord String
instance Ord a => Ord [a]
instance Read ()
instance (Read t1, Read t2) => Read (t1, t2)
instance Read Bool
instance Read Char
instance Read Double
instance Read Int
instance Read Integer
instance Read String
instance Read a => Read [a]
instance Semigroup ()
instance (Semigroup a, Semigroup b) => Semigroup (a, b)
instance Semigroup String
instance Semigroup [a]
instance Show ()
instance (Show t1, Show t2) => Show (t1, t2)
instance Show Bool
instance Show Char
instance Show Double
instance Show Int
instance Show Integer
instance Show String
instance Show a => Show [a]
instance Traversable []
```
