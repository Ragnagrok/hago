# Control.Monad.Writer

A computation that also writes something on the side, such as a log:
tell adds to it with <>, so what is written can be any Monoid.

Its source is [`lib/Control/Monad/Writer.hgo`](../../lib/Control/Monad/Writer.hgo).

```haskell
newtype WriterT w m a = WriterT (m (a, w))

instance (Monoid w, Monad m) => Applicative (WriterT w m)
instance (Monoid w, MonadState s m) => MonadState s (WriterT w m)
instance (Monoid w, MonadIO m) => MonadIO (WriterT w m)
instance Monoid w => MonadTrans (WriterT w)
instance (Monoid w, Monad m) => MonadWriter w (WriterT w m)
instance Functor m => Functor (WriterT w m)
instance (Monoid w, Monad m) => Monad (WriterT w m)
```

```haskell
runWriterT :: WriterT w m a -> m (a, w)
execWriterT :: Monad m => WriterT w m a -> m w
```

```haskell
type Writer w = WriterT w Identity
```

```haskell
runWriter :: WriterT w Identity a -> (a, w)
execWriter :: WriterT w Identity a -> w
```

```haskell
class (Monoid w, Monad m) => MonadWriter w m | m -> w where
  -- Adds w to what has been written.
  tell :: w -> m ()
```

## Re-exported

- From [Control.Monad.Trans](Control.Monad.Trans.md): `MonadIO`, `MonadTrans`.
