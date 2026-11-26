-- Two pure functions that end calling each other, a hundred million times:
-- a state machine that adds what it sees, by turns.
evens :: Int -> Int -> Int
evens i acc = if i == 0 then acc else odds (i - 1) (acc + i)

odds :: Int -> Int -> Int
odds i acc = if i == 0 then acc else evens (i - 1) (acc + 2 * i)

main :: IO ()
main = print (evens 100000000 0)
