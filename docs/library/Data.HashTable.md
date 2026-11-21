# Data.HashTable

Mutable hash tables, on Go's maps: insert, lookup and delete in constant
time on average. HashTable s k v is used in a monad of state s:
IOHashTable k v in IO, and HashTable s k v in ST s (see Control.Monad.ST),
with the same functions. Import it qualified:
import qualified Data.HashTable as HashTable.

Keys are the types Go compares by value, the instances of Key: Int,
Char, String, Bool, (), and tuples of keys. Other types are kept as
pointers, which Go would compare by identity (two equal lists would be
different keys), or have no equality that suits a table (Double's NaN is
not equal to itself). Only this module gives instances of Key; for other
keys, use Data.Map.

toList gives the pairs in Go's order, which changes from run to run.

A table made in IO can be shared by threads: in a program that has them,
it has a lock, and each operation takes it, so each is atomic (alter and
insertWith too); a sequence of them is not. One made in ST has none.

Its source is [`lib/Data/HashTable.hgo`](../../lib/Data/HashTable.hgo).

```haskell
foreign import go type "*rt_HashTable" HashTable s k v
```

```haskell
type IOHashTable = HashTable RealWorld
```

```haskell
class Key k
```

The types Go compares by value.

```haskell
new :: (PrimMonad s m, Key k) => m (HashTable s k v)
fromList :: (PrimMonad s m, Key k) => [(k, v)] -> m (HashTable s k v)
```

```haskell
insert :: (PrimMonad s m, Key k) => HashTable s k v -> k -> v -> m ()
```

Replaces the value the key had, if it had one.

```haskell
insertWith :: (PrimMonad s m, Key k) => (v -> v -> v) -> HashTable s k v -> k -> v -> m ()
```

insertWith f t k new keeps f new old if the key had a value, and new if
it had none.

```haskell
alter :: (PrimMonad s m, Key k) => (Maybe v -> Maybe v) -> HashTable s k v -> k -> m ()
```

What the function makes of the key's value (Nothing if it has none): the
new value, or Nothing to delete it.

```haskell
lookup :: (PrimMonad s m, Key k) => HashTable s k v -> k -> m (Maybe v)
member :: (PrimMonad s m, Key k) => HashTable s k v -> k -> m Bool
delete :: (PrimMonad s m, Key k) => HashTable s k v -> k -> m ()
size :: (PrimMonad s m, Key k) => HashTable s k v -> m Int
```

```haskell
toList :: (PrimMonad s m, Key k) => HashTable s k v -> m [(k, v)]
```

The pairs, in an order that changes from run to run.

## Instances for the types the language has

Also for every tuple up to fifteen elements, as for pairs.

```haskell
instance Key ()
instance (Key a, Key b) => Key (a, b)
instance Key Bool
instance Key Char
instance Key Int
instance Key String
```
