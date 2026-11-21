# Control.Applicative

More applicative functors and functions on them. Applicative and
Alternative themselves are in the Prelude.

Its source is [`lib/Control/Applicative.hgo`](../../lib/Control/Applicative.hgo).

```haskell
newtype ZipList a = ZipList [a]

instance Applicative ZipList
instance Eq a => Eq (ZipList a)
instance Functor ZipList
instance Show a => Show (ZipList a)
```

A list whose <*> pairs functions and values by position, as zipWith does,
instead of trying every function on every value.

```haskell
getZipList :: ZipList a -> [a]
liftA3 :: Applicative f => (a -> b -> c -> d) -> f a -> f b -> f c -> f d
```

```haskell
optional :: Alternative f => f a -> f (Maybe a)
```

Just the result, or Nothing where p fails without it.
