# Data.Vector.Mutable

Mutable vectors: a fixed number of elements, each read and written in
constant time. MVector s a is used in a monad of state s: IOVector a in
IO, and STVector s a in ST s (see Control.Monad.ST), with the same
functions. Import it qualified: import qualified Data.Vector.Mutable as MV.

An index outside the vector ends the program with
"error: index out of range", as in Go: indices come from the algorithm,
and one out of bounds is a bug in it. readMaybe is for an index that
comes from outside.

A vector made in IO can be shared by threads: in a program that has
them, it has a lock, and each operation takes it. One made in ST has
none, since only its computation can see it.

Its source is [`lib/Data/Vector/Mutable.hgo`](../../lib/Data/Vector/Mutable.hgo).

```haskell
foreign import go type "*rt_MVector" MVector s a
```

```haskell
type IOVector = MVector RealWorld
```

```haskell
type STVector s = MVector s
```

```haskell
replicate :: PrimMonad s m => Int -> a -> m (MVector s a)
```

A vector of n elements, all the same.

```haskell
generate :: PrimMonad s m => Int -> (Int -> a) -> m (MVector s a)
```

A vector of n elements, each computed from its position.

```haskell
length :: MVector s a -> Int
```

The length never changes, so it is not an action.

```haskell
read :: PrimMonad s m => MVector s a -> Int -> m a
```

```haskell
readMaybe :: PrimMonad s m => MVector s a -> Int -> m (Maybe a)
```

The element at a position, or Nothing if the vector has none there.

```haskell
write :: PrimMonad s m => MVector s a -> Int -> a -> m ()
```

```haskell
modify :: PrimMonad s m => MVector s a -> (a -> a) -> Int -> m ()
```

Replaces the element at a position with what the function makes of it.

```haskell
swap :: PrimMonad s m => MVector s a -> Int -> Int -> m ()
```

```haskell
set :: PrimMonad s m => MVector s a -> a -> m ()
```

Writes the value in every element.

```haskell
freeze :: PrimMonad s m => MVector s a -> m (Vector a)
```

An immutable copy, which later writes do not change.

```haskell
thaw :: PrimMonad s m => Vector a -> m (MVector s a)
```

A mutable copy of an immutable vector.

```haskell
fromList :: PrimMonad s m => [a] -> m (MVector s a)
toList :: PrimMonad s m => MVector s a -> m [a]
```
