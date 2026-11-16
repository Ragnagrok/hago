{-# LANGUAGE TemplateHaskell #-}

-- | From a source file to Go source: loading modules, renaming, type
-- synonyms, deriving, type checking, specialisation, newtype erasure, code
-- generation.
module Hago.Driver (compileFile) where

import Control.Monad (foldM)
import Data.Char (isAlphaNum, isDigit)
import Data.List (intercalate, isPrefixOf)
import qualified Data.Map as M
import qualified Data.Set as S
import Hago.CodeGen (generate)
import Hago.Derive (expandDeriving)
import Hago.Embed (embedFile)
import Hago.Expand (expandSynonyms, synonymsOf)
import Hago.Newtype (eraseNewtypes)
import Hago.Parser (fixitiesOf, parseModule, resolveFixity)
import Hago.Cache
import Hago.Rename (renameModule)
import Hago.Specialize (specialize)
import Hago.Syntax
import Hago.Typecheck (Checked (..), programOf, typecheckModule)
import System.Directory (doesFileExist)
import System.FilePath (takeDirectory, (<.>), (</>))

preludeSource :: String
preludeSource = $(embedFile "prelude/Prelude.hgo")

-- | The standard library, compiled into hago: a program's own module of the
-- same name comes first.
libraryModules :: M.Map Name String
libraryModules = M.fromList
  [ ("Data.Functor.Identity", $(embedFile "lib/Data/Functor/Identity.hgo"))
  , ("Control.Monad.Trans", $(embedFile "lib/Control/Monad/Trans.hgo"))
  , ("Control.Monad.State", $(embedFile "lib/Control/Monad/State.hgo"))
  , ("Control.Monad.Except", $(embedFile "lib/Control/Monad/Except.hgo"))
  , ("Control.Monad.Reader", $(embedFile "lib/Control/Monad/Reader.hgo"))
  , ("System.Environment", $(embedFile "lib/System/Environment.hgo"))
  , ("Data.String", $(embedFile "lib/Data/String.hgo")) ]

runtimeSource :: String
runtimeSource = unlines (drop 1 (dropWhile (not . ("// --- runtime ---" `isPrefixOf`)) (lines raw)))
  where raw = $(embedFile "runtime/runtime.go")

-- | Eq, Ord, Show, Bounded and Read for every size of tuple, written out as
-- Prelude source.
tupleInstances :: String
tupleInstances = unlines (concatMap instances [2 .. maxTuple])
  where
    instances n =
      let xs = ["x" ++ show i | i <- [1 .. n]]
          ys = ["y" ++ show i | i <- [1 .. n]]
          ts = ["t" ++ show i | i <- [1 .. n]]
          tuple vs = "(" ++ intercalate ", " vs ++ ")"
          ctx c = "(" ++ intercalate ", " [c ++ " " ++ t | t <- ts] ++ ")"
          chain op = foldr1 (\a b -> a ++ " " ++ op ++ " (" ++ b ++ ")")
       in [ ""
          , "instance " ++ ctx "Eq" ++ " => Eq " ++ tuple ts ++ " where"
          , "  " ++ tuple xs ++ " == " ++ tuple ys ++ " = " ++ chain "&&" (zipWith (\x y -> x ++ " == " ++ y) xs ys)
          , ""
          , "instance " ++ ctx "Ord" ++ " => Ord " ++ tuple ts ++ " where"
          , "  compare " ++ tuple xs ++ " " ++ tuple ys ++ " = " ++ chain "<>" (zipWith (\x y -> "compare " ++ x ++ " " ++ y) xs ys)
          , ""
          , "instance " ++ ctx "Show" ++ " => Show " ++ tuple ts ++ " where"
          , "  show " ++ tuple xs ++ " = \"(\" ++ " ++ intercalate " ++ \",\" ++ " ["show " ++ x | x <- xs] ++ " ++ \")\""
          , ""
          , "instance " ++ ctx "Bounded" ++ " => Bounded " ++ tuple ts ++ " where"
          , "  minBound = " ++ tuple (map (const "minBound") ts)
          , "  maxBound = " ++ tuple (map (const "maxBound") ts)
          , ""
          , "instance " ++ ctx "Read" ++ " => Read " ++ tuple ts ++ " where"
          , "  readsPrec = readParens (\\_ s0 -> do"
          , "    r0 <- expectToken \"(\" s0" ]
          ++ concat
            [ [ "    (" ++ x ++ ", s" ++ show i ++ ") <- readsPrec 0 r" ++ show (i - 1)
              , "    r" ++ show i ++ " <- expectToken \"" ++ (if i == n then ")" else ",") ++ "\" s" ++ show i ]
            | (i, x) <- zip [1 :: Int ..] xs ]
          ++ [ "    pure (" ++ tuple xs ++ ", r" ++ show n ++ "))" ]

-- | Compiles one module, given what its imports give.
compileModule :: Iface -> (FilePath, Module) -> Either String Iface
compileModule before (path, m) = do
  (renamed, rn) <- renameModule (ifRenamed before) m
  expanded <- expandSynonyms (ifSynonyms before) renamed
  decls <- expandDeriving expanded
  checked <- typecheckModule path (modName m) (ifChecked before) (resolveFixity (ifFixities before) decls)
  pure (Iface rn (synonymsOf renamed) (fixitiesOf renamed) checked)

-- | A module to compile: its file, name, source, and, but for the Prelude,
-- which is parsed only when it has to be checked, its parse.
data Unit = Unit FilePath Name String (Maybe Module)

compileFile :: FilePath -> IO (Either String String)
compileFile file = do
  loaded <- loadAll file
  stamp <- compilerStamp
  cache <- cacheDirectory
  let preludeUnit = Unit "Prelude.hgo" "Prelude" (preludeSource ++ tupleInstances) Nothing
  result <- case loaded of
    Left e -> pure (Left e)
    Right mods -> compileUnits stamp cache (preludeUnit : [Unit path (modName m) src (Just m) | (path, src, m) <- mods])
  either (fmap Left . quoteSource) (pure . Right) $ do
    ifaces <- result
    let checked = map (ifChecked . snd) ifaces
    -- two modules that do not import each other can still give the same instance
    case [(c, k) | ((c, k), n) <- M.toList (M.fromListWith (+) [(key, 1 :: Int) | ck <- checked, key <- M.keys (ckInsts ck)]), n > 1] of
      (c, k) : _ -> Left (file ++ ": two modules define the instance " ++ c ++ " " ++ k)
      [] -> pure ()
    prog <- either (Left . ((file ++ ": ") ++)) Right (specialize (programOf (mconcat checked)))
    pure (generate runtimeSource (eraseNewtypes prog))

-- | Compiles each module, dependencies first, reusing what the cache keeps
-- for a module whose source and imports have not changed. Each module is
-- checked with what its imports give, directly or not, and nothing else.
compileUnits :: String -> Maybe FilePath -> [Unit] -> IO (Either String [(Name, Iface)])
compileUnits stamp cache = go M.empty M.empty []
  where
    go _ _ done [] = pure (Right (reverse done))
    go keys deps done (Unit path name src parsed : rest) = do
      let direct = [i | name /= "Prelude", i <- "Prelude" : maybe [] (map impModule . modImports) parsed]
          below = S.unions (S.fromList direct : [M.findWithDefault S.empty i deps | i <- direct])
          key = moduleKey stamp src [M.findWithDefault "" i keys | i <- direct]
          before = mconcat [iface | (n, iface) <- reverse done, S.member n below]
      kept <- maybe (pure Nothing) (\dir -> readIface dir name key) cache
      r <- case kept of
        Just iface -> pure (Right iface)
        Nothing -> case maybe (parseModule path src) Right parsed of
          Left e -> pure (Left e)
          Right m -> case compileModule before (path, m {modName = name}) of
            Left e -> pure (Left e)
            Right iface -> do
              mapM_ (\dir -> writeIface dir name key iface) cache
              pure (Right iface)
      case r of
        Left e -> pure (Left e)
        Right iface -> go (M.insert name key keys) (M.insert name below deps) ((name, iface) : done) rest

-- | Follows an error that starts with file:line:column with that line of the
-- source and a mark under the place:
--
-- > rejected/mismatch.hgo:3:18: in main: type mismatch: expected String, got Int
-- >   |
-- > 3 | main = putStrLn (length [1, 2, 3])
-- >   |                  ^^^^^^
quoteSource :: String -> IO String
quoteSource err = case location err of
  Nothing -> pure err
  Just (path, l, c) -> do
    exists <- doesFileExist path
    src <- if exists then readFile path else pure ""
    pure $ case drop (l - 1) (lines src) of
      line : _ | l >= 1, c >= 1, c <= length line + 1 ->
        let n = show l
            pad = replicate (length n) ' '
            rest = drop (c - 1) line
            (headline, details) = break (== '\n') err
         in intercalate "\n"
              [ headline
              , pad ++ " |"
              , n ++ " | " ++ line
              , pad ++ " | " ++ map (\ch -> if ch == '\t' then '\t' else ' ') (take (c - 1) line) ++ replicate (tokenWidth rest) '^' ]
              ++ details
      _ -> err
  where
    -- a word, an operator, or a field access like .name
    tokenWidth rest = case rest of
      '.' : more@(ch : _) | isWordChar ch -> 1 + length (takeWhile isWordChar more)
      ch : _
        | isWordChar ch -> length (takeWhile isWordChar rest)
        | isSymbolChar ch -> length (takeWhile isSymbolChar rest)
      _ -> 1
    isWordChar ch = isAlphaNum ch || ch == '_' || ch == '\''
    isSymbolChar ch = ch `elem` ("!#$%&*+./<=>?@\\^|-~:" :: String)
    location s = case break (== ':') s of
      (path, ':' : more) | not (null path), (l, ':' : more') <- span isDigit more, (c, ':' : _) <- span isDigit more', not (null l), not (null c) ->
        Just (path, read l, read c)
      _ -> Nothing

-- | The main module and everything it imports, dependencies first. A module
-- A.B lives in A/B.hgo, next to the main file, or in the standard library.
loadAll :: FilePath -> IO (Either String [(FilePath, String, Module)])
loadAll mainFile = do
  r <- load [] (Right (M.empty, [])) ("Main", mainFile, Nothing)
  pure (fmap (reverse . snd) r)
  where
    root = takeDirectory mainFile
    load stack acc (name, path, from) = case acc of
      Left e -> pure (Left e)
      Right (seen, done)
        | M.member name seen -> pure acc
        | name `elem` stack -> pure (Left ("import cycle: " ++ intercalate " -> " (reverse (name : stack))))
        | otherwise -> do
            exists <- doesFileExist path
            found <- case (exists, M.lookup name libraryModules) of
              (True, _) -> Just . (,) path <$> readFile path
              (False, Just src) -> pure (Just ("lib" </> moduleFile name, src))
              (False, Nothing) -> pure Nothing
            case found of
              Nothing -> pure (Left (maybe "" ((++ ": ") . showLoc) from ++ "cannot find module " ++ name ++ " (looked for " ++ path ++ ")"))
              Just (path', src) ->
                case parseModule path' src of
                  Left e -> pure (Left e)
                  Right m
                    | modName m /= name ->
                        pure (Left (path' ++ ": declares module " ++ modName m ++ ", but should be " ++ name))
                    | otherwise -> do
                        let deps = [(impModule i, root </> moduleFile (impModule i), Just (impLoc i)) | i <- modImports m, impModule i /= "Prelude"]
                        r <- foldM (load (name : stack)) (Right (seen, done)) deps
                        pure (fmap (\(seen', done') -> (M.insert name () seen', (path', src, m) : done')) r)
    moduleFile n = map (\c -> if c == '.' then '/' else c) n <.> "hgo"
