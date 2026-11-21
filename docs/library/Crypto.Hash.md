# Crypto.Hash

Hashes of a String's bytes, in hexadecimal: SHA-1 (only for checking data
against what other programs give; it is broken for security), SHA-256
and SHA-512.

Its source is [`lib/Crypto/Hash.hgo`](../../lib/Crypto/Hash.hgo).

```haskell
sha1 :: String -> String
sha256 :: String -> String
sha512 :: String -> String
```
