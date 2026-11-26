# Data.Foldable

Foldable and its functions, as Haskell's Data.Foldable: all of them are
the Prelude's, so this module only gives them under that name, with
foldl' (which is foldl: Hago computes as it goes). maximum and minimum
give a Maybe.

Its source is [`lib/Data/Foldable.hgo`](../../lib/Data/Foldable.hgo).

```haskell
foldl' :: Foldable t => (b -> a -> b) -> b -> t a -> b
```

## Re-exported

- From [Prelude](Prelude.md): `all`, `and`, `any`, `concat`, `concatMap`, `elem`, `find`, `forM_`, `for_`, `length`, `mapM_`, `maximum`, `minimum`, `notElem`, `or`, `product`, `sequenceA_`, `sequence_`, `sum`, `traverse_`, `Foldable`.
