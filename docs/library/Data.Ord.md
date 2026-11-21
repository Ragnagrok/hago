# Data.Ord

Orderings: comparing by a part of a value, and an order turned around.

Its source is [`lib/Data/Ord.hgo`](../../lib/Data/Ord.hgo).

```haskell
comparing :: Ord b => (a -> b) -> a -> a -> Ordering
```

compare, by what a function gives: sortBy (comparing snd).

```haskell
newtype Down a = Down a

instance Eq a => Eq (Down a)
instance Ord a => Ord (Down a)
instance Show a => Show (Down a)
```

The same values in the opposite order: sortOn Down sorts from largest.

```haskell
clamp :: Ord a => (a, a) -> a -> a
```

The value, moved into the range from low to high.
