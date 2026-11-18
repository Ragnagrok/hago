// Hashes and encodings, for Crypto.Hash and Data.Encoding. A program gets
// this part of the runtime only if it uses one of its functions; see
// runtime.go.
package main

import (
	rt_sha1 "crypto/sha1"
	rt_sha256 "crypto/sha256"
	rt_sha512 "crypto/sha512"
	rt_base64 "encoding/base64"
	rt_hex "encoding/hex"
)

// --- runtime ---

// The hash of a string's bytes, in hexadecimal.
func rt_sha1Hex(s string) string {
	h := rt_sha1.Sum([]byte(s))
	return rt_hex.EncodeToString(h[:])
}

func rt_sha256Hex(s string) string {
	h := rt_sha256.Sum256([]byte(s))
	return rt_hex.EncodeToString(h[:])
}

func rt_sha512Hex(s string) string {
	h := rt_sha512.Sum512([]byte(s))
	return rt_hex.EncodeToString(h[:])
}

func rt_base64Encode(s string) string { return rt_base64.StdEncoding.EncodeToString([]byte(s)) }

func rt_base64Decode(s string) (string, error) {
	b, err := rt_base64.StdEncoding.DecodeString(s)
	return string(b), err
}

func rt_hexEncode(s string) string { return rt_hex.EncodeToString([]byte(s)) }

func rt_hexDecode(s string) (string, error) {
	b, err := rt_hex.DecodeString(s)
	return string(b), err
}
