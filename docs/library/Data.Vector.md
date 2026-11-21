# Data.Vector

Vectors: sequences of a fixed length, each element reached in constant
time. A Vector a is a Go slice, []T, that Hago code never changes, so a
Go function that takes or gives a slice takes or gives a Vector. Import
it qualified: import qualified Data.Vector as Vector.

A vector is the right shape for data that is built once and then read,
by position or from end to end. Adding one element copies the vector, so
a sequence built one element at a time is better as a list first.

Its source is [`lib/Data/Vector.hgo`](../../lib/Data/Vector.hgo).

```haskell
foreign import go type "[]" Vector a

instance Eq a => Eq (Vector a)
instance Foldable Vector
instance Functor Vector
instance Monoid (Vector a)
instance Ord a => Ord (Vector a)
instance Semigroup (Vector a)
instance Show a => Show (Vector a)
```

```haskell
fromList :: [a] -> Vector a
toList :: Vector a -> [a]
length :: Vector a -> Int
null :: Vector a -> Bool
```

```haskell
infixl 9 !?
(!?) :: Vector a -> Int -> Maybe a
```

The element at a position, counting from 0, if there is one.

```haskell
generate :: Int -> (Int -> a) -> Vector a
```

A vector of n elements, each computed from its position.

```haskell
replicate :: Int -> a -> Vector a
empty :: Vector a
singleton :: a -> Vector a
map :: (a -> b) -> Vector a -> Vector b
```

```haskell
imap :: (Int -> a -> b) -> Vector a -> Vector b
```

map, with the position of each element.

```haskell
filter :: (a -> Bool) -> Vector a -> Vector a
foldl :: (b -> a -> b) -> b -> Vector a -> b
sum :: Num a => Vector a -> a
product :: Num a => Vector a -> a
maximum :: Ord a => Vector a -> Maybe a
minimum :: Ord a => Vector a -> Maybe a
any :: (a -> Bool) -> Vector a -> Bool
all :: (a -> Bool) -> Vector a -> Bool
elem :: Eq a => a -> Vector a -> Bool
append :: Vector a -> Vector a -> Vector a
concat :: [Vector a] -> Vector a
```

```haskell
slice :: Int -> Int -> Vector a -> Vector a
```

The n elements from a position on, or as many as there are. It shares
the elements with the vector it comes from, without copying them.

```haskell
take :: Int -> Vector a -> Vector a
drop :: Int -> Vector a -> Vector a
reverse :: Vector a -> Vector a
sort :: Ord a => Vector a -> Vector a
sortBy :: (a -> a -> Ordering) -> Vector a -> Vector a
sortOn :: Ord b => (a -> b) -> Vector a -> Vector a
zipWith :: (a -> b -> c) -> Vector a -> Vector b -> Vector c
zip :: Vector a -> Vector b -> Vector (a, b)
toIter :: Vector a -> Iter a
fromIter :: Iter a -> Vector a
```
