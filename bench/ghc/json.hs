{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}

-- examples/json.hgo with Data.Json, Text.Parser and Text.Pretty, ported to
-- GHC as they are: the same combinators, the same reply, the same printer.
-- Hago's String is Go's string, so Data.Text stands for it, and fields are
-- strict (StrictData), as Hago's are. Two places differ because Go's
-- strings do something Text does not: comparing two suffixes of the same
-- text takes constant time in Go (same pointer), so here they are compared
-- by their length in bytes, which is the same test for suffixes; and a
-- match is taken by its length (takeWord8) instead of stripSuffix.
module Main (main) where

import Control.Applicative
import Data.Char (isDigit, isSpace, ord, chr)
import qualified Data.Text as T
import qualified Data.Text.IO as T
import qualified Data.Text.Read as TR
import Data.Text.Unsafe (lengthWord8, takeWord8)
import System.Environment (getArgs)

type String' = T.Text

same :: T.Text -> T.Text -> Bool
same a b = lengthWord8 a == lengthWord8 b

-- Text.Pretty -------------------------------------------------------------------

data Doc = Nil | Text String' | Line String' | Cat Doc Doc | Nest Int Doc | Group Doc

instance Semigroup Doc where
  a <> b = Cat a b

instance Monoid Doc where
  mempty = Nil

text :: String' -> Doc
text = Text

line, linebreak :: Doc
line = Line " "
linebreak = Line ""

nest :: Int -> Doc -> Doc
nest = Nest

group :: Doc -> Doc
group = Group

punctuate :: Doc -> [Doc] -> [Doc]
punctuate _ [] = []
punctuate _ [d] = [d]
punctuate p (d : ds) = (d <> p) : punctuate p ds

data Mode = Flat | Break

data Stack = Done | Push Int Mode Doc Stack

fits :: Int -> Int -> Mode -> Doc -> Stack -> Bool
fits w i m d z
  | w < 0 = False
  | otherwise = case d of
      Nil -> case z of
        Done -> True
        Push i' m' d' z' -> fits w i' m' d' z'
      Text s -> fits (w - T.length s) i m Nil z
      Line s -> case m of
        Flat -> fits (w - T.length s) i m Nil z
        Break -> True
      Cat a b -> fits w i m a (Push i m b z)
      Nest j x -> fits w (i + j) m x z
      Group x -> fits w i Flat x z

