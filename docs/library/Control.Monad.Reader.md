# Control.Monad.Reader

An environment over any monad, and the MonadReader class, as in mtl.

Its source is [`lib/Control/Monad/Reader.hgo`](../../lib/Control/Monad/Reader.hgo).

```haskell
newtype ReaderT r m a = ReaderT (r -> m a)

instance Monad m => Applicative (ReaderT r m)
instance MonadError e m => MonadError e (ReaderT r m)
instance Monad m => MonadReader r (ReaderT r m)
instance MonadState s m => MonadState s (ReaderT r m)
instance MonadIO m => MonadIO (ReaderT r m)
instance MonadTrans (ReaderT r)
instance Functor m => Functor (ReaderT r m)
instance Monad m => Monad (ReaderT r m)
instance MonadRec m => MonadRec (ReaderT r m)
```

```haskell
runReaderT :: ReaderT r m a -> r -> m a
```

```haskell
type Reader r = ReaderT r Identity
```

```haskell
runReader :: ReaderT r Identity a -> r -> a
```

```haskell
class Monad m => MonadReader r m | m -> r where
  ask :: m r
  local :: (r -> r) -> m a -> m a
```

```haskell
asks :: MonadReader r m => (r -> a) -> m a
```

## Re-exported

- From [Control.Monad.Trans](Control.Monad.Trans.md): `MonadIO`, `MonadTrans`.
