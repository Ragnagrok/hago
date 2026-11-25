-- GHC computes fib 32 once here: full laziness floats the shared value out
-- of the list. bench/ghc/run.sh also builds it with -fno-full-laziness, which
-- computes it sixteen times, as Hago does.
fib :: Int -> Int
fib n = if n < 2 then n else fib (n - 1) + fib (n - 2)

main :: IO ()
main = print (sum (map fib (replicate 16 32)))
