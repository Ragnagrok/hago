# Control.Concurrent.Channel

Go's channels. A channel carries values of one type from the threads that
send them to the threads that receive them, in order. It has a buffer of
a fixed size: a send waits while the buffer is full, and with a size of 0
each send waits for a receive. Closing a channel says nothing more will
be sent: receivers get what is left, and then Nothing.

select waits on several channels at once, as Go's select statement does.

Its source is [`lib/Control/Concurrent/Channel.hgo`](../../lib/Control/Concurrent/Channel.hgo).

```haskell
foreign import go type "rt_Channel" Channel a
```

```haskell
newChannel :: Int -> IO (Channel a)
```

```haskell
send :: Channel a -> a -> IO ()
```

Fails if the channel is closed.

```haskell
close :: Channel a -> IO ()
```

```haskell
receive :: Channel a -> IO (Maybe a)
```

The next value, or Nothing once the channel is closed and empty.

```haskell
receiveAll :: Channel a -> IO [a]
```

Every value until the channel is closed.

```haskell
foreign import go type "rt_Case" Case a
```

One of the things a select waits for, and what to do if it happens.

```haskell
onReceive :: Channel b -> (Maybe b -> IO a) -> Case a
```

A value received, or Nothing if the channel is closed.

```haskell
onSend :: Channel b -> b -> IO a -> Case a
```

The value sent.

```haskell
after :: Int -> IO a -> Case a
```

This many microseconds after the select starts, if nothing else happened.

```haskell
select :: [Case a] -> IO a
```

Waits until one of the cases can happen, makes it happen, and runs what
goes with it. If several can at once, one is chosen at random.
