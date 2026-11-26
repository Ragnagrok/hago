{-# LANGUAGE LambdaCase #-}
-- | The hago command line.
module Main (main) where

import Hago.Doc (documentLibrary)
import Hago.Driver (checkFile, compileFile, libraryInterfaces, quoteSource, searchPath)
import Hago.Format (format)
import Hago.Repl (repl)
import Control.Exception (finally)
import Data.List (isPrefixOf, nub)
import System.Directory (createDirectoryIfMissing, doesFileExist, findExecutable, getTemporaryDirectory, listDirectory, makeAbsolute, removeDirectoryRecursive, removeFile)
import System.Environment (getArgs)
import System.Exit
import System.FilePath (takeBaseName, takeDirectory, takeExtension, (<.>), (</>))
import System.IO
import System.Process (CreateProcess (..), getCurrentPid, proc, rawSystem, readProcessWithExitCode, waitForProcess, withCreateProcess)

usage :: String
usage = unlines
  [ "usage: hago build [-i DIR]... FILE.hgo [-o OUT.go]   compile to Go"
  , "       hago run [-i DIR]... FILE.hgo [ARGS...]       compile and run, with the arguments given"
  , "       hago check [-i DIR]... FILE.hgo               type check a program or a module, without making Go"
  , "       hago doc [-o DIR]                             write the standard library's reference (to docs/library)"
  , "       hago fmt [--check] FILE.hgo...                normalise whitespace in place, or say which files need it"
  , "       hago repl [-i DIR]... [FILE.hgo]              evaluate expressions as they are typed"
  , ""
  , "Modules are looked for next to FILE, then in each -i DIR, then in the directories"
  , "of HAGO_PATH (separated by ':'), then in the standard library. hago run builds"
  , "the program in the Go module of the nearest go.mod above FILE, if there is one;"
  , "a program that imports Go packages outside Go's standard library needs one." ]

main :: IO ()
main = getArgs >>= \args -> case args of
  "build" : rest | (dirs, [file]) <- includes rest -> withPath dirs $ \path -> build path file (takeBaseName file ++ ".go") >> pure ()
  "build" : rest | (dirs, [file, "-o", out]) <- includes rest -> withPath dirs $ \path -> build path file out >> pure ()
  "run" : rest | (dirs, file : progArgs) <- leadingIncludes rest, not ("-" `isPrefixOf` file) -> withPath dirs $ \path -> run path file progArgs
  "check" : rest | (dirs, [file]) <- includes rest -> withPath dirs $ \path -> checkFile path file >>= either (\err -> hPutStrLn stderr err >> exitFailure) pure
  ["doc"] -> doc ("docs" </> "library")
  ["doc", "-o", dir] -> doc dir
  "fmt" : "--check" : files@(_ : _) -> fmt True files
  "fmt" : files@(_ : _) -> fmt False files
  "repl" : rest | (dirs, file) <- includes rest, length file <= 1 -> withPath dirs $ \path -> repl path (case file of [f] -> Just f; _ -> Nothing)
  _ -> hPutStr stderr usage >> exitFailure
  where
    withPath dirs k = searchPath dirs >>= k

-- | The directories of every -i DIR, and the other arguments.
includes :: [String] -> ([FilePath], [String])
includes = \case
  "-i" : dir : rest -> let (dirs, others) = includes rest in (dir : dirs, others)
  a : rest -> let (dirs, others) = includes rest in (dirs, a : others)
  [] -> ([], [])

-- | The directories of the -i DIR before the first other argument, and the
-- arguments from it on: what follows a program is its own.
leadingIncludes :: [String] -> ([FilePath], [String])
leadingIncludes = \case
  "-i" : dir : rest -> let (dirs, others) = leadingIncludes rest in (dir : dirs, others)
  rest -> ([], rest)

-- | Compiles and runs a program. With a go.mod above it, the Go is built in
-- that module, in a directory of its own at the module's root, so that what
-- the go.mod requires and replaces holds; without one, in a temporary
-- directory, which only Go's standard library can be built in.
run :: [FilePath] -> FilePath -> [String] -> IO ()
run path file progArgs = do
  pid <- getCurrentPid
  modRoot <- makeAbsolute (takeDirectory file) >>= goModRoot
  dir <- case modRoot of
    Just root -> pure (root </> (".hago-run-" ++ show pid))
    Nothing -> (</> ("hago-run-" ++ show pid)) <$> getTemporaryDirectory
  let exe = dir </> takeBaseName file
  createDirectoryIfMissing True dir
  code <- (do
      out <- build path file (exe <.> "go")
      go <- readFile out
      case (modRoot, thirdParty go) of
        (Nothing, pkgs@(_ : _)) -> do
          hPutStr stderr $ unlines $
            [ file ++ " imports Go packages outside Go's standard library, so it needs a go.mod"
            , "next to it or above it, which says which versions to use:" ]
              ++ map ("  " ++) pkgs
              ++ [ "make one with, in " ++ takeDirectory file ++ ":"
                 , "  go mod init NAME"
                 , "  go get " ++ unwords pkgs ]
          pure (ExitFailure 1)
        _ -> do
          -- from the module's root, so that its go.mod is the one Go reads
          built <- withCreateProcess (proc "go" ["build", "-o", exe, out]) {cwd = modRoot} (\_ _ _ h -> waitForProcess h)
          case built of
            ExitSuccess -> rawSystem exe progArgs
            failure -> pure failure)
    `finally` removeDirectoryRecursive dir
  exitWith code

-- | The directory of the nearest go.mod at or above a directory.
goModRoot :: FilePath -> IO (Maybe FilePath)
goModRoot dir = do
  here <- doesFileExist (dir </> "go.mod")
  if here
    then pure (Just dir)
    else if takeDirectory dir == dir then pure Nothing else goModRoot (takeDirectory dir)

-- | The packages a Go file imports from outside Go's standard library, whose
-- paths start with a domain (github.com/...): a standard one's first part has
-- no dot.
thirdParty :: String -> [String]
thirdParty go = nub [p | l <- importLines, Just p <- [quoted l], '.' `elem` takeWhile (/= '/') p]
  where
    importLines = takeWhile (/= ")") (drop 1 (dropWhile (/= "import (") (map trimSpace (lines go))))
    trimSpace = reverse . dropWhile (== ' ') . reverse . dropWhile (`elem` " \t")
    quoted l = case dropWhile (/= '"') l of
      '"' : more | (p, "\"") <- break (== '"') more -> Just p
      _ -> Nothing

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

build :: [FilePath] -> FilePath -> FilePath -> IO FilePath
build path file out = do
  result <- compileFile path file
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
