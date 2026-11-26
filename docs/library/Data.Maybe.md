# Data.Maybe

Functions on Maybe, as Haskell's Data.Maybe. There is no fromJust: a
Nothing would fail at run time; maybe or fromMaybe say what to do then.

Its source is [`lib/Data/Maybe.hgo`](../../lib/Data/Maybe.hgo).

```haskell
isJust :: Maybe a -> Bool
isNothing :: Maybe a -> Bool
```

```haskell
catMaybes :: [Maybe a] -> [a]
```

The values of the Justs.

```haskell
mapMaybe :: (a -> Maybe b) -> [a] -> [b]
```

The values f gives a Just of.

```haskell
listToMaybe :: [a] -> Maybe a
```

The first element, if there is one.

```haskell
maybeToList :: Maybe a -> [a]
```

## Re-exported

- From [Prelude](Prelude.md): `fromMaybe`, `maybe`.
