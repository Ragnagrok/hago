# Control.Monad.State

State over any monad, and the MonadState class, as in mtl. State s is
StateT s Identity, and Identity is trampolined, so a long loop in State
runs in constant stack, as one in StateT s IO does.

Its source is [`lib/Control/Monad/State.hgo`](../../lib/Control/Monad/State.hgo).

```haskell
newtype StateT s m a = StateT (s -> m (a, s))

instance Monad m => Applicative (StateT s m)
instance MonadError e m => MonadError e (StateT s m)  -- in Control.Monad.Except
instance MonadReader r m => MonadReader r (StateT s m)  -- in Control.Monad.Reader
instance Monad m => MonadState s (StateT s m)
instance MonadIO m => MonadIO (StateT s m)
instance MonadTrans (StateT s)
instance MonadWriter w m => MonadWriter w (StateT s m)  -- in Control.Monad.Writer
instance Functor m => Functor (StateT s m)
instance Monad m => Monad (StateT s m)
instance MonadRec m => MonadRec (StateT s m)
```

```haskell
runStateT :: StateT s m a -> s -> m (a, s)
evalStateT :: Monad m => StateT s m a -> s -> m a
execStateT :: Monad m => StateT s m a -> s -> m s
```

```haskell
type State s = StateT s Identity
```

```haskell
runState :: StateT s Identity a -> s -> (a, s)
evalState :: StateT s Identity a -> s -> a
execState :: StateT s Identity a -> s -> s
```

```haskell
class Monad m => MonadState s m | m -> s where
  get :: m s
  put :: s -> m ()
```

```haskell
modify :: MonadState s m => (s -> s) -> m ()
gets :: MonadState s m => (s -> a) -> m a
```

## Re-exported

- From [Control.Monad.Trans](Control.Monad.Trans.md): `MonadIO`, `MonadTrans`.
- From [Data.Functor.Identity](Data.Functor.Identity.md): `runIdentity`.
