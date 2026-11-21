# Data.Ratio

Fractions, exact: 1 % 3 + 1 % 6 is 1 % 2, never 0.49999. A Rational is a
numerator and a denominator of any size (Go's *big.Rat), always in lowest
terms. Arithmetic on it is exact, and slower than on Double.

Its source is [`lib/Data/Ratio.hgo`](../../lib/Data/Ratio.hgo).

```haskell
foreign import go type "*math/big.Rat" Rational

instance Eq Rational
instance Fractional Rational
instance Num Rational
instance Ord Rational
instance Show Rational
```

```haskell
infixl 7 %
(%) :: Integer -> Integer -> Rational
numerator :: Rational -> Integer
denominator :: Rational -> Integer
```

```haskell
fromRational :: Rational -> Double
```

The Double nearest to a Rational.

```haskell
toRational :: Double -> Rational
```

The exact value of a Double: toRational 0.1 is not 1 % 10.
