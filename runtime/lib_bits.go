// Bits and integers of fixed sizes, for Data.Bits, Data.Word and Data.Int.
// A program gets this part of the runtime only if it uses one of its
// functions; see runtime.go.
package main

import (
	rt_big "math/big"
	rt_bits "math/bits"
	rt_unsafe "unsafe"
)

// --- runtime ---

// Go's integers: Int is int, Word8 is uint8, Int64 is int64.
type rt_integral interface {
	~int | ~int8 | ~int16 | ~int32 | ~int64 | ~uint | ~uint8 | ~uint16 | ~uint32 | ~uint64
}

func rt_bitAnd[T rt_integral](a, b T) T { return a & b }
func rt_bitOr[T rt_integral](a, b T) T  { return a | b }
func rt_bitXor[T rt_integral](a, b T) T { return a ^ b }
func rt_bitNot[T rt_integral](a T) T    { return ^a }
func rt_bitSize[T rt_integral](a T) int { return int(rt_unsafe.Sizeof(a)) * 8 }
func rt_bitTest[T rt_integral](a T, i int) bool {
	return i >= 0 && i < rt_bitSize(a) && (a>>uint(i))&1 == 1
}

// A shift by a negative count, or by the size or more, gives what shifting
// one place at a time would: no bits, or for a signed right shift the sign.
func rt_shiftL[T rt_integral](a T, n int) T {
	if n < 0 {
		return rt_shiftR(a, -n)
	}
	return a << uint(n)
}

func rt_shiftR[T rt_integral](a T, n int) T {
	if n < 0 {
		return rt_shiftL(a, -n)
	}
	return a >> uint(n)
}

// The bits set, of the type's own size: popCount (-1 :: Int8) is 8.
func rt_popCount[T rt_integral](a T) int {
	size := rt_bitSize(a)
	return rt_bits.OnesCount64(uint64(a) & (^uint64(0) >> uint(64-size)))
}

func rt_leadingZeros[T rt_integral](a T) int {
	size := rt_bitSize(a)
	return rt_bits.LeadingZeros64(uint64(a)&(^uint64(0)>>uint(64-size))) - (64 - size)
}

func rt_trailingZeros[T rt_integral](a T) int {
	size := rt_bitSize(a)
	if t := rt_bits.TrailingZeros64(uint64(a)); t < size {
		return t
	}
	return size
}

// Division as Haskell's: quot and rem round towards zero, div and mod
// towards negative infinity; by zero is an error, as for Int.
func rt_quotOf[T rt_integral](a, b T) T {
	if b == 0 {
		panic("divide by zero")
	}
	return a / b
}

func rt_remOf[T rt_integral](a, b T) T {
	if b == 0 {
		panic("divide by zero")
	}
	return a % b
}

func rt_divOf[T rt_integral](a, b T) T {
	q, r := rt_quotOf(a, b), a%b
	if r != 0 && (r < 0) != (b < 0) {
		q--
	}
	return q
}

func rt_modOf[T rt_integral](a, b T) T {
	r := rt_remOf(a, b)
	if r != 0 && (r < 0) != (b < 0) {
		r += b
	}
	return r
}

// Conversions, which keep the low bits, as Go's and Haskell's fromIntegral.
func rt_fromInt[T rt_integral](n int) T         { return T(n) }
func rt_toInt[T rt_integral](a T) int           { return int(a) }
func rt_wordToInteger(a uint64) *rt_big.Int     { return new(rt_big.Int).SetUint64(a) }
func rt_wordToUint64[T rt_integral](a T) uint64 { return uint64(a) }
