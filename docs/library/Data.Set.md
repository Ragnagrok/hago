# Data.Set

Finite sets, kept as a balanced binary search tree, as Data.Map is:
membership, inserting and deleting take time logarithmic in the size.
Many names are the Prelude's, so this module is meant to be imported
qualified: import qualified Data.Set as Set.

Its source is [`lib/Data/Set.hgo`](../../lib/Data/Set.hgo).

```haskell
data Set a

instance Eq a => Eq (Set a)
instance Foldable Set
instance Ord a => Monoid (Set a)
instance Ord a => Ord (Set a)
instance Ord a => Semigroup (Set a)
instance Show a => Show (Set a)
```

```haskell
empty :: Set a
singleton :: a -> Set a
fromList :: Ord a => [a] -> Set a
insert :: Ord a => a -> Set a -> Set a
delete :: Ord a => a -> Set a -> Set a
member :: Ord a => a -> Set a -> Bool
notMember :: Ord a => a -> Set a -> Bool
size :: Set a -> Int
null :: Set a -> Bool
```

```haskell
toList :: Set a -> [a]
```

The elements, in increasing order.

```haskell
toAscList :: Set a -> [a]
toDescList :: Set a -> [a]
elems :: Set a -> [a]
foldr :: (a -> b -> b) -> b -> Set a -> b
map :: Ord b => (a -> b) -> Set a -> Set b
filter :: (a -> Bool) -> Set a -> Set a
partition :: (a -> Bool) -> Set a -> (Set a, Set a)
union :: Ord a => Set a -> Set a -> Set a
unions :: Ord a => [Set a] -> Set a
intersection :: Ord a => Set a -> Set a -> Set a
difference :: Ord a => Set a -> Set a -> Set a
isSubsetOf :: Ord a => Set a -> Set a -> Bool
lookupMin :: Set a -> Maybe a
lookupMax :: Set a -> Maybe a
deleteMin :: Set a -> Set a
deleteMax :: Set a -> Set a
```
