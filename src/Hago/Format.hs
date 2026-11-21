{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | hago fmt: the layout changes that can be made without a syntax tree that
-- keeps comments, so that none can move or change meaning. Every token keeps
-- its line (counted among the lines that are not blank) and its column, as
-- the lexer counts it, so the layout rule sees the same blocks:
--
-- * a tab in code becomes the spaces up to the column the lexer moves it to;
-- * whitespace at the end of a line goes;
-- * blank lines in a row become one, and the file starts with no blank line
--   and ends with exactly one newline; Windows line ends become \n.
--
-- Inside string and character literals nothing changes, and comments keep
-- their text and place: only blank lines inside a block comment are kept as
-- they are, and only their trailing whitespace goes. Before giving its result,
-- 'format' checks that the result parses to the same syntax tree, that the
-- comments are the same, and that formatting it again changes nothing.
module Hago.Format (format, comments) where

import Data.Char (isAlpha, isAlphaNum, isDigit, isHexDigit, isSpace)
import Data.Data (Data, gmapT)
import Data.List (dropWhileEnd)
import Data.Typeable (cast)
import Hago.Parser (parseModule)
import Hago.Syntax

-- | The source formatted, or why it cannot be: it does not parse, or (a bug
-- in hago fmt) the result would not keep the program or its comments.
format :: FilePath -> String -> Either String String
format path src = do
  before <- parseModule path src
  let out = layoutOnly src
  after <- either (\e -> Left (path ++ ": hago fmt made a file that does not parse (a bug in hago fmt): " ++ e)) Right (parseModule path out)
  check (shape before == shape after) "changed the syntax tree"
  check (comments src == comments out) "changed a comment"
  check (layoutOnly out == out) "does not give the same file when run again"
  pure out
  where
    check ok what = if ok then Right () else Left (path ++ ": hago fmt " ++ what ++ " (a bug in hago fmt); the file is left as it is")

-- | What a character of the source is part of.
data Part = Code | Literal | LineComment | BlockComment
  deriving (Eq, Show)

-- | Each character of the source with what it is part of, as the lexer reads
-- them: an operator that starts with -- (|--) is code, x' is a name and not
-- the start of a character, and block comments nest.
classify :: String -> [(Char, Part)]
classify = code
  where
    code s = case s of
      [] -> []
      '{' : '-' : rest -> block (1 :: Int) "-{" rest  -- acc is reversed
      '-' : '-' : rest
        | not (startsOp (dropWhile (== '-') rest)) ->
            let (c, more) = break (== '\n') rest in tag LineComment ("--" ++ c) ++ code more
      '"' : rest -> string "\"" rest
      '\'' : rest | Just n <- charLiteral rest -> tag Literal ('\'' : take n rest) ++ code (drop n rest)
      c : _
        | isAlpha c || c == '_' -> let (w, more) = span isIdChar s in tag Code w ++ code more
        | isDigit c -> let (w, more) = span isAlphaNum s in tag Code w ++ code more
        | symChar c -> let (o, more) = span symChar s in tag Code o ++ code more
      c : rest -> (c, Code) : code rest
    -- a string ends at its closing quote, or at the end of the line, where the lexer fails
    string acc s = case s of
      '\\' : c : rest | c /= '\n' -> string (c : '\\' : acc) rest
      '"' : rest -> tag Literal (reverse ('"' : acc)) ++ code rest
      '\n' : _ -> tag Literal (reverse acc) ++ code s
      c : rest -> string (c : acc) rest
      [] -> tag Literal (reverse acc)
    block d acc s = case s of
      _ | d == 0 -> tag BlockComment (reverse acc) ++ code s
      '-' : '}' : rest -> block (d - 1) ('}' : '-' : acc) rest
      '{' : '-' : rest -> block (d + 1) ('-' : '{' : acc) rest
      c : rest -> block d (c : acc) rest
      [] -> tag BlockComment (reverse acc)
    tag p = map (\c -> (c, p))
    startsOp = \case
      c : _ -> symChar c
      [] -> False
    isIdChar c = isAlphaNum c || c == '_' || c == '\''

-- | How many characters after an opening quote make a character literal with
-- its closing quote, as the lexer's lexChar reads one.
charLiteral :: String -> Maybe Int
charLiteral s = case s of
  '\\' : 'x' : rest | (h@(_ : _), '\'' : _) <- span isHexDigit rest -> Just (length h + 3)
  '\\' : c : rest
    | isDigit c, (d, '\'' : _) <- span isDigit (c : rest) -> Just (length d + 2)
    | c `elem` "ntrabfv\\'\"", '\'' : _ <- rest -> Just 3
  c : '\'' : _ | c /= '\n' && c /= '\\' -> Just 2
  _ -> Nothing

symChar :: Char -> Bool
symChar c = c `elem` ("!#$%&*+./<=>?@\\^|-~:" :: String)

-- | The formatting itself.
layoutOnly :: String -> String
layoutOnly src = finish (squeeze (zip startsInComment (map (dropWhileEnd isSpace . expand 1) (splitLines parts))))
  where
    parts = classify (crlf src)
    crlf = \case
      '\r' : '\n' : rest -> '\n' : crlf rest
      c : rest -> c : crlf rest
      [] -> []
    -- a line that starts inside a block comment is part of it, blank or not
    startsInComment = False : [p == BlockComment | ('\n', p) <- parts]
    -- columns as the lexer counts them: a tab in code moves to the next multiple
    -- of 8, and every other character, a tab in a literal or comment too, takes one
    expand :: Int -> [(Char, Part)] -> String
    expand col = \case
      [] -> []
      ('\t', Code) : rest -> let next = ((col - 1) `div` 8 + 1) * 8 + 1 in replicate (next - col) ' ' ++ expand next rest
      (c, _) : rest -> c : expand (col + 1) rest
    squeeze ls = case ls of
      (False, "") : rest@((False, "") : _) -> squeeze rest
      l : rest -> l : squeeze rest
      [] -> []
    finish ls =
      let blank (inComment, l) = not inComment && null l
       in concatMap ((++ "\n") . snd) (dropWhileEnd blank (dropWhile blank ls))

-- | The characters of each line, without the newline.
splitLines :: [(Char, Part)] -> [[(Char, Part)]]
splitLines cs = case break ((== '\n') . fst) cs of
  (l, []) -> [l]
  (l, _ : rest) -> l : splitLines rest

-- | The comments of a source, each without the whitespace at the end of its
-- lines and with the column it starts at: what formatting must keep.
comments :: String -> [(Int, String)]
comments src = go 1 (classify src)
  where
    go col = \case
      [] -> []
      xs@((_, p) : _) | p == LineComment || p == BlockComment ->
        let (c, rest) = span ((== p) . snd) xs
         in (col, unlines' (map (dropWhileEnd isSpace) (lines (map fst c)))) : go (col + length c) rest
      ('\n', _) : rest -> go 1 rest
      ('\t', Code) : rest -> go (((col - 1) `div` 8 + 1) * 8 + 1) rest
      _ : rest -> go (col + 1) rest
    unlines' = foldr1' (\a b -> a ++ "\n" ++ b)
    foldr1' f xs = if null xs then "" else foldr1 f xs

-- | A module without the places of its parts, which blank lines move.
shape :: Module -> (Name, String, [String], [Decl])
shape m =
  ( modName m
  , show (modExports m)
  , [show i {impLoc = noLoc} | i <- modImports m]
  , map erase (modDecls m) )

noLoc :: Loc
noLoc = ("", 0, 0)

-- | Every location inside a value set to nothing.
erase :: forall a. Data a => a -> a
erase x = case cast x :: Maybe Loc of
  Just _ -> maybe x id (cast noLoc)
  Nothing -> gmapT erase x
