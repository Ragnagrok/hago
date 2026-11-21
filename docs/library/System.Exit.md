# System.Exit

Ending the program with a status: 0 for success, anything else for a
failure, which the shell sees in $?.

Its source is [`lib/System/Exit.hgo`](../../lib/System/Exit.hgo).

```haskell
data ExitCode = ExitSuccess | ExitFailure Int

instance Eq ExitCode
instance Show ExitCode
```

```haskell
exitWith :: ExitCode -> IO ()
exitSuccess :: IO ()
exitFailure :: IO ()
```
