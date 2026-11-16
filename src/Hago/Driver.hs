{-# LANGUAGE TemplateHaskell #-}

-- | From a source file to Go source: loading modules, renaming, type
-- synonyms, deriving, type checking, specialisation, newtype erasure, code
-- generation.
module Hago.Driver (compileFile) where

import Control.Monad (foldM)
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

compileFile :: FilePath -> IO (Either String String)
compileFile file = do
  loaded <- loadAll file
  pure $ do
    mods <- loaded
    prelude <- parseModule "Prelude.hgo" preludeSource
    renamed <- renameModules (prelude {modName = "Prelude"} : mods)
    expanded <- expandSynonyms renamed
    decls <- expandDeriving expanded
    checked <- typecheck file (resolveFixity decls)
    prog <- either (Left . ((file ++ ": ") ++)) Right (specialize checked)
    pure (generate runtimeSource (eraseNewtypes prog))

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
