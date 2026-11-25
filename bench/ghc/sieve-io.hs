import Control.Monad
import Data.Array.IO

primesIO :: Int -> IO Int
primesIO n = do
  composite <- newArray (0, n) False :: IO (IOUArray Int Bool)
  let cross p i = if i > n then pure () else do
        writeArray composite i True
        cross p (i + p)
      count p found
        | p > n = pure found
        | otherwise = do
            crossed <- readArray composite p
            if crossed
              then count (p + 1) found
              else do
                when (p * p <= n) (cross p (p * p))
                count (p + 1) (found + 1)
  count 2 0

main :: IO ()
main = primesIO 10000000 >>= print
