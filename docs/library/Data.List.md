# Data.List

More functions on lists than the Prelude has: sorting, grouping, sets
kept as lists, searching, and the ways of cutting a list up. Those that
can have no answer (maximumBy on an empty list, elemIndex of something
missing) return a Maybe.

Its source is [`lib/Data/List.hgo`](../../lib/Data/List.hgo).

## Sorting

```haskell
sort :: Ord a => [a] -> [a]
```

```haskell
sortBy :: (a -> a -> Ordering) -> [a] -> [a]
```

A merge sort: stable, so elements that compare equal keep their order.

```haskell
sortOn :: Ord b => (a -> b) -> [a] -> [a]
```

Sorted by what f gives, which is computed once per element.

```haskell
insert :: Ord a => a -> [a] -> [a]
```

Into a sorted list, before the first element that is larger.

```haskell
insertBy :: (a -> a -> Ordering) -> a -> [a] -> [a]
```

## Grouping

```haskell
nub :: Eq a => [a] -> [a]
```

The first of each element, in order. It compares every pair, so it is
slow on long lists; Data.Set does better when the order does not matter.

```haskell
nubBy :: (a -> a -> Bool) -> [a] -> [a]
```

```haskell
group :: Eq a => [a] -> [[a]]
```

Runs of equal elements next to each other: group [1, 1, 2, 1] is
[[1, 1], [2], [1]].

```haskell
groupBy :: (a -> a -> Bool) -> [a] -> [[a]]
```

```haskell
partition :: (a -> Bool) -> [a] -> ([a], [a])
```

The elements that satisfy p, and the others.

## Joining and splitting

```haskell
intercalate :: Monoid a => a -> [a] -> a
```

The pieces with sep between them. It joins any Monoid, Strings among
them: intercalate ", " ["a", "b"] is "a, b".

```haskell
intersperse :: a -> [a] -> [a]
```

```haskell
transpose :: [[a]] -> [[a]]
```

Rows into columns, with short rows leaving gaps.

```haskell
tails :: [a] -> [[a]]
inits :: [a] -> [[a]]
```

```haskell
subsequences :: [a] -> [[a]]
```

Every choice of elements, in order.

```haskell
permutations :: [a] -> [[a]]
```

Every order of the elements.

```haskell
dropWhileEnd :: (a -> Bool) -> [a] -> [a]
```

## Tests

```haskell
isPrefixOf :: Eq a => [a] -> [a] -> Bool
isSuffixOf :: Eq a => [a] -> [a] -> Bool
isInfixOf :: Eq a => [a] -> [a] -> Bool
```

```haskell
isSubsequenceOf :: Eq a => [a] -> [a] -> Bool
```

Whether the elements of the first list appear in the second, in order.

```haskell
stripPrefix :: Eq a => [a] -> [a] -> Maybe [a]
```

The rest of the list after the prefix, if it starts with it.

## Lists as sets

```haskell
delete :: Eq a => a -> [a] -> [a]
```

Without the first occurrence of x.

```haskell
deleteBy :: (a -> a -> Bool) -> a -> [a] -> [a]
```

```haskell
infix 5 \\
(\\) :: Eq a => [a] -> [a] -> [a]
```

The first list without one occurrence of each element of the second.

```haskell
union :: Eq a => [a] -> [a] -> [a]
intersect :: Eq a => [a] -> [a] -> [a]
```

## Searching

```haskell
elemIndex :: Eq a => a -> [a] -> Maybe Int
elemIndices :: Eq a => a -> [a] -> [Int]
findIndex :: (a -> Bool) -> [a] -> Maybe Int
findIndices :: (a -> Bool) -> [a] -> [Int]
maximumBy :: (a -> a -> Ordering) -> [a] -> Maybe a
minimumBy :: (a -> a -> Ordering) -> [a] -> Maybe a
```

## Building

```haskell
unfoldr :: (b -> Maybe (a, b)) -> b -> [a]
```

A list from a seed: f gives the next element and the next seed, or
Nothing to stop.

```haskell
uncons :: [a] -> Maybe (a, [a])
singleton :: a -> [a]
zip4 :: [a] -> [b] -> [c] -> [d] -> [(a, b, c, d)]
zipWith4 :: (a -> b -> c -> d -> e) -> [a] -> [b] -> [c] -> [d] -> [e]
genericLength :: Num n => [a] -> n
```

## Re-exported

- From [Prelude](Prelude.md): `concatMap`, `find`, `lookup`.
