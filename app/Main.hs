-- | The hago command line.
module Main (main) where

import Hago.Doc (documentLibrary)
import Hago.Driver (checkFile, compileFile, libraryInterfaces, quoteSource)
import Hago.Format (format)
import Hago.Repl (repl)
import Control.Exception (finally)
import System.Directory (createDirectoryIfMissing, findExecutable, getTemporaryDirectory, listDirectory, removeDirectoryRecursive, removeFile)
import System.Environment (getArgs)
import System.Exit
import System.FilePath (takeBaseName, takeExtension, (<.>), (</>))
import System.IO
import System.Process (getCurrentPid, rawSystem, readProcessWithExitCode)

usage :: String
usage = unlines
  [ "usage: hago build FILE.hgo [-o OUT.go]   compile to Go"
  , "       hago run FILE.hgo [ARGS...]       compile and run, with the arguments given"
  , "       hago check FILE.hgo               type check a program or a module, without making Go"
  , "       hago doc [-o DIR]                 write the standard library's reference (to docs/library)"
  , "       hago fmt [--check] FILE.hgo...    normalise whitespace in place, or say which files need it"
  , "       hago repl [FILE.hgo]              evaluate expressions as they are typed" ]

main :: IO ()
main = getArgs >>= \args -> case args of
  ["build", file] -> build file (takeBaseName file ++ ".go") >> pure ()
  ["build", file, "-o", out] -> build file out >> pure ()
  "run" : file : progArgs -> do
    tmp <- getTemporaryDirectory
    pid <- getCurrentPid
    let dir = tmp </> ("hago-run-" ++ show pid)
        exe = dir </> takeBaseName file
    createDirectoryIfMissing True dir
    code <- (do
        out <- build file (exe <.> "go")
        built <- rawSystem "go" ["build", "-o", exe, out]
        case built of
          ExitSuccess -> rawSystem exe progArgs
          failure -> pure failure)
      `finally` removeDirectoryRecursive dir
    exitWith code
  ["check", file] -> checkFile file >>= either (\err -> hPutStrLn stderr err >> exitFailure) pure
  ["doc"] -> doc ("docs" </> "library")
  ["doc", "-o", dir] -> doc dir
  "fmt" : "--check" : files@(_ : _) -> fmt True files
  "fmt" : files@(_ : _) -> fmt False files
  ["repl"] -> repl Nothing
  ["repl", file] -> repl (Just file)
  _ -> hPutStr stderr usage >> exitFailure

-- | Writes the reference of the Prelude and the library into a directory,
-- removing the Markdown files there that are not part of it.
doc :: FilePath -> IO ()
doc dir = do
  result <- libraryInterfaces
  case result of
    Left err -> hPutStrLn stderr err >> exitFailure
    Right units -> do
      let files = documentLibrary units
      createDirectoryIfMissing True dir
      old <- listDirectory dir
      mapM_ (\f -> removeFile (dir </> f)) [f | f <- old, takeExtension f == ".md", f `notElem` map fst files]
      mapM_ (\(f, text) -> writeFile (dir </> f) text) files

-- | Formats files in place, or with --check says which are not formatted.
-- Fails if a file does not parse, or is not formatted when checking.
fmt :: Bool -> [FilePath] -> IO ()
fmt checking files = do
  results <- mapM one files
  if and results then pure () else exitFailure
  where
    one file = do
      src <- readFile file
      case format file src of
        Left err -> quoteSource err >>= hPutStrLn stderr >> pure False
        Right out
          | out == src -> pure True
          | checking -> putStrLn (file ++ ": not formatted") >> pure False
          | otherwise -> length src `seq` writeFile file out >> pure True

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
