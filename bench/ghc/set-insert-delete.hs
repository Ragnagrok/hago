import Data.List (foldl')
import qualified Data.Set as Set

main :: IO ()
main = do
  let n = 1000000 :: Int
      s = foldl' (\acc k -> Set.insert ((k * 7919) `mod` n) acc) Set.empty [1 .. n]
      s' = foldl' (\acc k -> Set.delete ((k * 7919) `mod` n) acc) s [1 .. n `div` 2]
      found = length (filter (\k -> Set.member k s') [1 .. n])
  print (Set.size s', found)
