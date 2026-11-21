# Control.Parallel

Pure parallelism: computing the elements of a list on all the processors
at once. The functions are pure, so the result is the same as without
parallelism, only sooner: there is nothing to wait for or to coordinate.

Its source is [`lib/Control/Parallel.hgo`](../../lib/Control/Parallel.hgo).

```haskell
parMap :: (a -> b) -> [a] -> [b]
```

map, with the elements computed in parallel. Worth it when computing each
one takes long compared to starting a goroutine (about a microsecond).
