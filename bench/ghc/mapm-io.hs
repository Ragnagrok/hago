import Control.Monad (when)

main :: IO ()
main = mapM_ (\x -> when (x `mod` 250000 == 0) (print x)) [1 .. 1000000 :: Int]