layout :: Int -> Doc -> [String']
layout w d0 = go 0 0 Break d0 Done
  where
    go k i m x z = case x of
      Nil -> case z of
        Done -> []
        Push i' m' x' z' -> go k i' m' x' z'
      Text s -> s : go (k + T.length s) i m Nil z
      Line s -> case m of
        Flat -> s : go (k + T.length s) i m Nil z
        Break -> T.cons '\n' (T.replicate i " ") : go i i m Nil z
      Cat a b -> go k i m a (Push i m b z)
      Nest j y -> go k (i + j) m y z
      Group y -> case m of
        Flat -> go k i Flat y z
        Break -> if fits (w - k) i Flat y z then go k i Flat y z else go k i Break y z

render :: Int -> Doc -> String'
render w d = T.concat (layout w d)

-- Text.Parser --------------------------------------------------------------------

data Reply a = Reply (Maybe a) String' [String]

newtype Parser a = Parser (String' -> Reply a)

runP :: Parser a -> String' -> Reply a
runP (Parser f) s = f s

data Pos = Pos Int Int

data ParseError = ParseError Pos [String] String'

parse :: Parser a -> String' -> Either ParseError a
parse p s = case runP p s of
  Reply (Just x) _ _ -> Right x
  Reply Nothing rest e -> Left (ParseError (position s rest) e rest)

position :: String' -> String' -> Pos
position s rest = go 1 1 s
  where
    go l c t
      | same t rest = Pos l c
      | otherwise = case T.uncons t of
          Just ('\n', t') -> go (l + 1) 1 t'
          Just (_, t') -> go l (c + 1) t'
          Nothing -> Pos l c

showError :: ParseError -> String
showError (ParseError (Pos l c) ex left) =
  "line " ++ show l ++ ", column " ++ show c ++ ": unexpected "
    ++ maybe "end of input" (\(ch, _) -> show ch) (T.uncons left)
    ++ expecting (nubStrings ex)
  where
    expecting [] = ""
    expecting [x] = ", expected " ++ x
    expecting xs = ", expected " ++ commaList xs
    commaList [x, y] = x ++ " or " ++ y
    commaList (x : xs) = x ++ ", " ++ commaList xs
    commaList [] = ""

nubStrings :: [String] -> [String]
nubStrings [] = []
nubStrings (x : xs) = x : nubStrings (filter (/= x) xs)

after :: String' -> [String] -> String' -> [String] -> [String]
after rest1 e1 rest2 e2
  | not (same rest2 rest1) = e2
  | null e1 = e2
  | null e2 = e1
  | otherwise = e1 ++ e2

instance Functor Parser where
  fmap f p = Parser (\s -> case runP p s of
    Reply (Just x) rest e -> Reply (Just (f x)) rest e
    Reply Nothing rest e -> Reply Nothing rest e)

instance Applicative Parser where
  pure x = Parser (\s -> Reply (Just x) s [])
  pf <*> px = liftA2 id pf px
  liftA2 f pa pb = Parser (\s -> case runP pa s of
    Reply Nothing rest e -> Reply Nothing rest e
    Reply (Just a) rest1 e1 -> case runP pb rest1 of
      Reply Nothing rest2 e2 -> Reply Nothing rest2 (after rest1 e1 rest2 e2)
      Reply (Just b) rest2 e2 -> Reply (Just (f a b)) rest2 (after rest1 e1 rest2 e2))
  pa *> pb = Parser (\s -> case runP pa s of
    Reply Nothing rest e -> Reply Nothing rest e
    Reply (Just _) rest1 e1 -> case runP pb rest1 of
      Reply y rest2 e2 -> Reply y rest2 (after rest1 e1 rest2 e2))
  pa <* pb = Parser (\s -> case runP pa s of
    Reply Nothing rest e -> Reply Nothing rest e
    Reply (Just a) rest1 e1 -> case runP pb rest1 of
      Reply Nothing rest2 e2 -> Reply Nothing rest2 (after rest1 e1 rest2 e2)
      Reply (Just _) rest2 e2 -> Reply (Just a) rest2 (after rest1 e1 rest2 e2))

instance Monad Parser where
  p >>= k = Parser (\s -> case runP p s of
    Reply Nothing rest e -> Reply Nothing rest e
    Reply (Just x) rest1 e1 -> case runP (k x) rest1 of
      Reply y rest2 e2 -> Reply y rest2 (after rest1 e1 rest2 e2))

instance Alternative Parser where
  empty = Parser (\s -> Reply Nothing s [])
  p <|> q = Parser (\s -> case runP p s of
    Reply Nothing rest1 e1 | same rest1 s -> case runP q s of
      Reply y rest2 e2 | same rest2 s -> Reply y rest2 (after s e1 s e2)
      other -> other
    other -> other)
  many = manyP
  some = someP

instance MonadFail Parser where
  fail msg = empty <?> msg

satisfy :: (Char -> Bool) -> Parser Char
satisfy f = Parser (\s -> case T.uncons s of
  Just (c, cs) | f c -> Reply (Just c) cs []
  _ -> Reply Nothing s [])

takeWhileP :: Maybe String -> (Char -> Bool) -> Parser String'
takeWhileP name f =
  let e = maybe [] (\n -> [n]) name
   in Parser (\s -> case T.span f s of (run, rest) -> Reply (Just run) rest e)

takeWhile1P :: Maybe String -> (Char -> Bool) -> Parser String'
takeWhile1P name f =
  let e = maybe [] (\n -> [n]) name
   in Parser (\s -> case T.span f s of
        (run, rest) -> Reply (if T.null run then Nothing else Just run) rest e)

match :: Parser a -> Parser (String', a)
match p = Parser (\s -> case runP p s of
  Reply (Just x) rest e -> Reply (Just (takeWord8 (lengthWord8 s - lengthWord8 rest) s, x)) rest e
  Reply Nothing rest e -> Reply Nothing rest e)

label :: String -> Parser a -> Parser a
label name p =
  let e = [name]
   in Parser (\s -> case runP p s of
        Reply x rest _ | same rest s -> Reply x rest e
        other -> other)

infix 0 <?>

(<?>) :: Parser a -> String -> Parser a
p <?> name = label name p

char :: Char -> Parser Char
char c = satisfy (== c) <?> show c

string :: String' -> Parser String'
string str =
  let e = [show str]
   in Parser (\s -> case T.stripPrefix str s of
        Just rest -> Reply (Just str) rest []
        Nothing -> Reply Nothing s e)

eof :: Parser ()
eof = let e = ["end of input"] in Parser (\s -> if T.null s then Reply (Just ()) s [] else Reply Nothing s e)

oneOf :: [Char] -> Parser Char
oneOf cs = satisfy (`elem` cs)

manyP :: Parser a -> Parser [a]
manyP p = Parser (\s0 -> go [] s0)
  where
    go acc s = case runP p s of
      Reply (Just x) rest _
        | not (same rest s) -> go (x : acc) rest
        | otherwise -> error "many: the parser succeeded without consuming input"
      Reply Nothing rest e
        | same rest s -> Reply (Just (reverse acc)) s e
        | otherwise -> Reply Nothing rest e

someP :: Parser a -> Parser [a]
someP p = liftA2 (:) p (manyP p)

sepBy :: Parser a -> Parser s -> Parser [a]
sepBy p sep = sepBy1 p sep <|> pure []

sepBy1 :: Parser a -> Parser s -> Parser [a]
sepBy1 p sep = liftA2 (:) p (manyP (sep *> p))

between :: Parser o -> Parser c -> Parser a -> Parser a
between open close p = open *> p <* close

option :: a -> Parser a -> Parser a
option x p = p <|> pure x

count :: Int -> Parser a -> Parser [a]
count n p = sequenceA (replicate n p)

spaces :: Parser ()
spaces = () <$ takeWhileP Nothing isSpace

-- Data.Json ----------------------------------------------------------------------

data Json
  = JNull
  | JBool Bool
  | JNumber Double
  | JString String'
  | JArray [Json]
  | JObject [(String', Json)]
  deriving (Eq, Show)

decode :: String' -> Either String Json
decode s = case parse document s of
  Right j -> Right j
  Left e -> Left (showError e)

document :: Parser Json
document = spaces *> value <* eof

value :: Parser Json
value = (object <|> array <|> fmap JString stringLiteral <|> number <|> constant) <* spaces
  <?> "a value"

symbol :: Char -> Parser Char
symbol c = char c <* spaces

object :: Parser Json
object = JObject <$> between (symbol '{') (symbol '}') (sepBy member (symbol ','))
  where
    member = liftA2 (,) (stringLiteral <* spaces <* symbol ':') value

array :: Parser Json
array = JArray <$> between (symbol '[') (symbol ']') (sepBy value (symbol ','))

constant :: Parser Json
constant = (JNull <$ string "null") <|> (JBool True <$ string "true") <|> (JBool False <$ string "false")

number :: Parser Json
number = do
  (txt, _) <- match (option () (() <$ string "-") *> int *> option () frac *> option () expo)
  case TR.signed TR.double txt of
    Right (x, r) | T.null r -> pure (JNumber x)
    Right _ -> fail "a number"
    Left err -> fail err
  where
    digits = takeWhileP (Just "a digit") isDigit
    int = (() <$ string "0") <|> (oneOf "123456789" *> (() <$ digits))
    frac = (char '.' <?> "a fraction") *> (() <$ takeWhile1P (Just "a digit") isDigit)
    expo = (oneOf "eE" <?> "an exponent") *> option ' ' (oneOf "+-") *> (() <$ takeWhile1P (Just "a digit") isDigit)

stringLiteral :: Parser String'
stringLiteral = fmap T.concat (char '"' *> manyP piece <* (char '"' <?> "the closing quote"))
  where
    piece = fmap T.singleton (char '\\' *> escape) <|> takeWhile1P Nothing plain <?> "a character"
    plain c = c /= '"' && c /= '\\' && ord c >= 32
    escape = simple <|> (char 'u' *> unicode) <?> "an escape"
    simple = do
      c <- oneOf "\"\\/bfnrt"
      pure (case c of
        'b' -> '\b'
        'f' -> '\f'
        'n' -> '\n'
        'r' -> '\r'
        't' -> '\t'
        _ -> c)
    unicode = do
      hi <- hex4
      if hi >= 55296 && hi < 56320
        then do
          lo <- string "\\u" *> hex4
          if lo >= 56320 && lo < 57344
            then pure (chr (65536 + (hi - 55296) * 1024 + (lo - 56320)))
            else fail "the second half of a surrogate pair"
        else pure (chr hi)
    hex4 = fmap (foldl (\n d -> n * 16 + d) 0) (count 4 hexDigit)
    hexDigit = fmap hexValue (satisfy isHexDigit') <?> "a hex digit"
    isHexDigit' c = isDigit c || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
    hexValue c
      | isDigit c = ord c - ord '0'
      | c >= 'a' = ord c - ord 'a' + 10
      | otherwise = ord c - ord 'A' + 10

pretty :: Int -> Json -> String'
pretty width j = render width (doc j)

doc :: Json -> Doc
doc x = case x of
  JArray [] -> text "[]"
  JArray (y : ys) -> block "[" "]" (doc y) (items ys)
  JObject [] -> text "{}"
  JObject (m : ms) -> block "{" "}" (member m) (members ms)
  _ -> text (scalar x)
  where
    items [] = mempty
    items (y : ys) = comma <> doc y <> items ys
    members [] = mempty
    members (m : ms) = comma <> member m <> members ms
    member (k, v) = text (quoteThen k ": ") <> doc v
    comma = text "," <> line
    block open close first rest =
      group (text open <> nest 2 (linebreak <> first <> rest) <> linebreak <> text close)

scalar :: Json -> String'
scalar x = case x of
  JNull -> "null"
  JBool True -> "true"
  JBool False -> "false"
  JNumber n -> number' n
  JString s -> quoteThen s ""
  _ -> ""
  where
    number' n
      | n == fromIntegral (truncate n :: Int) && abs n < 1.0e15 = T.pack (show (truncate n :: Int))
      | otherwise = T.pack (show n)

quoteThen :: String' -> String' -> String'
quoteThen s aft
  | T.null (T.dropWhile (not . needsEscape) s) = T.concat ["\"", s, "\"", aft]
  | otherwise = T.concat ("\"" : pieces s)
  where
    pieces t = case T.break needsEscape t of
      (run, rest) -> run : case T.uncons rest of
        Nothing -> ["\"", aft]
        Just (c, rest') -> esc c : pieces rest'
    esc c = case c of
      '"' -> "\\\""
      '\\' -> "\\\\"
      '\n' -> "\\n"
      '\r' -> "\\r"
      '\t' -> "\\t"
      _ | ord c < 32 -> T.pack ['\\', 'u', '0', '0', hexD (ord c `div` 16), hexD (ord c `mod` 16)]
        | otherwise -> T.singleton c
    hexD n = if n < 10 then chr (ord '0' + n) else chr (ord 'a' + n - 10)

needsEscape :: Char -> Bool
needsEscape c = c == '"' || c == '\\' || ord c < 32

main :: IO ()
main = do
  [file] <- getArgs
  s <- T.readFile file
  either putStrLn (T.putStrLn . pretty 80) (decode s)
