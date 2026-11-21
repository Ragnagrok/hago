# System.Process

Running other programs.

Its source is [`lib/System/Process.hgo`](../../lib/System/Process.hgo).

```haskell
readProcess :: String -> [String] -> String -> IO (Either String String)
```

Runs a program with its arguments and what to give it on its standard
input, and gives what it printed. The program is found on the PATH. A
program that cannot be started or that fails is an error, with what it
printed on its standard error.
