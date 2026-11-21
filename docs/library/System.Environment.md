# System.Environment

The command line.

Its source is [`lib/System/Environment.hgo`](../../lib/System/Environment.hgo).

```haskell
getArgs :: IO [String]
```

The arguments, without the program's name.

```haskell
getProgName :: IO String
```

The name the program was run with, without its directory.
