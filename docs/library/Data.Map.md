# Data.Map

Finite maps from keys to values, kept as a balanced binary search tree,
as in Haskell's containers: a tree whose subtrees' sizes never differ by
more than a factor of three (Adams, "Efficient sets: a balancing act",
1993). Looking up, inserting and deleting take time logarithmic in the
size. Keys need an order, and values are computed when they are put in,
as everything in Hago is. Many names are the Prelude's, so this module is
meant to be imported qualified: import qualified Data.Map as Map.

A map built by a fold (foldl (\m x -> Map.insert ...) m0 xs, fromList,
fromListWith) or by a loop that passes it to itself (go (Map.insert k v
m) rest) is built in place: the nodes the fold or the loop made are
changed instead of copied, since nothing else can see them. The map it
starts from, and every map made before, stay as they were.

Its source is [`lib/Data/Map.hgo`](../../lib/Data/Map.hgo).

```haskell
data Map k v

instance (Eq k, Eq v) => Eq (Map k v)
instance Foldable (Map k)
instance Functor (Map k)
instance Ord k => Monoid (Map k v)
instance (Ord k, Ord v) => Ord (Map k v)
instance Ord k => Semigroup (Map k v)
instance (Show k, Show v) => Show (Map k v)
```

## Building

```haskell
empty :: Map k v
singleton :: k -> v -> Map k v
```

```haskell
fromList :: Ord k => [(k, v)] -> Map k v
```

From pairs; of two pairs with the same key, the last one wins.

```haskell
fromListWith :: Ord k => (v -> v -> v) -> [(k, v)] -> Map k v
```

From pairs, combining the values of a key with f: f new old.

## Inserting and deleting

```haskell
insert :: Ord k => k -> v -> Map k v -> Map k v
```

```haskell
insertWith :: Ord k => (v -> v -> v) -> k -> v -> Map k v -> Map k v
```

If the key is there, its value becomes f new old.

```haskell
delete :: Ord k => k -> Map k v -> Map k v
```

```haskell
adjust :: Ord k => (v -> v) -> k -> Map k v -> Map k v
```

The value at the key changed with f, if the key is there.

```haskell
alter :: Ord k => (Maybe v -> Maybe v) -> k -> Map k v -> Map k v
```

f is given the value at the key, if there is one, and says what the key
has afterwards: Nothing deletes it.

## Looking up

```haskell
lookup :: Ord k => k -> Map k v -> Maybe v
```

```haskell
infixl 9 !?
(!?) :: Ord k => Map k v -> k -> Maybe v
```

lookup, with the map first: m !? k. There is no (!), which would fail
on a missing key.

```haskell
findWithDefault :: Ord k => v -> k -> Map k v -> v
member :: Ord k => k -> Map k v -> Bool
notMember :: Ord k => k -> Map k v -> Bool
size :: Map k v -> Int
null :: Map k v -> Bool
lookupMin :: Map k v -> Maybe (k, v)
lookupMax :: Map k v -> Maybe (k, v)
deleteMin :: Map k v -> Map k v
deleteMax :: Map k v -> Map k v
```

## Lists

```haskell
toList :: Map k v -> [(k, v)]
```

The pairs, by increasing key.

```haskell
toAscList :: Map k v -> [(k, v)]
toDescList :: Map k v -> [(k, v)]
assocs :: Map k v -> [(k, v)]
keys :: Map k v -> [k]
elems :: Map k v -> [v]
```

## Changing and combining

```haskell
map :: (a -> b) -> Map k a -> Map k b
mapWithKey :: (k -> a -> b) -> Map k a -> Map k b
filter :: (v -> Bool) -> Map k v -> Map k v
filterWithKey :: (k -> v -> Bool) -> Map k v -> Map k v
partition :: (v -> Bool) -> Map k v -> (Map k v, Map k v)
```

```haskell
split :: Ord k => k -> Map k v -> (Map k v, Map k v)
```

The keys smaller than k, and those larger.

```haskell
foldr :: (a -> b -> b) -> b -> Map k a -> b
foldrWithKey :: (k -> v -> b -> b) -> b -> Map k v -> b
foldlWithKey :: (b -> k -> v -> b) -> b -> Map k v -> b
```

```haskell
union :: Ord k => Map k v -> Map k v -> Map k v
```

Of a key in both, the value of the first map.

```haskell
unionWith :: Ord k => (v -> v -> v) -> Map k v -> Map k v -> Map k v
unions :: Ord k => [Map k v] -> Map k v
unionsWith :: Ord k => (v -> v -> v) -> [Map k v] -> Map k v
```

```haskell
intersectionWith :: Ord k => (a -> b -> c) -> Map k a -> Map k b -> Map k c
```

The keys in both, with their values combined.

```haskell
difference :: Ord k => Map k a -> Map k b -> Map k a
```

The first map without the keys of the second.

## Balancing

```haskell
valid :: Ord k => Map k v -> Bool
```

Whether the tree is as it should be: its keys in order, the size kept in
each node right, and every node balanced, as containers' valid checks.
