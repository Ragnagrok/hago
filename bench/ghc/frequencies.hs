import Control.Monad
import Control.Monad.ST
import qualified Data.HashTable.ST.Basic as HashTable
import Data.List (foldl')
import qualified Data.Map.Strict as Map
import System.Environment (getArgs)
import Text.Read (readMaybe)

numbers :: Int -> [Int]
numbers n = map (\x -> x `mod` 100000) (take n (iterate (\x -> (x * 1103515245 + 12345) `mod` 2147483648) 42))

summary :: [(Int, Int)] -> (Int, Int)
summary counts = (length counts, foldl' max 0 (map snd counts))

countTable :: [Int] -> (Int, Int)
countTable xs = summary (runST $ do
  table <- HashTable.new
  mapM_ (\x -> HashTable.mutate table x (\v -> (Just (maybe 1 (+ 1) v), ()))) xs
  HashTable.foldM (\acc kv -> pure (kv : acc)) [] table)

countMap :: [Int] -> (Int, Int)
countMap xs = summary (Map.toList (foldl' (\m x -> Map.insertWith (+) x 1 m) Map.empty xs))

main :: IO ()
main = do
  args <- getArgs
  let n = case args of
        a : _ -> maybe 10000 id (readMaybe a)
        [] -> 10000
      which = case args of
        [_, w] -> w
        _ -> "both"
  when (which /= "map") (print (countTable (numbers n)))
  when (which /= "table") (print (countMap (numbers n)))
