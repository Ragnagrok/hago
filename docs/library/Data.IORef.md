# Data.IORef

Mutable references in IO. An IORef holds one value, which any thread can
read and replace: it is an atomic pointer to the value, so a thread never
sees half of what another is writing, and modifyIORef' and
atomicModifyIORef' never lose a change.

Hago is strict, so a value is computed before it is written:
modifyIORef' and modifyIORef are the same function.

Its source is [`lib/Data/IORef.hgo`](../../lib/Data/IORef.hgo).

```haskell
foreign import go type "*rt_IORef" IORef a
```

```haskell
newIORef :: a -> IO (IORef a)
readIORef :: IORef a -> IO a
writeIORef :: IORef a -> a -> IO ()
```

```haskell
modifyIORef' :: IORef a -> (a -> a) -> IO ()
```

Applies the function to the value, atomically: if another thread writes
in between, the function runs again on the new value.

```haskell
modifyIORef :: IORef a -> (a -> a) -> IO ()
```

```haskell
atomicModifyIORef' :: IORef a -> (a -> (a, b)) -> IO b
```

Replaces the value with the first of the pair the function gives, and
gives the second, atomically.

```haskell
atomicWriteIORef :: IORef a -> a -> IO ()
```

writeIORef is already atomic.
