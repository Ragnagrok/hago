import Control.Monad
import Control.Monad.ST
import Data.Array.ST
import Data.List (foldl')
import qualified Data.Map.Strict as Map
import System.Environment (getArgs)
import Text.Read (readMaybe)

primesST :: Int -> Int
primesST n = runST $ do
  composite <- newArray (0, n) False :: ST s (STUArray s Int Bool)
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

primesMap :: Int -> Int
primesMap n = sieveFrom n 2 Map.empty 0

sieveFrom :: Int -> Int -> Map.Map Int [Int] -> Int -> Int
sieveFrom n i next found
  | i > n = found
  | otherwise = case Map.lookup i next of
      Nothing -> sieveFrom n (i + 1) (Map.insert (i * i) [i] next) (found + 1)
      Just ps -> sieveFrom n (i + 1) (foldl' (\m p -> Map.insertWith (++) (i + p) [p] m) (Map.delete i next) ps) found

main :: IO ()
main = do
  args <- getArgs
  let n = case args of
        a : _ -> maybe 100000 id (readMaybe a)
        [] -> 100000
      which = case args of
        [_, w] -> w
        _ -> "both"
  when (which /= "map") (print (primesST n))
  when (which /= "st") (print (primesMap n))
