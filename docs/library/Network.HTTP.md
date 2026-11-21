# Network.HTTP

Asking web servers for pages, with Go's net/http: get and post, with the
whole answer read. An error is a failure to reach the server; an answer
with any status, 404 included, is a Response.

Its source is [`lib/Network/HTTP.hgo`](../../lib/Network/HTTP.hgo).

```haskell
data Response = Response { status :: Int, body :: String }

instance Eq Response
instance Show Response
```

```haskell
get :: String -> IO (Either String Response)
```

```haskell
post :: String -> String -> String -> IO (Either String Response)
```

post url contentType body
