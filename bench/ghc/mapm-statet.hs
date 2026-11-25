import Control.Monad.State.Strict

main :: IO ()
main = do
  n <- execStateT (mapM_ (\x -> modify' (+ x)) [1 .. 1000000 :: Int]) 0
  print n
