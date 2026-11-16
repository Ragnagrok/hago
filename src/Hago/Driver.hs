{-# LANGUAGE TemplateHaskell #-}

-- | From a source file to Go source: loading modules, renaming, type
-- synonyms, deriving, type checking, specialisation, newtype erasure, code
-- generation.
module Hago.Driver (compileFile) where

import Control.Monad (foldM)
import Data.Char (isAlphaNum, isDigit)
import Data.List (intercalate, isPrefixOf)
import qualified Data.Map as M
import Hago.CodeGen (generate)
import Hago.Derive (expandDeriving)
import Hago.Embed (embedFile)
import Hago.Expand (expandSynonyms)
import Hago.Newtype (eraseNewtypes)
import Hago.Parser (parseModule, resolveFixity)
import Hago.Rename (renameModules)
import Hago.Specialize (specialize)
import Hago.Syntax
import Hago.Typecheck (typecheck)
import System.Directory (doesFileExist)
import System.FilePath (takeDirectory, (<.>), (</>))

preludeSource :: String
preludeSource = $(embedFile "prelude/Prelude.hgo")

runtimeSource :: String
runtimeSource = unlines (drop 1 (dropWhile (not . ("// --- runtime ---" `isPrefixOf`)) (lines raw)))
  where raw = $(embedFile "runtime/runtime.go")

-- | Eq, Ord, Show and Bounded for every size of tuple, written out as Prelude
-- source.
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
          ]

compileFile :: FilePath -> IO (Either String String)
compileFile file = do
  loaded <- loadAll file
  either (fmap Left . quoteSource) (pure . Right) $ do
    mods <- loaded
    prelude <- parseModule "Prelude.hgo" (preludeSource ++ tupleInstances)
    renamed <- renameModules (prelude {modName = "Prelude"} : mods)
    expanded <- expandSynonyms renamed
    decls <- expandDeriving expanded
    checked <- typecheck file (resolveFixity decls)
    prog <- either (Left . ((file ++ ": ") ++)) Right (specialize checked)
    pure (generate runtimeSource (eraseNewtypes prog))

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
-- A.B lives in A/B.hgo, next to the main file.
loadAll :: FilePath -> IO (Either String [Module])
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
            if not exists
              then pure (Left (maybe "" ((++ ": ") . showLoc) from ++ "cannot find module " ++ name ++ " (looked for " ++ path ++ ")"))
              else do
                src <- readFile path
                case parseModule path src of
                  Left e -> pure (Left e)
                  Right m
                    | modName m /= name ->
                        pure (Left (path ++ ": declares module " ++ modName m ++ ", but should be " ++ name))
                    | otherwise -> do
                        let deps = [(impModule i, root </> moduleFile (impModule i), Just (impLoc i)) | i <- modImports m, impModule i /= "Prelude"]
                        r <- foldM (load (name : stack)) (Right (seen, done)) deps
                        pure (fmap (\(seen', done') -> (M.insert name () seen', m : done')) r)
    moduleFile n = map (\c -> if c == '.' then '/' else c) n <.> "hgo"
