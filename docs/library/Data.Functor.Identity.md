# Data.Functor.Identity

The identity monad, trampolined: it runs on the same machinery as IO, so
a long chain of binds runs in constant stack, and so does every
transformer over it (State s is StateT s Identity). Its constructor is not
exported, so no IO action can be run as a pure value.

Its source is [`lib/Data/Functor/Identity.hgo`](../../lib/Data/Functor/Identity.hgo).

```haskell
newtype Identity a

instance Applicative Identity
instance Functor Identity
instance Monad Identity
instance MonadRec Identity
```

```haskell
runIdentity :: Identity a -> a
```
