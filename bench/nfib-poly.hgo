nfib :: (Ord a, Num a) => a -> a
nfib n = if n < 2 then 1 else nfib (n - 1) + nfib (n - 2) + 1

main :: IO ()
main = print (nfib (40 :: Int))
