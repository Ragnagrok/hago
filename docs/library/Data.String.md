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
```

```haskell
stripSuffix :: String -> String -> Maybe String
```

s without the suffix, if it ends with it. When the suffix is what is
left of s after reading some of it, this takes constant time: comparing
a String with itself is immediate.

```haskell
intercalate :: String -> [String] -> String
replicate :: Int -> String -> String
```

```haskell
span :: (Char -> Bool) -> String -> (String, String)
```

The longest run of characters at the front that satisfy f, and the rest,
in one pass and without copying: both share the text.

```haskell
break :: (Char -> Bool) -> String -> (String, String)
takeWhile :: (Char -> Bool) -> String -> String
dropWhile :: (Char -> Bool) -> String -> String
```
