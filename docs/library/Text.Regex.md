# Text.Regex

Regular expressions, Go's regexp: the syntax of RE2, as Go documents it.
Matching takes time proportional to the text, whatever the expression,
because RE2 has no back-references. Import it qualified:
import qualified Text.Regex as Regex.

Its source is [`lib/Text/Regex.hgo`](../../lib/Text/Regex.hgo).

```haskell
foreign import go type "*regexp.Regexp" Regex
```

```haskell
compile :: String -> Either String Regex
```

An expression, or why it is not one.

```haskell
matches :: Regex -> String -> Bool
```

Whether the expression matches somewhere in the text.

```haskell
find :: Regex -> String -> Maybe String
```

The first match.

```haskell
findAll :: Regex -> String -> Vector String
```

Every match, from left to right, without overlapping.

```haskell
groups :: Regex -> String -> Maybe (Vector String)
```

The first match and its groups: the whole match first, then what each
pair of parentheses matched.

```haskell
allGroups :: Regex -> String -> Vector (Vector String)
```

The groups of every match.

```haskell
replaceAll :: Regex -> String -> String -> String
```

Replaces every match; $1 in the replacement is the first group.

```haskell
replaceAllWith :: Regex -> String -> (String -> String) -> String
```

Replaces every match with what a function makes of it.

```haskell
split :: Regex -> String -> Vector String
```

The pieces of the text between the matches.
