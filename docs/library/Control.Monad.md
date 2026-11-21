# Control.Monad

Functions on monads beyond the Prelude's (which has when, unless, join,
guard, forever, mapM_, forM_ and sequence, and which this module also
exports, so that importing it works as it does in Haskell).

Its source is [`lib/Control/Monad.hgo`](../../lib/Control/Monad.hgo).

```haskell
foldM :: Monad m => (b -> a -> m b) -> b -> [a] -> m b
```

A fold whose step is an action: foldM step z [x1, x2] is
step z x1 >>= \a -> step a x2.

```haskell
foldM_ :: Monad m => (b -> a -> m b) -> b -> [a] -> m ()
```

```haskell
replicateM :: Applicative m => Int -> m a -> m [a]
```

n times, keeping the results.

```haskell
replicateM_ :: Applicative m => Int -> m a -> m ()
```

```haskell
filterM :: Applicative m => (a -> m Bool) -> [a] -> m [a]
```

The elements for which the action gives True.

```haskell
zipWithM :: Applicative m => (a -> b -> m c) -> [a] -> [b] -> m [c]
zipWithM_ :: Applicative m => (a -> b -> m c) -> [a] -> [b] -> m ()
```

```haskell
infixr 1 >=>
(>=>) :: Monad m => (a -> m b) -> (b -> m c) -> a -> m c
```

Composition of functions that give monadic results.

```haskell
infixr 1 <=<
(<=<) :: Monad m => (b -> m c) -> (a -> m b) -> a -> m c
liftM :: Monad m => (a -> b) -> m a -> m b
liftM2 :: Monad m => (a -> b -> c) -> m a -> m b -> m c
ap :: Monad m => m (a -> b) -> m a -> m b
void :: Functor f => f a -> f ()
mfilter :: (Monad m, Alternative m) => (a -> Bool) -> m a -> m a
```

## Re-exported

- From [Prelude](Prelude.md): `forM`, `forM_`, `forever`, `guard`, `join`, `mapM`, `mapM_`, `sequence`, `sequence_`, `unless`, `when`.
