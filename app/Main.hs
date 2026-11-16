-- | The hago command line.
module Main (main) where

import Hago.Driver (compileFile)
import System.Directory (createDirectoryIfMissing, findExecutable, getTemporaryDirectory)
import System.Environment (getArgs)
import System.Exit
import System.FilePath (takeBaseName, (</>))
import System.IO
import System.Process (callProcess, rawSystem)

usage :: String
usage = unlines
  [ "usage: hago build FILE.hgo [-o OUT.go]   compile to Go"
  , "       hago run FILE.hgo                 compile and run with `go run`" ]

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
        Just _ -> callProcess "gofmt" ["-w", out]
        Nothing -> pure ()
      pure out
