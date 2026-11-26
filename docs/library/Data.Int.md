# Data.Int

Signed integers of fixed sizes, as Haskell's Data.Int: Go's int8, int16,
int32 and int64 (Int itself is Go's int, of 64 bits). Arithmetic wraps
around, and fromIntegral keeps the low bits. They are Num, Integral,
Enum, Bounded, Bits and FiniteBits.

Its source is [`lib/Data/Int.hgo`](../../lib/Data/Int.hgo).

```haskell
foreign import go type "int8" Int8

instance Bounded Int8
instance Bits Int8
instance FiniteBits Int8
instance Enum Int8
instance Eq Int8
instance Integral Int8
instance Num Int8
instance Ord Int8
instance Show Int8
```

```haskell
foreign import go type "int16" Int16

instance Bounded Int16
instance Bits Int16
instance FiniteBits Int16
instance Enum Int16
instance Eq Int16
instance Integral Int16
instance Num Int16
instance Ord Int16
instance Show Int16
```

```haskell
foreign import go type "int32" Int32

instance Bounded Int32
instance Bits Int32
instance FiniteBits Int32
instance Enum Int32
instance Eq Int32
instance Integral Int32
instance Num Int32
instance Ord Int32
instance Show Int32
```

```haskell
foreign import go type "int64" Int64

instance Bounded Int64
instance Bits Int64
instance FiniteBits Int64
instance Enum Int64
instance Eq Int64
instance Integral Int64
instance Num Int64
instance Ord Int64
instance Show Int64
```
