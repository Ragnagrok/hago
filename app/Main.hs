-- | The hago command line.
module Main (main) where

import Hago.Driver (compileFile)
import Hago.Repl (repl)
import System.Directory (createDirectoryIfMissing, findExecutable, getTemporaryDirectory)
import System.Environment (getArgs)
import System.Exit
import System.FilePath (takeBaseName, (</>))
import System.IO
import System.Process (rawSystem, readProcessWithExitCode)

usage :: String
usage = unlines
  [ "usage: hago build FILE.hgo [-o OUT.go]   compile to Go"
  , "       hago run FILE.hgo                 compile and run with `go run`"
  , "       hago repl [FILE.hgo]              evaluate expressions as they are typed" ]

main :: IO ()
main = getArgs >>= \args -> case args of
  ["build", file] -> build file (takeBaseName file ++ ".go") >> pure ()
  ["build", file, "-o", out] -> build file out >> pure ()
  ["run", file] -> do
    tmp <- getTemporaryDirectory
    let dir = tmp </> ("hago-" ++ takeBaseName file)
    createDirectoryIfMissing True dir
    out <- build file (dir </> "main.go")
    code <- rawSystem "go" ["run", out]
    exitWith code
  ["repl"] -> repl Nothing
  ["repl", file] -> repl (Just file)
  _ -> hPutStr stderr usage >> exitFailure

build :: FilePath -> FilePath -> IO FilePath
build file out = do
  result <- compileFile file
  case result of
    Left err -> hPutStrLn stderr err >> exitFailure
    Right go -> do
      writeFile out go
      gofmt <- findExecutable "gofmt"
      case gofmt of
        Just _ -> do
          (code, _, err) <- readProcessWithExitCode "gofmt" ["-w", out] ""
          case code of
            ExitSuccess -> pure ()
            ExitFailure _ -> do
              hPutStrLn stderr ("hago produced Go that does not parse (a compiler bug):\n" ++ err)
              exitFailure
        Nothing -> pure ()
      pure out
