main :: IO ()
main = print (foldr max 0 [1 .. 10000000 :: Int])
