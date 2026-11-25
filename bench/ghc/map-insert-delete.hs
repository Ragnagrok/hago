import Data.List (foldl')
import qualified Data.Map.Strict as Map

main :: IO ()
main = do
  let n = 1000000 :: Int
      m = foldl' (\acc k -> Map.insert ((k * 7919) `mod` n) k acc) Map.empty [1 .. n]
      m' = foldl' (\acc k -> Map.delete ((k * 7919) `mod` n) acc) m [1 .. n `div` 2]
      found = length (filter (\k -> Map.member k m') [1 .. n])
  print (Map.size m', found)
