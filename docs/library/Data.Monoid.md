# Data.Monoid

Monoids beyond the Prelude's Sum, Product, Any and All, which this
module also exports: the first and the last value that is there, the
smallest and the largest.

Its source is [`lib/Data/Monoid.hgo`](../../lib/Data/Monoid.hgo).

```haskell
newtype First a = First (Maybe a)

instance Eq a => Eq (First a)
instance Monoid (First a)
instance Ord a => Ord (First a)
instance Semigroup (First a)
instance Show a => Show (First a)
```

The first Just.

```haskell
getFirst :: First a -> Maybe a
```

```haskell
newtype Last a = Last (Maybe a)

instance Eq a => Eq (Last a)
instance Monoid (Last a)
instance Ord a => Ord (Last a)
instance Semigroup (Last a)
instance Show a => Show (Last a)
```

The last Just.

```haskell
getLast :: Last a -> Maybe a
```

```haskell
newtype Min a = Min a

instance Eq a => Eq (Min a)
instance Ord a => Ord (Min a)
instance Ord a => Semigroup (Min a)
instance Show a => Show (Min a)
```

The smaller and the larger; with no empty value, these are only
semigroups (Maybe (Min a) is a monoid).

```haskell
getMin :: Min a -> a
```

```haskell
newtype Max a = Max a

instance Eq a => Eq (Max a)
instance Ord a => Ord (Max a)
instance Ord a => Semigroup (Max a)
instance Show a => Show (Max a)
```

```haskell
getMax :: Max a -> a
```

## Re-exported

- From [Prelude](Prelude.md): `getAll`, `getAny`, `getProduct`, `getSum`.
