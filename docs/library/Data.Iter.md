# Data.Iter

Iterators: Go's iter.Seq. An Iter a gives its values one by one, as they
are asked for, and can go on forever: from 1 is every number from 1 on.
A pipeline of map, filter and takeWhile over an Iter computes each value
once and allocates nothing per value, so it is much faster than the same
pipeline over a list, and runs in constant memory. Import it qualified:
import qualified Data.Iter as Iter.

An Iter is a computation, not a structure: consuming one twice computes
it twice, and it cannot be taken apart with patterns. For that, toList
makes it a list. Functions that consume a whole Iter (length, sum, foldl)
never end on an infinite one.

Its source is [`lib/Data/Iter.hgo`](../../lib/Data/Iter.hgo).

```haskell
foreign import go type "iter.Seq" Iter a

instance Functor Iter
```

```haskell
from :: Int -> Iter Int
```

Every number from n on.

```haskell
range :: Int -> Int -> Iter Int
```

The numbers from a to b, both included.

```haskell
iterate :: (a -> a) -> a -> Iter a
```

x, f x, f (f x)...

```haskell
repeat :: a -> Iter a
fromList :: [a] -> Iter a
toList :: Iter a -> [a]
```

```haskell
lines :: String -> Iter String
```

The lines, words and characters of a text, without copying it.

```haskell
words :: String -> Iter String
chars :: String -> Iter Char
map :: (a -> b) -> Iter a -> Iter b
filter :: (a -> Bool) -> Iter a -> Iter a
takeWhile :: (a -> Bool) -> Iter a -> Iter a
dropWhile :: (a -> Bool) -> Iter a -> Iter a
take :: Int -> Iter a -> Iter a
drop :: Int -> Iter a -> Iter a
concatMap :: (a -> Iter b) -> Iter a -> Iter b
append :: Iter a -> Iter a -> Iter a
zipWith :: (a -> b -> c) -> Iter a -> Iter b -> Iter c
zip :: Iter a -> Iter b -> Iter (a, b)
foldl :: (b -> a -> b) -> b -> Iter a -> b
length :: Iter a -> Int
sum :: Num a => Iter a -> a
product :: Num a => Iter a -> a
maximum :: Ord a => Iter a -> Maybe a
minimum :: Ord a => Iter a -> Maybe a
```

```haskell
find :: (a -> Bool) -> Iter a -> Maybe a
```

The first value that satisfies p; what comes after it is not computed.

```haskell
head :: Iter a -> Maybe a
any :: (a -> Bool) -> Iter a -> Bool
all :: (a -> Bool) -> Iter a -> Bool
elem :: Eq a => a -> Iter a -> Bool
null :: Iter a -> Bool
mapM_ :: (a -> IO ()) -> Iter a -> IO ()
forM_ :: Iter a -> (a -> IO ()) -> IO ()
```
