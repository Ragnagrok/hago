{-# LANGUAGE TemplateHaskell #-}

-- | From a source file to Go source: loading modules, renaming, type
-- synonyms, deriving, type checking, specialisation, newtype erasure, code
-- generation.
module Hago.Driver (Virtual, compileFile, checkFile, checkProgram, checkProgramExports, generateProgram, quoteSource, quoteIn, libraryInterfaces) where

import Control.Applicative ((<|>))
import Control.Monad (foldM)
import Data.Char (isAlphaNum, isDigit)
import Data.List (intercalate, isPrefixOf, stripPrefix)
import qualified Data.Map as M
import qualified Data.Set as S
import Hago.CodeGen (Runtime (..), RuntimePart (..), generate)
import Hago.Derive (expandDeriving)
import Hago.Embed (embedFile)
import Hago.Expand (expandSynonyms, synonymsOf)
import Hago.Inline (inlineSmall)
import Hago.Lift (liftLocals)
import Hago.Newtype (eraseNewtypes)
import Hago.Parser (fixitiesOf, parseModule, resolveFixity)
import Hago.Cache
import Hago.Rename (Renamed (..), renameModule)
import Hago.Sink (sinkLocals)
import Hago.Specialize (specialize)
import Hago.Syntax
import Hago.Typecheck (Checked (..), programOf, typecheckModule)
import System.Directory (doesFileExist)
import System.FilePath (joinPath, splitDirectories, takeDirectory, takeFileName, (<.>), (</>))

preludeSource :: String
preludeSource = $(embedFile "prelude/Prelude.hgo")

-- | The standard library, compiled into hago: a program's own module of the
-- same name comes first.
libraryModules :: M.Map Name String
libraryModules = M.fromList
  [ ("Data.Functor.Identity", $(embedFile "lib/Data/Functor/Identity.hgo"))
  , ("Control.Monad", $(embedFile "lib/Control/Monad.hgo"))
  , ("Control.Monad.Trans", $(embedFile "lib/Control/Monad/Trans.hgo"))
  , ("Control.Monad.State", $(embedFile "lib/Control/Monad/State.hgo"))
  , ("Control.Monad.Except", $(embedFile "lib/Control/Monad/Except.hgo"))
  , ("Control.Monad.Reader", $(embedFile "lib/Control/Monad/Reader.hgo"))
  , ("Control.Monad.Writer", $(embedFile "lib/Control/Monad/Writer.hgo"))
  , ("System.Environment", $(embedFile "lib/System/Environment.hgo"))
  , ("System.IO", $(embedFile "lib/System/IO.hgo"))
  , ("System.Exit", $(embedFile "lib/System/Exit.hgo"))
  , ("System.Random", $(embedFile "lib/System/Random.hgo"))
  , ("Control.Concurrent", $(embedFile "lib/Control/Concurrent.hgo"))
  , ("Control.Concurrent.Channel", $(embedFile "lib/Control/Concurrent/Channel.hgo"))
  , ("Control.Concurrent.Async", $(embedFile "lib/Control/Concurrent/Async.hgo"))
  , ("Control.Parallel", $(embedFile "lib/Control/Parallel.hgo"))
  , ("Data.Vector", $(embedFile "lib/Data/Vector.hgo"))
  , ("Data.Iter", $(embedFile "lib/Data/Iter.hgo"))
  , ("Data.Ratio", $(embedFile "lib/Data/Ratio.hgo"))
  , ("Data.Time", $(embedFile "lib/Data/Time.hgo"))
  , ("Text.Regex", $(embedFile "lib/Text/Regex.hgo"))
  , ("Data.String.Builder", $(embedFile "lib/Data/String/Builder.hgo"))
  , ("Crypto.Hash", $(embedFile "lib/Crypto/Hash.hgo"))
  , ("Data.Encoding", $(embedFile "lib/Data/Encoding.hgo"))
  , ("System.Process", $(embedFile "lib/System/Process.hgo"))
  , ("Network.HTTP", $(embedFile "lib/Network/HTTP.hgo"))
  , ("Data.String", $(embedFile "lib/Data/String.hgo"))
  , ("Data.Char", $(embedFile "lib/Data/Char.hgo"))
  , ("Data.Monoid", $(embedFile "lib/Data/Monoid.hgo"))
  , ("Control.Applicative", $(embedFile "lib/Control/Applicative.hgo"))
  , ("Data.Ord", $(embedFile "lib/Data/Ord.hgo"))
  , ("Data.List", $(embedFile "lib/Data/List.hgo"))
  , ("Data.Map", $(embedFile "lib/Data/Map.hgo"))
  , ("Data.Set", $(embedFile "lib/Data/Set.hgo"))
  , ("Control.Monad.ST.Unsafe", $(embedFile "lib/Control/Monad/ST/Unsafe.hgo"))
  , ("Control.Monad.ST", $(embedFile "lib/Control/Monad/ST.hgo"))
  , ("Data.IORef", $(embedFile "lib/Data/IORef.hgo"))
  , ("Data.STRef", $(embedFile "lib/Data/STRef.hgo"))
  , ("Data.Vector.Mutable", $(embedFile "lib/Data/Vector/Mutable.hgo"))
  , ("Data.HashTable", $(embedFile "lib/Data/HashTable.hgo")) ]

-- | The runtime copied into every program: runtime.go, and the thunks of
-- thunk_sequential.go, or concurrent.go for a program that starts goroutines.
runtimeSource :: Bool -> String
runtimeSource concurrent = body shared ++ body (if concurrent then conc else seqThunks)
  where
    body raw = unlines (drop 1 (dropWhile (not . ("// --- runtime ---" `isPrefixOf`)) (lines raw)))
    shared = $(embedFile "runtime/runtime.go")
    seqThunks = $(embedFile "runtime/thunk_sequential.go")
    conc = concurrentRuntime

concurrentRuntime :: String
concurrentRuntime = $(embedFile "runtime/concurrent.go")

-- | The runtime, with the parts a program gets only if it uses them.
runtime :: Runtime
runtime = Runtime
  { rtCore = runtimeSource
  , rtConcurrentSymbols = definedIn concurrentRuntime
  , rtParts = map part
      [ $(embedFile "runtime/lib_codec.go")
      , $(embedFile "runtime/lib_process.go")
      , $(embedFile "runtime/lib_http.go")
      , $(embedFile "runtime/lib_mutable.go") ]
  }
  where
    part src = RuntimePart (afterMarker src) (definedIn src) (importsOf src)
    afterMarker src = unlines (drop 1 (dropWhile (not . ("// --- runtime ---" `isPrefixOf`)) (lines src)))
    -- the lines of the import block, as "rt_http \"net/http\""
    importsOf src =
      [ unwords (words l) | l <- takeWhile (/= ")") (drop 1 (dropWhile (/= "import (") (lines src))) ]

-- | The functions and types a part of the runtime defines.
definedIn :: String -> [String]
definedIn src =
  [ takeWhile (\c -> isAlphaNum c || c == '_') rest
  | l <- lines src
  , Just rest <- [fmap ("rt_" ++) (stripPrefix "func rt_" l <|> stripPrefix "type rt_" l)] ]

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

-- | Modules given as text instead of files, by name: the path their errors
-- name, and their source. A program's main module can be one of them.
type Virtual = M.Map Name (FilePath, String)

compileFile :: FilePath -> IO (Either String String)
compileFile file = do
  checked <- checkProgram M.empty file
  either (fmap Left . quoteSource) (pure . Right) (checked >>= generateProgram file)

-- | Every module of the program, type checked, dependencies first, with the
-- Prelude. Errors are not quoted yet.
checkProgram :: Virtual -> FilePath -> IO (Either String [(Name, Checked)])
checkProgram virtual file = fmap (\(mods, _, _) -> mods) <$> checkProgramExports virtual file

-- | checkProgram, also giving what each module exports, and the type
-- synonyms, by internal name.
checkProgramExports :: Virtual -> FilePath -> IO (Either String ([(Name, Checked)], Renamed, M.Map Name ([Name], SType)))
checkProgramExports virtual file = checkUnitsExports ("Prelude.hgo", preludeSource) virtual "Main" (takeDirectory file) file

-- | The Prelude, at the path its errors name, with the modules loaded from
-- a root, starting from the named one.
checkUnits :: (FilePath, String) -> Virtual -> Name -> FilePath -> FilePath -> IO (Either String [(Name, Checked)])
checkUnits prelude virtual name root file = fmap (\(mods, _, _) -> mods) <$> checkUnitsExports prelude virtual name root file

-- | checkUnits, also giving what each module exports, and the type synonyms.
checkUnitsExports
  :: (FilePath, String) -> Virtual -> Name -> FilePath -> FilePath
  -> IO (Either String ([(Name, Checked)], Renamed, M.Map Name ([Name], SType)))
checkUnitsExports (preludePath, prelude) virtual name root file = do
  loaded <- loadAll virtual name root file
  stamp <- compilerStamp
  cache <- cacheDirectory
  let preludeUnit = Unit preludePath "Prelude" (prelude ++ tupleInstances) Nothing
  result <- case loaded of
    Left e -> pure (Left e)
    Right mods -> compileUnits stamp cache (preludeUnit : [Unit path (modName m) src (Just m) | (path, src, m) <- mods])
  pure ((\ifaces -> (map (fmap ifChecked) ifaces, mconcat (map (ifRenamed . snd) ifaces), M.unions (map (ifSynonyms . snd) ifaces))) <$> result)

-- | Type checks a file and the modules it imports, without generating Go.
-- The file is a program, one of its modules (whose imports are looked for
-- from the directory its name implies: Data/Json.hgo's are next to Data/),
-- a module of the standard library, or the Prelude (a file named
-- Prelude.hgo without a module header). Errors are quoted.
checkFile :: FilePath -> IO (Either String ())
checkFile file = do
  src <- readFile file
  result <- case parseModule file src of
    Left e -> pure (Left e)
    Right m -> case modName m of
      -- the Prelude has no header
      "Main" | takeFileName file == "Prelude.hgo" -> fmap (const ()) <$> checkUnits (file, src) M.empty "Prelude" (takeDirectory file) file
      "Main" -> checkProgram M.empty file >>= pure . (>>= duplicateInstances file . map snd)
      name -> fmap (const ()) <$> checkUnits ("Prelude.hgo", preludeSource) M.empty name (rootOf name) file
  either (fmap Left . quoteSource) (pure . Right) result
  where
    -- the directory A.B's imports are under, if the file is at <root>/A/B.hgo
    rootOf name =
      let parts = splitOn name
          dirs = splitDirectories (takeDirectory file)
          depth = length parts - 1
       in if depth > 0 && drop (length dirs - depth) dirs == init parts
            then (if length dirs == depth then "." else joinPath (take (length dirs - depth) dirs))
            else takeDirectory file
    splitOn n = case break (== '.') n of
      (a, '.' : rest) -> a : splitOn rest
      (a, _) -> [a]

-- | The Prelude and every module of the standard library, as compiled into
-- hago, dependencies first: each module's name, file, source, and what it
-- gives. For hago doc.
libraryInterfaces :: IO (Either String [(Name, FilePath, String, Iface)])
libraryInterfaces = do
  let path n = "lib" </> moduleFile n
      importer = unlines (["module Main where"] ++ ["import " ++ n ++ " ()" | n <- M.keys libraryModules] ++ ["main :: IO ()", "main = pure ()"])
      virtual = M.insert "Main" ("<library>", importer) (M.mapWithKey (\n src -> (path n, src)) libraryModules)
  loaded <- loadAll virtual "Main" "." "<library>"
  stamp <- compilerStamp
  cache <- cacheDirectory
  case loaded of
    Left e -> pure (Left e)
    Right mods -> do
      let mods' = [(p, modName m, src, m) | (p, src, m) <- mods, modName m /= "Main"]
          units = Unit "Prelude.hgo" "Prelude" (preludeSource ++ tupleInstances) Nothing : [Unit p n src (Just m) | (p, n, src, m) <- mods']
          sources = M.fromList (("Prelude", ("prelude/Prelude.hgo", preludeSource)) : [(n, (p, src)) | (p, n, src, _) <- mods'])
      result <- compileUnits stamp cache units
      pure (fmap (\done -> [(n, p, src, iface) | (n, iface) <- done, Just (p, src) <- [M.lookup n sources]]) result)

-- | Two modules that do not import each other can still give the same
-- instance, which only the whole program sees.
duplicateInstances :: FilePath -> [Checked] -> Either String ()
duplicateInstances file checked =
  case [(c, k) | ((c, k), n) <- M.toList (M.fromListWith (+) [(key, 1 :: Int) | ck <- checked, key <- M.keys (ckInsts ck)]), n > 1] of
    (c, k) : _ -> Left (file ++ ": two modules define the instance " ++ c ++ " " ++ k)
    [] -> pure ()

generateProgram :: FilePath -> [(Name, Checked)] -> Either String String
generateProgram file modules = do
  let checked = map snd modules
  duplicateInstances file checked
  prog <- either (Left . ((file ++ ": ") ++)) Right (specialize (sinkLocals (programOf (mconcat checked))))
  pure (generate runtime (liftLocals (inlineSmall (eraseNewtypes prog))))

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
      kept <- if "<" `isPrefixOf` path then pure Nothing else maybe (pure Nothing) (\dir -> readIface dir name key) cache
      r <- case kept of
        Just iface -> pure (Right iface)
        Nothing -> case maybe (parseModule path src) Right parsed of
          Left e -> pure (Left e)
          Right m -> case compileModule before (path, m {modName = name}) of
            Left e -> pure (Left e)
            Right iface -> do
              -- the prompt's module changes with every line
              mapM_ (\dir -> writeIface dir name key iface) (if "<" `isPrefixOf` path then Nothing else cache)
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
  Just (path, _, _) -> do
    exists <- doesFileExist path
    src <- if exists then readFile path else pure ""
    pure (quoteIn src err)

-- | quoteSource, given the source of the file the error is in.
quoteIn :: String -> String -> String
quoteIn src err = case location err of
  Nothing -> err
  Just (_, l, c) -> case drop (l - 1) (lines src) of
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

location :: String -> Maybe (FilePath, Int, Int)
location s = case break (== ':') s of
      (path, ':' : more) | not (null path), (l, ':' : more') <- span isDigit more, (c, ':' : _) <- span isDigit more', not (null l), not (null c) ->
        Just (path, read l, read c)
      _ -> Nothing

-- | The first module and everything it imports, dependencies first. A module
-- A.B lives in root/A/B.hgo (the root is the main file's directory), or in the
-- standard library.
loadAll :: Virtual -> Name -> FilePath -> FilePath -> IO (Either String [(FilePath, String, Module)])
loadAll virtual first root firstFile
  | first == "Prelude" = pure (Right [])
  | otherwise = do
      r <- load [] (Right (M.empty, [])) (first, firstFile, Nothing)
      pure (fmap (reverse . snd) r)
  where
    load stack acc (name, path, from) = case acc of
      Left e -> pure (Left e)
      Right (seen, done)
        | M.member name seen -> pure acc
        | name `elem` stack -> pure (Left ("import cycle: " ++ intercalate " -> " (reverse (name : stack))))
        | otherwise -> do
            exists <- doesFileExist path
            found <- case (M.lookup name virtual, exists, M.lookup name libraryModules) of
              (Just v, _, _) -> pure (Just v)
              (_, True, _) -> Just . (,) path <$> readFile path
              (_, False, Just src) -> pure (Just ("lib" </> moduleFile name, src))
              _ -> pure Nothing
            case found of
              Nothing -> pure (Left (maybe "" ((++ ": ") . showLoc) from ++ "cannot find module " ++ name ++ " (looked for " ++ path ++ ")"))
              Just (path', src) ->
                case parseModule path' src of
                  Left e -> pure (Left e)
                  Right m
                    | modName m /= name, not (M.member name virtual) ->
                        pure (Left (path' ++ ": declares module " ++ modName m ++ ", but should be " ++ name))
                    | otherwise -> do
                        let deps = [(impModule i, root </> moduleFile (impModule i), Just (impLoc i)) | i <- modImports m, impModule i /= "Prelude"]
                        r <- foldM (load (name : stack)) (Right (seen, done)) deps
                        pure (fmap (\(seen', done') -> (M.insert name () seen', (path', src, m {modName = name}) : done')) r)

-- | The file module A.B lives in: A/B.hgo.
moduleFile :: Name -> FilePath
moduleFile n = map (\c -> if c == '.' then '/' else c) n <.> "hgo"
