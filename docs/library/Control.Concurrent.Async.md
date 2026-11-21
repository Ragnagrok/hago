# Control.Concurrent.Async

Running actions at the same time and waiting for their results, without
handling threads: async starts one, wait gives its result.

Unlike Haskell's async, a thread cannot be stopped from outside (see
Control.Concurrent), so race does not cancel the action that loses: it
runs to the end, and its result is dropped.

Its source is [`lib/Control/Concurrent/Async.hgo`](../../lib/Control/Concurrent/Async.hgo).

```haskell
newtype Async a
```

An action running on its own thread, and the box its result goes to.

```haskell
async :: IO a -> IO (Async a)
```

```haskell
wait :: Async a -> IO a
```

Waits for the result.

```haskell
poll :: Async a -> IO (Maybe a)
```

The result, if the action has finished.

```haskell
concurrently :: IO a -> IO b -> IO (a, b)
```

Both actions at the same time; both results.

```haskell
race :: IO a -> IO b -> IO (Either a b)
```

Both actions at the same time; the result of the first to finish.

```haskell
mapConcurrently :: (a -> IO b) -> [a] -> IO [b]
```

The action on every element, all at the same time; the results in order.

```haskell
mapConcurrently_ :: (a -> IO b) -> [a] -> IO ()
forConcurrently :: [a] -> (a -> IO b) -> IO [b]
forConcurrently_ :: [a] -> (a -> IO b) -> IO ()
```
