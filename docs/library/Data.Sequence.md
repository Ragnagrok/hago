# Data.Sequence

Finite sequences, as containers' Data.Sequence: adding at either end,
reaching, changing, inserting or deleting at a position, splitting and
joining all take time logarithmic in the length. containers keeps a
finger tree, a type nested in itself, which Hago's specialisation cannot
make copies of; this one is a balanced tree, as Data.Map's, ordered by
position, each node keeping its size, so adding at an end takes log n
instead of constant time. There is no index, which would fail past the
end: lookup and !? give a Maybe. Many names are the Prelude's, so this
module is meant to be imported qualified: import qualified Data.Sequence
as Seq.

Its source is [`lib/Data/Sequence.hgo`](../../lib/Data/Sequence.hgo).

```haskell
data Seq a

instance Eq a => Eq (Seq a)
instance Foldable Seq
instance Functor Seq
instance Monoid (Seq a)
instance Ord a => Ord (Seq a)
instance Semigroup (Seq a)
instance Show a => Show (Seq a)
```

A tree of the elements in order: a node holds its size, an element, and
the elements before it and after it.

```haskell
data ViewL a = EmptyL | a :< (Seq a)
```

The first element and the rest, or nothing.

```haskell
data ViewR a = EmptyR | (Seq a) :> a
```

The rest and the last element, or nothing.

## Building

```haskell
empty :: Seq a
singleton :: a -> Seq a
```

```haskell
infixr 5 <|
(<|) :: a -> Seq a -> Seq a
```

At the front.

```haskell
infixl 5 |>
(|>) :: Seq a -> a -> Seq a
```

At the back.

```haskell
infixr 5 ><
(><) :: Seq a -> Seq a -> Seq a
```

One sequence followed by another.

```haskell
fromList :: [a] -> Seq a
```

A balanced tree of the list's elements, in time linear in its length.

```haskell
replicate :: Int -> a -> Seq a
```

n copies of x.

## Looking

```haskell
length :: Seq a -> Int
null :: Seq a -> Bool
```

```haskell
lookup :: Int -> Seq a -> Maybe a
```

The element at a position, from 0, if there is one.

```haskell
infixl 9 !?
(!?) :: Seq a -> Int -> Maybe a
```

```haskell
viewl :: Seq a -> ViewL a
```

The first element and the rest.

```haskell
viewr :: Seq a -> ViewR a
```

The rest and the last element.

## Changing

```haskell
update :: Int -> a -> Seq a -> Seq a
```

The element at a position replaced; the sequence as it was if there is none.

```haskell
adjust :: (a -> a) -> Int -> Seq a -> Seq a
```

```haskell
insertAt :: Int -> a -> Seq a -> Seq a
```

x put before the element at a position: at the front for 0 or less, at
the back for the length or more.

```haskell
deleteAt :: Int -> Seq a -> Seq a
```

The sequence without the element at a position, if there is one.

```haskell
splitAt :: Int -> Seq a -> (Seq a, Seq a)
```

The first n elements, and the rest.

```haskell
take :: Int -> Seq a -> Seq a
drop :: Int -> Seq a -> Seq a
reverse :: Seq a -> Seq a
filter :: (a -> Bool) -> Seq a -> Seq a
zip :: Seq a -> Seq b -> Seq (a, b)
zipWith :: (a -> b -> c) -> Seq a -> Seq b -> Seq c
```

```haskell
sort :: Ord a => Seq a -> Seq a
```

In order, stable: equal elements keep their order.

```haskell
sortBy :: (a -> a -> Ordering) -> Seq a -> Seq a
```

## With positions

```haskell
mapWithIndex :: (Int -> a -> b) -> Seq a -> Seq b
foldrWithIndex :: (Int -> a -> b -> b) -> b -> Seq a -> b
foldlWithIndex :: (b -> Int -> a -> b) -> b -> Seq a -> b
```

## Instances

```haskell
valid :: Seq a -> Bool
```

Whether the tree is as it should be: the size kept in each node right,
and every node balanced, as Data.Map.valid checks.
