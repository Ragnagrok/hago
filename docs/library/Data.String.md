# Data.String

Functions on String, which is Go's string: taking the first character off
slices it without copying, so a String can be read from the front as a
list would, without making one. Most names are also the Prelude's names
for lists, so this module is meant to be imported qualified.

Its source is [`lib/Data/String.hgo`](../../lib/Data/String.hgo).

```haskell
length :: String -> Int
```

The number of characters, not of bytes.

```haskell
concat :: [String] -> String
```

Joins the strings in one pass.

```haskell
uncons :: String -> Maybe (Char, String)
```

The first character and the rest, in constant time.

```haskell
null :: String -> Bool
elem :: Char -> String -> Bool
isPrefixOf :: String -> String -> Bool
stripPrefix :: String -> String -> Maybe String
intercalate :: String -> [String] -> String
replicate :: Int -> String -> String
```
