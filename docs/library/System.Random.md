# System.Random

Pseudo-random numbers. A generator is a value: randomR gives a number and
the next generator, and the same generator always gives the same number,
which keeps it pure. In IO, newStdGen and randomRIO draw from a generator
seeded by the clock, or by the variable HAGO_RANDOM_SEED, so that a run
can be repeated. The generator is SplitMix64 (Steele, Lea and Flood,
"Fast splittable pseudorandom number generators", 2014).

Its source is [`lib/System/Random.hgo`](../../lib/System/Random.hgo).

```haskell
newtype StdGen

instance Show StdGen
```

```haskell
mkStdGen :: Int -> StdGen
```

A generator from a seed; the same seed gives the same numbers.

```haskell
next :: StdGen -> (Int, StdGen)
```

A number with 64 random bits, and the next generator.

```haskell
split :: StdGen -> (StdGen, StdGen)
```

Two generators that give unrelated numbers.

```haskell
class Random a where
  -- A value from lo to hi, both included.
  randomR :: (a, a) -> StdGen -> (a, StdGen)
  random :: StdGen -> (a, StdGen)
```

```haskell
randoms :: Random a => StdGen -> [a]
```

Infinitely many, from one generator.

```haskell
randomRs :: Random a => (a, a) -> StdGen -> [a]
```

```haskell
newStdGen :: IO StdGen
```

A new generator, from the program's.

```haskell
getStdGen :: IO StdGen
randomIO :: Random a => IO a
randomRIO :: Random a => (a, a) -> IO a
```

## Instances for the types the language has

```haskell
instance Random Bool
instance Random Char
instance Random Double
instance Random Int
instance Random Integer
```
