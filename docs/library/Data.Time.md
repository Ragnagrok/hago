# Data.Time

Points in time, Go's time.Time: the current time, the seconds between two,
and dates written and read. A Time knows its time zone; utc and local
give the same moment in UTC and in the computer's zone.

Its source is [`lib/Data/Time.hgo`](../../lib/Data/Time.hgo).

```haskell
foreign import go type "time.Time" Time

instance Eq Time
instance Ord Time
instance Show Time
```

```haskell
getCurrentTime :: IO Time
```

```haskell
diffSeconds :: Time -> Time -> Double
```

The seconds from the second time to the first: diffSeconds later earlier.

```haskell
addSeconds :: Double -> Time -> Time
```

```haskell
fromUnix :: Int -> Time
```

Seconds since 1970-01-01 00:00 UTC, and back.

```haskell
toUnix :: Time -> Int
utc :: Time -> Time
local :: Time -> Time
```

```haskell
format :: String -> Time -> String
```

Go's way of writing a layout: the reference time, Mon Jan 2 15:04:05 MST
2006, written the way the result should look. "2006-01-02" is a date,
"15:04" an hour and minutes, "Jan 2, 2006" a date in words.

```haskell
parse :: String -> String -> Either String Time
```

```haskell
iso8601 :: Time -> String
```

2026-11-18T07:00:13Z, the form RFC 3339 and most programs use.

```haskell
year :: Time -> Int
month :: Time -> Int
day :: Time -> Int
hour :: Time -> Int
minute :: Time -> Int
second :: Time -> Int
```

```haskell
weekday :: Time -> Int
```

0 for Sunday, 1 for Monday... 6 for Saturday.
