# Data.IntMap

Maps from Int keys, as containers' Data.IntMap: a Data.Map whose keys
are Ints, with all its functions. Import it qualified: import qualified
Data.IntMap as IntMap.

Its source is [`lib/Data/IntMap.hgo`](../../lib/Data/IntMap.hgo).

```haskell
type IntMap v = Map Int v
```

```haskell
type Key = Int
```

## Re-exported

- From [Data.Map](Data.Map.md): `(!?)`, `adjust`, `alter`, `assocs`, `delete`, `deleteMax`, `deleteMin`, `difference`, `elems`, `empty`, `filter`, `filterWithKey`, `findWithDefault`, `foldlWithKey`, `foldr`, `foldrWithKey`, `fromList`, `fromListWith`, `insert`, `insertWith`, `intersectionWith`, `keys`, `lookup`, `lookupMax`, `lookupMin`, `map`, `mapWithKey`, `member`, `notMember`, `null`, `partition`, `singleton`, `size`, `split`, `toAscList`, `toDescList`, `toList`, `union`, `unionWith`, `unions`, `unionsWith`, `valid`, `Map`.
