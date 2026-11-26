# Data.Bits

Operations on the bits of integers, as Haskell's Data.Bits: Int here,
and the integers of Data.Word and Data.Int. Bit 0 is the lowest.

Its source is [`lib/Data/Bits.hgo`](../../lib/Data/Bits.hgo).

```haskell
class (Eq a, Num a) => Bits a where
  (.&.) :: a -> a -> a
  (.|.) :: a -> a -> a
  xor :: a -> a -> a
  complement :: a -> a
  -- by a number of places: a negative one shifts the other way
  shiftL :: a -> Int -> a
  -- by a number of places: a negative one shifts the other way
  shiftR :: a -> Int -> a
  -- by a number of places: a negative one shifts the other way
  shift :: a -> Int -> a
  testBit :: a -> Int -> Bool
  setBit :: a -> Int -> a
  clearBit :: a -> Int -> a
  complementBit :: a -> Int -> a
  -- how many bits are set
  popCount :: a -> Int
  zeroBits :: a
  -- the number with only bit i set
  bit :: Int -> a
```

Methods with a default definition: `shift`, `setBit`, `clearBit`, `complementBit`, `zeroBits`, `bit`.

```haskell
class Bits a => FiniteBits a where
  finiteBitSize :: a -> Int
  countLeadingZeros :: a -> Int
  countTrailingZeros :: a -> Int
```

```haskell
infixl 6 .^.
(.^.) :: Bits a => a -> a -> a
```

xor, shiftL and shiftR as operators, as in base 4.17.

```haskell
infixl 8 .<<.
(.<<.) :: Bits a => a -> Int -> a
infixl 8 .>>.
(.>>.) :: Bits a => a -> Int -> a
```

## Instances for the types the language has

```haskell
instance Bits Int
instance FiniteBits Int
```
