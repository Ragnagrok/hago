-- | Tokens and the layout rule (Haskell 2010 report, section 10.3).
module Hago.Lexer (Tok (..), Token (..), lexer, layout) where

import Data.Char

data Tok
  = TVarId String
  | TConId String
  | TVarSym String
  | TConSym String
  | TInt Integer
  | TFloat Double
  | TChar Char
  | TStr String
  | TSpecial String   -- ^ ( ) [ ] , ; ` { }
  | TKey String       -- ^ keywords and reserved operators
  | TOpenN String Int -- ^ layout marker {n}, with the keyword that opened it
  | TLineN Int        -- ^ layout marker <n>
  deriving (Eq, Show)

data Token = Token {tokLine :: Int, tokCol :: Int, tokVal :: Tok}
  deriving (Eq, Show)

keywords :: [String]
keywords =
  [ "case", "class", "data", "deriving", "do", "else", "foreign", "if", "import"
  , "in", "infix", "infixl", "infixr", "instance", "let", "module", "newtype"
  , "of", "then", "type", "where", "_" ]

reservedOps :: [String]
reservedOps = ["..", "::", "=", "\\", "|", "<-", "->", "@", "~", "=>"]

symChar :: Char -> Bool
symChar c = c `elem` "!#$%&*+./<=>?@\\^|-~:"

lexer :: String -> Either String [Token]
lexer = go 1 1
  where
    go :: Int -> Int -> String -> Either String [Token]
    go _ _ [] = Right []
    go l _ ('\n' : cs) = go (l + 1) 1 cs
    go l c ('\t' : cs) = go l (((c - 1) `div` 8 + 1) * 8 + 1) cs
    go l c (ch : cs) | isSpace ch = go l (c + 1) cs
    go l c ('-' : '-' : cs)
      | not (startsOp (dropWhile (== '-') cs)) = go l c (dropWhile (/= '\n') cs)
    go l c ('{' : '-' : cs) = blockComment l (c + 2) (1 :: Int) cs
    go l c s@(ch : cs)
      | isAlpha ch || ch == '_' =
          let (w, rest) = span isIdChar s
              t | w `elem` keywords = TKey w
                | isUpper ch = TConId w
                | otherwise = TVarId w
           in if isUpper ch then qualified w rest else emit t (length w) rest
      | isDigit ch =
          let (d, rest) = span isDigit s
           in case rest of
                '.' : r@(x : _) | isDigit x ->
                  let (frac, rest') = span isDigit r
                   in emit (TFloat (read (d ++ "." ++ frac))) (length d + 1 + length frac) rest'
                _ -> emit (TInt (read d)) (length d) rest
      | ch == '\'' = case lexChar cs of
          Just (v, n, '\'' : rest) -> emit (TChar v) (n + 2) rest
          _ -> Left (pos ++ ": bad character literal")
      | ch == '"' = lexString "" 1 cs
      | ch `elem` "()[],;`{}" = emit (TSpecial [ch]) 1 cs
      | symChar ch =
          let (o, rest) = span symChar s
              t | o `elem` reservedOps = TKey o
                | take 1 o == ":" = TConSym o
                | otherwise = TVarSym o
           in emit t (length o) rest
      | otherwise = Left (pos ++ ": unexpected character " ++ show ch)
      where
        pos = show l ++ ":" ++ show c
        emit t n rest = (Token l c t :) <$> go l (c + n) rest
        -- A.B.x, A.B.C and A.+ are single qualified tokens
        qualified prefix rest = case rest of
          '.' : r@(x : _)
            | isUpper x ->
                let (w, rest') = span isIdChar r in qualified (prefix ++ "." ++ w) rest'
            | isAlpha x || x == '_' ->
                let (w, rest') = span isIdChar r
                 in if w `elem` keywords
                      then emit (TConId prefix) (length prefix) rest
                      else emit (TVarId (prefix ++ "." ++ w)) (length prefix + 1 + length w) rest'
            | symChar x && x /= '.' ->
                let (o, rest') = span symChar r
                    t = if x == ':' then TConSym (prefix ++ "." ++ o) else TVarSym (prefix ++ "." ++ o)
                 in emit t (length prefix + 1 + length o) rest'
          _ -> emit (TConId prefix) (length prefix) rest
        lexString acc n ('"' : rest) = emit (TStr (reverse acc)) (n + 1) rest
        lexString acc n rest = case lexChar rest of
          Just (v, k, rest') -> lexString (v : acc) (n + k) rest'
          Nothing -> Left (pos ++ ": unterminated string")
    startsOp (x : _) = symChar x
    startsOp [] = False
    blockComment l c 0 cs = go l c cs
    blockComment l _ d ('\n' : cs) = blockComment l' 1 d cs where l' = l + 1
    blockComment l c d ('-' : '}' : cs) = blockComment l (c + 2) (d - 1) cs
    blockComment l c d ('{' : '-' : cs) = blockComment l (c + 2) (d + 1) cs
    blockComment l c d (_ : cs) = blockComment l (c + 1) d cs
    blockComment _ _ _ [] = Right []
    isIdChar x = isAlphaNum x || x == '_' || x == '\''

-- | One (possibly escaped) character: value, characters consumed, rest.
lexChar :: String -> Maybe (Char, Int, String)
lexChar ('\\' : e : rest) = case e of
  'n' -> Just ('\n', 2, rest)
  't' -> Just ('\t', 2, rest)
  'r' -> Just ('\r', 2, rest)
  '0' -> Just ('\0', 2, rest)
  '\\' -> Just ('\\', 2, rest)
  '\'' -> Just ('\'', 2, rest)
  '"' -> Just ('"', 2, rest)
  _ | isDigit e -> let (d, r) = span isDigit (e : rest) in Just (chr (read d), length d + 1, r)
  _ -> Nothing
lexChar ('\n' : _) = Nothing
lexChar (x : rest) = Just (x, 1, rest)
lexChar [] = Nothing

-- | Inserts the @{n}@ and @<n>@ markers, then resolves them into explicit
-- braces and semicolons.
layout :: [Token] -> [Token]
layout ts = resolve (markers ts) [] 0

openers :: [String]
openers = ["let", "where", "do", "of"]

markers :: [Token] -> [Token]
markers [] = []
markers (t : ts) = case tokVal t of
  TKey "module" -> go (tokLine t) False (t : ts)
  TSpecial "{" -> go (tokLine t) False (t : ts)
  _ -> t {tokVal = TOpenN "" (tokCol t)} : go (tokLine t) True (t : ts)
  where
    -- the Bool says the token right after an inserted {n} gets no <n>
    go _ _ [] = []
    go prevLine noMark (x : xs) =
      let lineMark = [x {tokVal = TLineN (tokCol x)} | tokLine x > prevLine, not noMark]
       in case (tokVal x, xs) of
            (TKey k, next : _)
              | k `elem` openers, tokVal next /= TSpecial "{" ->
                  lineMark ++ [x, next {tokVal = TOpenN k (tokCol next)}]
                    ++ go (tokLine x) True xs
            (TKey k, [])
              | k `elem` openers -> lineMark ++ [x, x {tokVal = TOpenN k 0}]
            _ -> lineMark ++ [x] ++ go (tokLine x) False xs

-- | The algorithm L. Each context remembers the bracket depth it was opened
-- at and the keyword that opened it, so a closing bracket, a comma, an @in@
-- (after let) or a @where@ (after do) can end an implicit block (a cheap stand-in for the report's
-- parse-error(t) rule).
resolve :: [Token] -> [(Int, Int, String)] -> Int -> [Token]
resolve [] ctx _ = [Token 0 0 (TSpecial "}") | (m, _, _) <- ctx, m /= 0]
resolve (t : ts) ctx depth = case (tokVal t, ctx) of
  (TLineN n, (m, _, _) : ms)
    | m == n -> sym ";" : resolve ts ctx depth
    | n < m -> sym "}" : resolve (t : ts) ms depth
  (TLineN _, _) -> resolve ts ctx depth
  (TOpenN k n, (m, _, _) : _)
    | n > m -> sym "{" : resolve ts ((n, depth, k) : ctx) depth
  (TOpenN k n, [])
    | n > 0 -> sym "{" : resolve ts [(n, depth, k)] depth
  (TOpenN _ n, _) -> sym "{" : sym "}" : resolve (t {tokVal = TLineN n} : ts) ctx depth
  (TSpecial "}", (0, _, _) : ms) -> t : resolve ts ms depth
  (TSpecial "{", _) -> t : resolve ts ((0, depth, "") : ctx) depth
  (TKey "in", (m, _, "let") : ms) | m /= 0 -> sym "}" : resolve (t : ts) ms depth
  (TKey "where", (m, _, "do") : ms) | m /= 0 -> sym "}" : resolve (t : ts) ms depth
  (TSpecial c, (m, d, _) : ms)
    | m /= 0, c `elem` [")", "]"], depth <= d -> sym "}" : resolve (t : ts) ms depth
    | m /= 0, c == ",", d > 0, depth <= d -> sym "}" : resolve (t : ts) ms depth
  (TSpecial c, _)
    | c `elem` ["(", "["] -> t : resolve ts ctx (depth + 1)
    | c `elem` [")", "]"] -> t : resolve ts ctx (depth - 1)
  _ -> t : resolve ts ctx depth
  where
    sym s = t {tokVal = TSpecial s}
