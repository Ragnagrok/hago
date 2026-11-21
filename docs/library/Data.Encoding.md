# Data.Encoding

Writing any bytes with a few safe characters, and back: base64 (RFC 4648,
with padding) and hexadecimal.

Its source is [`lib/Data/Encoding.hgo`](../../lib/Data/Encoding.hgo).

```haskell
base64Encode :: String -> String
base64Decode :: String -> Either String String
hexEncode :: String -> String
hexDecode :: String -> Either String String
```
