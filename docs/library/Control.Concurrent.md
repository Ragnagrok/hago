# Control.Concurrent

Threads, and MVars to pass values between them. A thread is a goroutine:
starting one is cheap, and thousands can run at once.

Differences from Haskell's Control.Concurrent:
- forkIO gives no ThreadId: Go cannot stop a goroutine from outside, so
  there is no killThread. A thread that should stop early has to be told,
  through an MVar or a channel.
- A failure in any thread (error, a division by zero) ends the program,
  as it does in the main one.
- When the main thread finishes, the program ends, whatever the others
  are doing.

Its source is [`lib/Control/Concurrent.hgo`](../../lib/Control/Concurrent.hgo).

```haskell
forkIO :: IO () -> IO ()
```

```haskell
threadDelay :: Int -> IO ()
```

Waits at least this many microseconds.

```haskell
yield :: IO ()
```

Lets other threads run.

```haskell
getNumCapabilities :: IO Int
```

How many threads can run at the same time: the processors Go uses.

```haskell
foreign import go type "*rt_MVar" MVar a
```

A box that is either empty or holds one value. takeMVar waits until it is
full and empties it; putMVar waits until it is empty and fills it.

```haskell
newMVar :: a -> IO (MVar a)
newEmptyMVar :: IO (MVar a)
takeMVar :: MVar a -> IO a
putMVar :: MVar a -> a -> IO ()
```

```haskell
readMVar :: MVar a -> IO a
```

The value, leaving it in the box: waits until there is one.

```haskell
tryTakeMVar :: MVar a -> IO (Maybe a)
```

Like takeMVar and readMVar, but Nothing at once if the box is empty.

```haskell
tryReadMVar :: MVar a -> IO (Maybe a)
```

```haskell
tryPutMVar :: MVar a -> a -> IO Bool
```

Fills the box if it is empty, and says whether it did.

```haskell
modifyMVar_ :: MVar a -> (a -> IO a) -> IO ()
```

Takes the value, puts back what the action makes of it. Other threads
that use the box only this way wait for each other, so the change is
never lost.

```haskell
modifyMVar :: MVar a -> (a -> IO (a, b)) -> IO b
```

The same, with a result besides the new value.

```haskell
withMVar :: MVar a -> (a -> IO b) -> IO b
```

Uses the value while no other thread can take it.
