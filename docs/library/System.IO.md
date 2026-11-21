# System.IO

The standard handles, for writing to standard error and testing for the
end of standard input. Files are read and written whole, with readFile,
writeFile and appendFile in the Prelude.

Its source is [`lib/System/IO.hgo`](../../lib/System/IO.hgo).

```haskell
data Handle

instance Eq Handle
instance Show Handle
```

```haskell
data BufferMode = NoBuffering | LineBuffering | BlockBuffering (Maybe Int)

instance Eq BufferMode
instance Show BufferMode
```

Output is not buffered, so there is never anything to flush.

```haskell
stdin :: Handle
stdout :: Handle
stderr :: Handle
isEOF :: IO Bool
hPutStr :: Handle -> String -> IO ()
hPutStrLn :: Handle -> String -> IO ()
hPrint :: Show a => Handle -> a -> IO ()
```

```haskell
hGetLine :: Handle -> IO String
```

A line of standard input; "" at its end, which hIsEOF tells apart.

```haskell
hGetContents :: Handle -> IO String
hIsEOF :: Handle -> IO Bool
hFlush :: Handle -> IO ()
hClose :: Handle -> IO ()
hSetBuffering :: Handle -> BufferMode -> IO ()
```
