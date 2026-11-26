# Data.Word

Unsigned integers of fixed sizes, as Haskell's Data.Word: Go's uint8,
uint16, uint32, uint64 and uint. Arithmetic wraps around, and
fromIntegral keeps the low bits: fromIntegral (300 :: Int) :: Word8 is 44.
They are Num, Integral, Enum, Bounded, Bits and FiniteBits.

Its source is [`lib/Data/Word.hgo`](../../lib/Data/Word.hgo).

```haskell
foreign import go type "uint8" Word8

instance Bounded Word8
instance Bits Word8
instance FiniteBits Word8
instance Enum Word8
instance Eq Word8
instance Integral Word8
instance Num Word8
instance Ord Word8
instance Show Word8
```

```haskell
foreign import go type "uint16" Word16

instance Bounded Word16
instance Bits Word16
instance FiniteBits Word16
instance Enum Word16
instance Eq Word16
instance Integral Word16
instance Num Word16
instance Ord Word16
instance Show Word16
```

```haskell
foreign import go type "uint32" Word32

instance Bounded Word32
instance Bits Word32
instance FiniteBits Word32
instance Enum Word32
instance Eq Word32
instance Integral Word32
instance Num Word32
instance Ord Word32
instance Show Word32
```

```haskell
foreign import go type "uint64" Word64

instance Bounded Word64
instance Bits Word64
instance FiniteBits Word64
instance Enum Word64
instance Eq Word64
instance Integral Word64
instance Num Word64
instance Ord Word64
instance Show Word64
```

```haskell
foreign import go type "uint" Word

instance Bounded Word
instance Bits Word
instance FiniteBits Word
instance Enum Word
instance Eq Word
instance Integral Word
instance Num Word
instance Ord Word
instance Show Word
```
