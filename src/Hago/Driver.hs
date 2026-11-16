{-# LANGUAGE TemplateHaskell #-}

-- | From a source file to Go source: prelude, parsing, type checking, code
-- generation.
module Hago.Driver (compile, compileFile) where

import Data.List (isPrefixOf)
import Hago.CodeGen (generate)
import Hago.Derive (expandDeriving)
import Hago.Embed (embedFile)
import Hago.Parser (parseModule, resolveFixity)
import Hago.Typecheck (typecheck)

preludeSource :: String
preludeSource = $(embedFile "prelude/Prelude.hgo")

runtimeSource :: String
runtimeSource = unlines (drop 1 (dropWhile (not . ("// --- runtime ---" `isPrefixOf`)) (lines raw)))
  where raw = $(embedFile "runtime/runtime.go")

compile :: FilePath -> String -> Either String String
compile file src = do
  prelude <- parseModule "Prelude.hgo" preludeSource
  user <- parseModule file src
  decls <- either (Left . ((file ++ ": ") ++)) Right (expandDeriving (prelude ++ user))
  prog <- either (Left . ((file ++ ": ") ++)) Right (typecheck (resolveFixity decls))
  pure (generate runtimeSource prog)

compileFile :: FilePath -> IO (Either String String)
compileFile file = compile file <$> readFile file
