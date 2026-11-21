# Control.Monad.ST.Unsafe

What the library's mutable structures are built on: ST, and the class of
the monads their operations run in. Nothing here is unsafe to use, but
unsafeIOToST is: it runs any IO action as part of an ST computation, and
runST would then give a pure value that is not one. Import
Control.Monad.ST instead.

Its source is [`lib/Control/Monad/ST/Unsafe.hgo`](../../lib/Control/Monad/ST/Unsafe.hgo).

```haskell
newtype ST s a

instance Applicative (ST s)
instance PrimMonad s (ST s)
instance Functor (ST s)
instance Monad (ST s)
instance MonadRec (ST s)
```

An action on structures whose state is s. At run time it is an IO action:
the newtype costs nothing, and its loops are trampolined as IO's are.

```haskell
data RealWorld
```

The state of the structures made in IO.

```haskell
unsafeIOToST :: IO a -> ST s a
unsafeSTToIO :: ST s a -> IO a
```

```haskell
class Monad m => PrimMonad s m | m -> s where
  -- An IO action on structures of state s, in m.
  unsafePrimIO :: IO a -> m a
  -- Whether other threads may see a structure made in m, which then needs
  -- a lock (in a program that has threads).
  primShared :: m Bool
```

The monads mutable structures live in: IO, whose state is RealWorld, and
ST s. The state says which structures an action may use: an
MVector s a only in a monad of state s.

## Instances for the types the language has

```haskell
instance PrimMonad RealWorld IO
```
