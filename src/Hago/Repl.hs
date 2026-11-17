{-# LANGUAGE LambdaCase #-}

-- | hago repl: an expression typed at the prompt is compiled, with the
-- definitions made so far and the file loaded, into a small program that
-- prints it, and run with Go. Definitions are type checked when they are
-- made. With no terminal on standard input, every line read is echoed after
-- the prompt, so the output is a transcript: the book checks its sessions by
-- comparing that transcript with the text.
module Hago.Repl (repl) where

import Control.Exception (IOException, finally, try)
import Data.Char (isAlphaNum, isDigit, isSpace, toUpper)
import Data.List (intercalate, isPrefixOf, nub, sortOn, stripPrefix)
import qualified Data.Map as M
import Data.Maybe (fromMaybe)
import Hago.Core (ClassInfo (..), Pred (..), Scheme (..), Type (..))
import Hago.Driver (Virtual, checkProgram, generateProgram, quoteIn, quoteSource)
import Hago.Parser (parseModule)
import Hago.Syntax
import Hago.TcMonad (prettyAtom, pretty)
import Hago.Typecheck (Checked (..))
import System.Directory (createDirectoryIfMissing, getTemporaryDirectory, removeDirectoryRecursive)
import System.FilePath (takeBaseName, (</>))
import System.IO
import System.Process (CreateProcess (..), StdStream (..), createProcess, getCurrentPid, proc, waitForProcess)

-- | What a line typed at the prompt defined, kept as its text.
data Chunk = Chunk {chText :: String, chValues :: [Name], chTypes :: [Name]}

data Session = Session
  { sImports :: [String]
  , sLoaded :: Maybe FilePath
  , sTarget :: Maybe FilePath   -- ^ the file :reload loads, even if it failed to load
  , sChunks :: [Chunk]   -- ^ oldest first
  , sDir :: FilePath     -- ^ where the programs are written
  }

repl :: Maybe FilePath -> IO ()
repl file = do
  hSetBuffering stdout LineBuffering
  tty <- hIsTerminalDevice stdin
  tmp <- getTemporaryDirectory
  pid <- getCurrentPid
  let dir = tmp </> ("hago-repl-" ++ show pid)
  createDirectoryIfMissing True dir
  let s0 = Session [] Nothing Nothing [] dir
  (maybe (pure s0) (load s0) file >>= loop tty) `finally` removeDirectoryRecursive dir
  where
    -- with a terminal the prompt is shown; without one, the line read follows it
    loop tty s = readLine tty "hago> " >>= \case
      Nothing -> pure ()
      Just l -> do
        input <- if trim l == ":{" then block tty [] else pure (Just l)
        case input of
          Nothing -> pure ()
          Just i -> step s i >>= maybe (pure ()) (loop tty)
    block tty acc = readLine tty "hago| " >>= \case
      Nothing -> pure Nothing
      Just l
        | trim l == ":}" -> pure (Just (intercalate "\n" (reverse acc)))
        | otherwise -> block tty (l : acc)
    readLine tty prompt = do
      if tty then putStr prompt >> hFlush stdout else pure ()
      l <- next
      if tty then pure () else mapM_ (putStrLn . (prompt ++)) l
      pure l
    next = do
      eof <- isEOF
      if eof then pure Nothing else Just <$> getLine

-- | Runs what was typed; Nothing to quit.
step :: Session -> String -> IO (Maybe Session)
step s input = case words input of
  [] -> pure (Just s)
  (cmd : args)
    | cmd `elem` [":q", ":quit"] -> pure Nothing
    | cmd `elem` [":t", ":type"] -> Just s <$ typeOf s (dropCommand input)
    | cmd `elem` [":l", ":load"], [f] <- args -> Just <$> load s f
    | cmd `elem` [":r", ":reload"] -> Just <$> maybe (s <$ putStrLn "no file to reload") (load s) (sTarget s)
    | cmd `elem` [":?", ":help"] -> Just s <$ putStr help
    | ":" `isPrefixOf` cmd -> Just s <$ putStrLn ("unknown command " ++ cmd ++ ", :help lists them")
    | otherwise -> Just <$> entry s input
  where
    dropCommand = dropWhile isSpace . dropWhile (not . isSpace) . dropWhile isSpace

help :: String
help = unlines
  [ "  EXPR            evaluate and print EXPR (an IO action is run)"
  , "  NAME = EXPR     define (also data, class, instance, import...)"
  , "  :type EXPR      the type of EXPR"
  , "  :load FILE      load the definitions in FILE, forgetting those typed here"
  , "  :reload         load the same file again"
  , "  :{ ... :}       a definition or expression on several lines"
  , "  :quit" ]

-- | Loads a file: the definitions typed so far are forgotten, as the file's
-- may need the same names.
load :: Session -> FilePath -> IO Session
load s f = do
  let s' = s {sLoaded = Just f, sTarget = Just f, sChunks = []}
  r <- checkSession s' []
  case r of
    Left err -> do
      putStrLn =<< report s' 0 0 "" err
      pure s {sLoaded = Nothing, sTarget = Just f, sChunks = []}
    Right _ -> s' <$ putStrLn ("loaded " ++ f)

-- | The prompt's module: its imports, the loaded file's, an import of the
-- loaded file without what the prompt redefined, the definitions typed,
-- then the lines given. A module Main of its own runs it.
sessionSource :: Session -> Maybe (Name, Module) -> [String] -> String
sessionSource s loaded extra =
  unlines (["module Interactive where"] ++ sImports s ++ loadedImports ++ concatMap (lines . chText) (sChunks s) ++ extra)
  where
    defined = concatMap chValues (sChunks s)
    loadedImports = case loaded of
      Nothing -> []
      Just (name, m) ->
        map renderImport (modImports m)
          ++ ["import " ++ name ++ hiding [n | n <- "it" : defined, n `elem` topValues m]]
    hiding [] = ""
    hiding ns = " hiding (" ++ intercalate ", " (map item ns) ++ ")"
    item n = if isOperatorName n then "(" ++ n ++ ")" else n

-- | The line the next line given to sessionSource is on.
extraLine :: Session -> Maybe (Name, Module) -> Int
extraLine s loaded = length (lines (sessionSource s loaded [])) + 1

renderImport :: Import -> String
renderImport i =
  "import " ++ (if impQualified i then "qualified " else "") ++ impModule i
    ++ maybe "" (" as " ++) (impAs i)
    ++ maybe "" (\items -> " (" ++ intercalate ", " (map renderItem items) ++ ")") (impOnly i)
    ++ (if null (impHiding i) then "" else " hiding (" ++ intercalate ", " (map renderItem (impHiding i)) ++ ")")
  where
    renderItem = \case
      IVar n -> if isOperatorName n then "(" ++ n ++ ")" else n
      IType n SubNone -> n
      IType n SubAll -> n ++ " (..)"
      IType n (SubSome ns) -> n ++ " (" ++ intercalate ", " ns ++ ")"
      IModule n -> "module " ++ n

isOperatorName :: Name -> Bool
isOperatorName n = case n of
  c : _ -> not (isAlphaNum c || c == '_')
  [] -> False

-- | The loaded file, parsed, and the name it is imported by.
loadedModule :: Session -> IO (Either String (Maybe (Name, FilePath, String, Module)))
loadedModule s = case sLoaded s of
  Nothing -> pure (Right Nothing)
  Just f -> do
    r <- try (readFile f) :: IO (Either IOException String)
    case r of
      Left _ -> pure (Left ("cannot read " ++ f))
      Right src -> case parseModule f src of
        Left e -> pure (Left e)
        Right m -> pure (Right (Just (moduleNameFor f m, f, src, m)))
  where
    moduleNameFor f m
      | modName m /= "Main" = modName m
      | (c : cs) <- filter (\x -> isAlphaNum x || x == '_') (takeBaseName f), not (isDigit c), toUpper c : cs `notElem` ["Main", "Interactive"] = toUpper c : cs
      | otherwise = "Loaded"

-- | Type checks the session with the lines given at the end, returning the
-- main module's types, everything the program's modules give, and the
-- virtual modules.
checkSession :: Session -> [String] -> IO (Either String (Checked, Checked, Virtual))
checkSession s extra = runSession s extra []

-- | checkSession, with the lines of the module Main that runs the session.
runSession :: Session -> [String] -> [String] -> IO (Either String (Checked, Checked, Virtual))
runSession s extra runner = do
  lm <- loadedModule s
  case lm of
    Left e -> pure (Left e)
    Right loaded -> do
      let named = fmap (\(n, _, _, m) -> (n, m)) loaded
          src = sessionSource s named extra
          mainSrc = unlines (["import Interactive"] ++ if null runner then ["main :: IO ()", "main = pure ()"] else runner)
          virtual = M.fromList
            ([("Main", ("<main>", mainSrc)), ("Interactive", ("<interactive>", src))]
              ++ [(n, (f, text)) | Just (n, f, text, _) <- [loaded]])
      r <- checkProgram virtual "<main>"
      pure $ case r of
        Left e -> Left e
        Right mods -> Right (fromMaybe mempty (lookup "Interactive" mods), mconcat (map snd mods), virtual)

-- | An expression to print, or definitions to keep.
entry :: Session -> String -> IO Session
entry s input = case parseModule "<interactive>" (expressionLines input) of
  Right _ -> s <$ evaluate s input
  Left exprErr -> case parseModule "<interactive>" body of
    Right m | not (null (modImports m)) && null (modDecls m) -> do
      let s' = s {sImports = sImports s ++ map renderImport (modImports m)}
      r <- checkSession s' []
      either (\e -> s <$ (putStrLn =<< report s 0 0 "" e)) (const (pure s')) r
    Right m | null (modImports m) -> define s body offset m
    Right _ -> s <$ putStrLn "<interactive>: an import goes on a line of its own"
    Left declErr
      | looksLikeDefinition -> s <$ (putStrLn =<< report s 1 offset body declErr)
      | otherwise -> s <$ (putStrLn =<< report s 1 5 input exprErr)
  where
    (body, offset) = maybe (input, 0) (\b -> (b, 4)) (stripPrefix "let " input)
    looksLikeDefinition =
      offset > 0
        || take 1 (words input) `elem` map pure ["data", "newtype", "type", "class", "instance", "import", "infix", "infixl", "infixr", "foreign"]
        || any isBinding (tokensOf input)
    isBinding t = t == "="
    tokensOf = words . map (\c -> if isAlphaNum c || c `elem` "\"'()[]," then ' ' else c)

-- | it = EXPR, with the lines after the first indented to keep the layout.
expressionLines :: String -> String
expressionLines input = case lines input of
  [] -> "it = ()"
  l : ls -> intercalate "\n" (("it = " ++ l) : map ("     " ++) ls)

define :: Session -> String -> Int -> Module -> IO Session
define s body offset m = do
  let chunk = Chunk body (concatMap declValues (modDecls m)) (concatMap declTypes (modDecls m))
      keep c = null (chValues c `common` chValues chunk) && null (chTypes c `common` chTypes chunk)
      common a b = filter (`elem` b) a
      s' = s {sChunks = filter keep (sChunks s) ++ [chunk]}
  r <- checkSession s' []
  case r of
    Left err -> do
      end <- endLine s'
      s <$ (putStrLn =<< report s (end - length (lines body)) offset body err)
    Right _ -> pure s'

-- | The line after the session's module, where an expression goes.
endLine :: Session -> IO Int
endLine s = do
  lm <- loadedModule s
  pure (extraLine s (either (const Nothing) (fmap (\(n, _, _, m) -> (n, m))) lm))

-- | The names a declaration defines, so that defining one again replaces it.
declValues :: Decl -> [Name]
declValues = \case
  DBind n _ -> [n]
  DSig ns _ _ -> ns
  DData d -> [c | ConDecl c _ _ <- ddCons d] ++ concat [fs | ConDecl _ _ fs <- ddCons d]
  DClass _ _ _ _ ds -> concatMap declValues ds
  DForeign _ n _ -> [n]
  _ -> []

declTypes :: Decl -> [Name]
declTypes = \case
  DData d -> [ddName d]
  DType n _ _ -> [n]
  DClass _ n _ _ _ -> [n]
  _ -> []

topValues :: Module -> [Name]
topValues m = nub (concatMap declValues (modDecls m))

-- | Prints the value of an expression, or runs it if it is an action.
evaluate :: Session -> String -> IO ()
evaluate s input = do
  r <- checkSession s expr
  case r of
    Left err -> putStrLn =<< reportExpr err
    Right (ck, _, _) -> case schemeOf ck of
      Nothing -> putStrLn "hago: the expression's type was lost (a bug in hago)"
      Just (Forall _ _ t) -> tryMains $ case t of
        TCon "IO" [TCon "()" []] -> [["main = it"]]
        TCon "IO" [_] -> [["main = it >>= print"], ["main = it >> pure ()"]]
        -- an action in any monad, as pure 3 is, is run in IO
        TApp (TVar _) (TCon "()" []) -> [["main = inIO it"] ++ inIO]
        TApp (TVar _) _ -> [["main = inIO it >>= print"] ++ inIO, ["main = inIO it >> pure ()"] ++ inIO]
        _ -> [["main = print it"]]
  where
    expr = lines (expressionLines input)
    inIO = ["inIO :: IO a -> IO a", "inIO x = x"]
    reportExpr err = do
      line0 <- endLine s
      report s line0 5 input err
    -- An error in the program that runs it is about the whole expression,
    -- since it is generalised; the same use written in the prompt's module,
    -- where nothing is generalised, finds the place in what was typed.
    locate (m : helpers) err
      | [_] <- lines input
      , Just body <- stripPrefix "main = " m
      , (before, ' ' : 'i' : 't' : after) <- breakOnIt body = do
          let use = "hagoMain = " ++ before ++ " (" ++ input ++ ")" ++ after
          line0 <- endLine s
          r <- checkSession s (use : helpers)
          let before' = length use - length input - length after - 1
          pure $ case r of
            Left err' | atLine line0 err', Just c <- column err', c > before', c <= before' + length input ->
              shift before' err'
            _ -> err
    locate _ err = pure err
    breakOnIt body = case [i | i <- [0 .. length body - 3], take 3 (drop i body) == " it", take 1 (drop (i + 3) body) `elem` ["", " "]] of
      i : _ -> splitAt i body
      [] -> (body, "")
    column e = case break (== ':') e of
      (_, ':' : more) | (_, ':' : more') <- span isDigit more, (c, _) <- span isDigit more', not (null c) -> Just (read c :: Int)
      _ -> Nothing
    atLine l e = (":" ++ show l ++ ":") `isPrefixOf` dropWhile (/= ':') e && "<interactive>" `isPrefixOf` e
    -- report takes off the 5 columns of "it = "; this line has more before the input
    shift n e = case break (== ':') e of
      (path, ':' : more) | (l, ':' : more') <- span isDigit more, (c, rest) <- span isDigit more', not (null c) ->
        path ++ ":" ++ l ++ ":" ++ show (read c - n + 5) ++ rest
      _ -> e
    -- the first main that type checks; one that prints, if the value can be shown
    tryMains [] = pure ()
    tryMains (m : ms) = do
      r <- runSession s expr m
      case r of
        Left err
          | not (null ms) -> tryMains ms
          | otherwise -> putStrLn =<< (locate m err >>= reportExpr)
        Right (_, _, virtual) -> do
          checked <- checkProgram virtual "<main>"
          case checked >>= generateProgram "<main>" of
            Left err -> putStrLn =<< reportExpr err
            Right go -> do
              let path = sDir s </> "main.go"
              writeFile path go
              hFlush stdout
              runGo path

-- | Runs the program with what it prints going straight out, and what Go
-- says about a failure cut to its first line: a stack overflow comes with a
-- trace of millions of frames.
runGo :: FilePath -> IO ()
runGo path = do
  (_, _, Just err, ph) <- createProcess (proc "go" ["run", path]) {std_err = CreatePipe}
  said <- hGetContents err
  let kept = case [rest | l <- lines said, Just rest <- [stripPrefix "fatal error: " l]] of
        reason : _ -> ["error: " ++ reason]
        [] -> takeWhile (not . trace) [l | l <- lines said, not ("exit status " `isPrefixOf` l)]
      trace l = "goroutine " `isPrefixOf` l || "runtime stack:" `isPrefixOf` l
  mapM_ (hPutStrLn stdout) (reverse (dropWhile null (reverse kept)))
  _ <- waitForProcess ph
  pure ()

schemeOf :: Checked -> Maybe Scheme
schemeOf ck = M.lookup "Interactive.it" (ckVars ck)

typeOf :: Session -> String -> IO ()
typeOf s input = do
  r <- checkSession s (lines (expressionLines input))
  case r of
    Left err -> do
      line0 <- endLine s
      putStrLn =<< report s line0 5 input err
    Right (ck, everything, _) -> case schemeOf ck of
      Nothing -> putStrLn "hago: the expression's type was lost (a bug in hago)"
      Just sc -> putStrLn (trim input ++ " :: " ++ prettyScheme (ckClasses everything) sc)

-- | A type with its constraints, as GHCi shows it: variables renamed in
-- the order they appear, a, b, c... for types and f, g, h... for type
-- constructors (m for a monad), and no constraint a superclass of another.
prettyScheme :: M.Map Name ClassInfo -> Scheme -> String
prettyScheme classes (Forall _ ps t) = context ++ pretty (rename t)
  where
    order = nub (varsOf t ++ concat [concatMap varsOf ts | IsIn _ ts <- ps])
    applied = nub (heads t ++ concat [concatMap heads ts | IsIn _ ts <- ps])
    monads = [v | IsIn c [TVar v] <- ps, unqual c == "Monad"]
    names = M.fromList (pick order [] )
    pick [] _ = []
    pick (v : vs) used =
      let pool
            | v `elem` monads = ["m", "n"] ++ constructorNames
            | v `elem` applied = constructorNames
            | otherwise = map pure ['a' .. 'e'] ++ ["a" ++ show i | i <- [1 :: Int ..]]
          name = head' [x | x <- pool, x `notElem` used]
       in (v, name) : pick vs (name : used)
    constructorNames = ["f", "g", "h"] ++ ["f" ++ show i | i <- [1 :: Int ..]]
    head' xs = case xs of
      x : _ -> x
      [] -> "t"
    rename = \case
      TVar v -> TVar (M.findWithDefault v v names)
      TCon c ts -> TCon c (map rename ts)
      TFun a b -> TFun (rename a) (rename b)
      TApp f x -> TApp (rename f) (rename x)
      other -> other
    varsOf = \case
      TVar v -> [v]
      TCon _ ts -> concatMap varsOf ts
      TFun a b -> varsOf a ++ varsOf b
      TApp f x -> varsOf f ++ varsOf x
      _ -> []
    heads = \case
      TApp (TVar v) x -> v : heads x
      TApp f x -> heads f ++ heads x
      TCon _ ts -> concatMap heads ts
      TFun a b -> heads a ++ heads b
      _ -> []
    -- the classes a class implies, itself not included
    supers c = case M.lookup c classes of
      Nothing -> []
      Just ci -> let direct = [d | IsIn d _ <- clsSupers ci] in direct ++ concatMap supers direct
    implied (IsIn c ts) = or [c `elem` supers d | IsIn d ts' <- ps, ts' == ts, d /= c]
    position (IsIn _ ts) = case concatMap varsOf ts of
      v : _ -> length (takeWhile (/= v) order)
      [] -> 0
    kept = sortOn position (nub (filter (not . implied) ps))
    preds = [unqual c ++ " " ++ unwords (map (prettyAtom . rename) ts) | IsIn c ts <- kept]
    context = case preds of
      [] -> ""
      [p] -> p ++ " => "
      _ -> "(" ++ intercalate ", " preds ++ ") => "

-- | An error, with a place in the prompt's module moved to the place in what
-- was typed: line l of the module is the input's first line, whose text
-- starts at column offset + 1.
report :: Session -> Int -> Int -> String -> String -> IO String
report _ start offset input err = case location err of
  Just ("<interactive>", l, c, rest)
    | start > 0, l >= start, l < start + length (lines input) ->
        let l' = l - start + 1
            c' = if l' == 1 then max 1 (c - offset) else max 1 (c - (if offset == 5 then 5 else 0))
         in pure (quoteIn input ("<interactive>:" ++ show l' ++ ":" ++ show c' ++ ":" ++ clean rest))
    | otherwise -> pure ("<interactive>:" ++ clean rest)
  -- the program that runs it: what it cannot do with the value
  Just ("<main>", _, _, rest) -> pure ("<interactive>:" ++ fromMaybe rest (stripPrefix " in main:" rest))
  Just _ -> quoteSource err
  Nothing -> pure (clean' err)
  where
    clean r = fromMaybe r (stripPrefix " in it:" r)
    clean' e = fromMaybe e (stripPrefix "<interactive>: in it:" e >>= Just . ("<interactive>:" ++))
    location e = case break (== ':') e of
      (path, ':' : more)
        | (l, ':' : more') <- span isDigit more
        , (c, ':' : rest) <- span isDigit more'
        , not (null l), not (null c) -> Just (path, read l, read c, rest)
      _ -> Nothing

trim :: String -> String
trim = dropWhile isSpace . reverse . dropWhile isSpace . reverse
