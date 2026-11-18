{-# LANGUAGE LambdaCase #-}

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
  | TProj String      -- ^ @.x@ written tight against what precedes it: a field
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
lexer src = fieldDots <$> go 1 1 src
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
              -- e10, e+10, e-10
              expo r = case r of
                e : r1 | e `elem` "eE" ->
                  let (sign, r2) = case r1 of
                        x : r' | x `elem` "+-" -> ([x], r')
                        _ -> ("", r1)
                      (ds, r3) = span isDigit r2
                   in if null ds then Nothing else Just ("e" ++ filter (/= '+') sign ++ ds, r3)
                _ -> Nothing
              float text n r = emit (TFloat (read text)) n r
           in case rest of
                '.' : r@(x : _) | isDigit x ->
                  let (frac, rest') = span isDigit r
                      mant = d ++ "." ++ frac
                   in case expo rest' of
                        Just (ex, rest'') -> float (mant ++ ex) (length s - length rest'') rest''
                        Nothing -> float mant (length mant) rest'
                _ -> case expo rest of
                  Just (ex, rest'') -> float (d ++ ".0" ++ ex) (length s - length rest'') rest''
                  Nothing -> emit (TInt (read d)) (length d) rest
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

-- | A dot is a field access when it touches both the name after it and what
-- comes before: @p.name@, @(f x).name@, @p.pos.x@ and the section @(.name)@.
-- With a space on either side it is composition, as always: @f . g@.
fieldDots :: [Token] -> [Token]
fieldDots = go Nothing
  where
    go prev (d : n : rest)
      | TVarSym "." <- tokVal d
      , TVarId x <- tokVal n
      , '.' `notElem` x
      , tokLine n == tokLine d
      , tokCol n == tokCol d + 1
      , Just p <- prev
      , touches p d =
          let t = d {tokVal = TProj x} in t : go (Just t) rest
    go _ (t : rest) = t : go (Just t) rest
    go _ [] = []
    touches p d = tokLine p == tokLine d && fmap (tokCol p +) (width (tokVal p)) == Just (tokCol d)
    width = \case
      TVarId s -> Just (length s)
      TConId s -> Just (length s)
      TProj s -> Just (length s + 1)
      TSpecial s | s `elem` [")", "]", "}", "("] -> Just 1
      _ -> Nothing

-- | One (possibly escaped) character: value, characters consumed, rest.
lexChar :: String -> Maybe (Char, Int, String)
lexChar ('\\' : e : rest) = case e of
  'n' -> Just ('\n', 2, rest)
  't' -> Just ('\t', 2, rest)
  'r' -> Just ('\r', 2, rest)
  'a' -> Just ('\a', 2, rest)
  'b' -> Just ('\b', 2, rest)
  'f' -> Just ('\f', 2, rest)
  'v' -> Just ('\v', 2, rest)
  'x' | (h@(_ : _), r) <- span isHexDigit rest -> Just (chr (read ("0x" ++ h)), length h + 2, r)
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

-- | An open block: its column (0 for explicit braces), the bracket depth
-- it was opened at, the keyword that opened it, and how many @then@s and
-- @else@s, and how many @in@s, of the @if@s and @let@s inside it are
-- still to come.
data Ctx = Ctx {cCol :: Int, cDepth :: Int, cKey :: String, cIfs :: Int, cLets :: Int}

-- | The algorithm L. The report's parse-error(t) rule closes an implicit
-- block when the next token cannot continue it; that is approximated by
-- the tokens that cannot: a closing bracket or a comma of an enclosing
-- bracket, an @in@ whose @let@ is outside the block, a @then@ or @else@
-- whose @if@ is outside the block, and a @where@ after do or in the block's
-- column.
resolve :: [Token] -> [Ctx] -> Int -> [Token]
resolve [] ctx _ = [Token 0 0 (TSpecial "}") | c <- ctx, cCol c /= 0]
resolve (t : ts) ctx depth = case (tokVal t, ctx) of
  (TLineN n, c : ms)
    -- no item of a block starts with where, so a where in its column ends it
    | cCol c == n, (w : _) <- ts, tokVal w == TKey "where" -> sym "}" : resolve ts ms depth
    | cCol c == n -> sym ";" : resolve ts ctx depth
    | n < cCol c -> sym "}" : resolve (t : ts) ms depth
  (TLineN _, _) -> resolve ts ctx depth
  (TOpenN k n, c : _)
    | n > cCol c -> sym "{" : resolve ts (Ctx n depth k 0 0 : ctx) depth
  (TOpenN k n, [])
    | n > 0 -> sym "{" : resolve ts [Ctx n depth k 0 0] depth
  (TOpenN _ n, _) -> sym "{" : sym "}" : resolve (t {tokVal = TLineN n} : ts) ctx depth
  -- explicit braces (blocks and records) count as brackets, so a comma
  -- inside a record closes an implicit block opened in a field's value
  (TSpecial "}", c : ms) | cCol c == 0 -> t : resolve ts ms (depth - 1)
  (TSpecial "}", _ : ms) -> sym "}" : resolve (t : ts) ms depth
  (TSpecial "{", _) -> t : resolve ts (Ctx 0 (depth + 1) "" 0 0 : ctx) (depth + 1)
  (TKey "let", c : ms) -> t : resolve ts (c {cLets = cLets c + 1} : ms) depth
  (TKey "in", c : ms)
    | cLets c > 0 -> t : resolve ts (c {cLets = cLets c - 1} : ms) depth
    | cCol c /= 0, depth <= cDepth c -> sym "}" : resolve (t : ts) ms depth
  (TKey "if", c : ms) -> t : resolve ts (c {cIfs = cIfs c + 2} : ms) depth
  (TKey k, c : ms)
    | k `elem` ["then", "else"], cIfs c > 0 -> t : resolve ts (c {cIfs = cIfs c - 1} : ms) depth
    | k `elem` ["then", "else"], cCol c /= 0, depth <= cDepth c -> sym "}" : resolve (t : ts) ms depth
  (TKey "where", c : ms) | cKey c == "do", cCol c /= 0 -> sym "}" : resolve (t : ts) ms depth
  (TSpecial s, c : ms)
    | cCol c /= 0, s `elem` [")", "]"], depth <= cDepth c -> sym "}" : resolve (t : ts) ms depth
    | cCol c /= 0, s == ",", cDepth c > 0, depth <= cDepth c -> sym "}" : resolve (t : ts) ms depth
  (TSpecial s, _)
    | s `elem` ["(", "["] -> t : resolve ts ctx (depth + 1)
    | s `elem` [")", "]"] -> t : resolve ts ctx (depth - 1)
  _ -> t : resolve ts ctx depth
  where
    sym s = t {tokVal = TSpecial s}
