# Data.String.Builder

Building a long String from many pieces. Joining two Strings copies both,
so a text built by adding pieces one by one takes time that grows with
the square of its length. A Builder keeps the pieces, and toString joins
them all at once, in time that grows with the length.

Its source is [`lib/Data/String/Builder.hgo`](../../lib/Data/String/Builder.hgo).

```haskell
newtype Builder

instance Monoid Builder
instance Semigroup Builder
```

The pieces, as a function that puts them in front of the ones after.

```haskell
fromString :: String -> Builder
fromChar :: Char -> Builder
fromShow :: Show a => a -> Builder
toString :: Builder -> String
```

```haskell
intercalate :: Builder -> [Builder] -> Builder
```

The builders, with another between each two.
