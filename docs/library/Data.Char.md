# Data.Char

Characters: what kind each is, and changing case. A Char is a Unicode
code point (Go's rune), and the tests are Unicode's.

Its source is [`lib/Data/Char.hgo`](../../lib/Data/Char.hgo).

```haskell
toUpper :: Char -> Char
toLower :: Char -> Char
toTitle :: Char -> Char
isPunctuation :: Char -> Bool
isSymbol :: Char -> Bool
isControl :: Char -> Bool
isPrint :: Char -> Bool
isMark :: Char -> Bool
isNumber :: Char -> Bool
```

```haskell
ord :: Char -> Int
```

The code point of a character, and the character of a code point; they
are also always in scope, as the compiler's own.

```haskell
chr :: Int -> Char
isLetter :: Char -> Bool
isAscii :: Char -> Bool
isOctDigit :: Char -> Bool
isHexDigit :: Char -> Bool
```

```haskell
digitToInt :: Char -> Maybe Int
```

The value of a decimal or hexadecimal digit, if the character is one.

```haskell
intToDigit :: Int -> Maybe Char
```

The digit for a value from 0 to 15.

## Re-exported

- From [Prelude](Prelude.md): `isAlpha`, `isAlphaNum`, `isDigit`, `isLower`, `isSpace`, `isUpper`.
