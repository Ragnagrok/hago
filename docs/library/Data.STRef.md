# Data.STRef

Mutable references in ST: see Control.Monad.ST. An STRef s a can only
be used by the computation that made it, which runs on one thread, so it
is a plain cell.

Its source is [`lib/Data/STRef.hgo`](../../lib/Data/STRef.hgo).

```haskell
foreign import go type "*rt_STRef" STRef s a
```

```haskell
newSTRef :: a -> ST s (STRef s a)
readSTRef :: STRef s a -> ST s a
writeSTRef :: STRef s a -> a -> ST s ()
```

```haskell
modifySTRef' :: STRef s a -> (a -> a) -> ST s ()
```

Hago is strict, so modifySTRef and modifySTRef' are the same function.

```haskell
modifySTRef :: STRef s a -> (a -> a) -> ST s ()
```
