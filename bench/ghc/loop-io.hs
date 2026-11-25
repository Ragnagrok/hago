import Control.Monad (when)

loop :: Int -> Int -> IO ()
loop i acc
  | i == 0 = print acc
  | otherwise = do
      when (i `mod` 1000000 == 0) (putStrLn "tick")
      loop (i - 1) (acc + i)

main :: IO ()
main = loop 5000000 0
