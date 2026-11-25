import Control.Monad (when)

-- The loop of loop-io.hs as two functions that call each other at the end.
loop :: Int -> Int -> IO ()
loop i acc
  | i == 0 = print acc
  | otherwise = do
      when (i `mod` 1000000 == 0) (putStrLn "tick")
      other (i - 1) (acc + i)

other :: Int -> Int -> IO ()
other i acc
  | i == 0 = print acc
  | otherwise = do
      when (i `mod` 1000000 == 0) (putStrLn "tock")
      loop (i - 1) (acc + 2 * i)

main :: IO ()
main = loop 5000000 0
