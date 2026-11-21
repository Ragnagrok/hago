# Control.Monad.Except

Errors over any monad, and the MonadError class, as in mtl.

Its source is [`lib/Control/Monad/Except.hgo`](../../lib/Control/Monad/Except.hgo).

```haskell
newtype ExceptT e m a = ExceptT (m (Either e a))

instance Monad m => Applicative (ExceptT e m)
instance Monad m => MonadError e (ExceptT e m)
instance MonadReader r m => MonadReader r (ExceptT e m)  -- in Control.Monad.Reader
instance MonadState s m => MonadState s (ExceptT e m)
instance MonadIO m => MonadIO (ExceptT e m)
instance MonadTrans (ExceptT e)
instance Functor m => Functor (ExceptT e m)
instance Monad m => Monad (ExceptT e m)
instance MonadRec m => MonadRec (ExceptT e m)
```

```haskell
runExceptT :: ExceptT e m a -> m (Either e a)
```

```haskell
type Except e = ExceptT e Identity
```

```haskell
runExcept :: ExceptT e Identity a -> Either e a
```

```haskell
class Monad m => MonadError e m | m -> e where
  throwError :: e -> m a
  catchError :: m a -> (e -> m a) -> m a
```

```haskell
liftEither :: MonadError e m => Either e a -> m a
```

## Re-exported

- From [Control.Monad.Trans](Control.Monad.Trans.md): `MonadIO`, `MonadTrans`.
