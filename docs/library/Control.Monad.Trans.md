# Control.Monad.Trans

Lifting through monad transformers.

Its source is [`lib/Control/Monad/Trans.hgo`](../../lib/Control/Monad/Trans.hgo).

```haskell
class MonadTrans t where
  lift :: Monad m => m a -> t m a
```

```haskell
class Monad m => MonadIO m where
  liftIO :: IO a -> m a
```

## Instances for the types the language has

```haskell
instance MonadIO IO
```
