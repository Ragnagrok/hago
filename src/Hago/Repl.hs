{-# LANGUAGE LambdaCase #-}

-- | hago repl: an expression typed at the prompt is compiled, with the
-- definitions made so far and the file loaded, into a small program that
-- prints it, and run with Go. Definitions are type checked when they are
-- made. With no terminal on standard input, every line read is echoed after
-- the prompt, so the output is a transcript: the book checks its sessions by
-- comparing that transcript with the text.
module Hago.Repl (repl) where

import Control.Exception (IOException, finally, try)
import Control.Monad (void)
import Data.Char (isAlphaNum, isDigit, isSpace, toUpper)
import Data.List (intercalate, isPrefixOf, nub, sortOn, stripPrefix)
import qualified Data.Map as M
import Data.Maybe (fromMaybe, isJust)
import Hago.Core (ClassInfo (..), ConInfo (..), DataInfo (..), InstInfo (..), Pred (..), Scheme (..), Type (..))
import Hago.Driver (Virtual, checkProgram, checkProgramExports, generateProgram, quoteIn, quoteSource)
import Hago.Parser (parseModule)
import Hago.Rename (Renamed (..), Table (..))
import Hago.Syntax
import Hago.TcMonad (prettyAtom, pretty)
import Hago.Typecheck (Checked (..))
import System.Directory (createDirectoryIfMissing, getTemporaryDirectory, removeDirectoryRecursive, removeFile)
import System.FilePath (takeBaseName, (</>))
import System.IO
import System.Exit (ExitCode (..))
import System.Process (CreateProcess (..), StdStream (..), createProcess, getCurrentPid, proc, waitForProcess)

-- | What a line typed at the prompt defined, kept as its text, and the types
-- a value kept from an action has (it is forgotten when one is defined again).
data Chunk = Chunk {chText :: String, chValues :: [Name], chTypes :: [Name], chUses :: [Name]}

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
    | cmd `elem` [":k", ":kind"] -> Just s <$ kindOf s (dropCommand input)
    | cmd `elem` [":i", ":info"], [n] <- args -> Just s <$ info s n
    | cmd `elem` [":i", ":info"] -> Just s <$ putStrLn "<interactive>: :info takes a name, as in :info Maybe"
    | cmd `elem` [":b", ":browse"], [m] <- args -> Just s <$ browse s m
    | cmd `elem` [":b", ":browse"] -> Just s <$ putStrLn "<interactive>: :browse takes a module, as in :browse Data.Map"
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
  , "  PAT <- ACTION   run ACTION once and keep what PAT binds (if it has Show and Read)"
  , "  :type EXPR      the type of EXPR"
  , "  :kind TYPE      the kind of a type, or of a class"
  , "  :info NAME      what NAME is: its type, or its definition and instances"
  , "  :browse MODULE  what MODULE exports, with types"
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
          ++ ["import " ++ name ++ hiding [n | n <- "it" : defined, n `elem` values]]
          -- the file's own names come before the Prelude's, as they do in the file
          ++ ["import Prelude" ++ hiding values | not (null values)]
        where
          -- constructors are hidden with their types, which a file rarely shares
          values = filter (not . isConName) (topValues m)
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
  r <- sessionExports s extra runner
  pure (fmap (\(ck, everything, _, _, virtual) -> (ck, everything, virtual)) r)

-- | runSession, also giving what each module exports and the type synonyms.
sessionExports :: Session -> [String] -> [String] -> IO (Either String (Checked, Checked, Renamed, M.Map Name ([Name], SType), Virtual))
sessionExports s extra runner = do
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
      r <- checkProgramExports virtual "<main>"
      pure $ case r of
        Left e -> Left e
        Right (mods, rn, syns) -> Right (fromMaybe mempty (lookup "Interactive" mods), mconcat (map snd mods), rn, syns, virtual)

-- | An expression to print, or definitions to keep.
entry :: Session -> String -> IO Session
entry s input = case parseModule "<interactive>" (expressionLines input) of
  Right _ -> s <$ evaluateExpr s input
  Left exprErr -> case parseModule "<interactive>" body of
    Right m | not (null (modImports m)) && null (modDecls m) -> do
      let s' = s {sImports = sImports s ++ map renderImport (modImports m)}
      r <- checkSession s' []
      either (\e -> s <$ (putStrLn =<< report s 0 0 "" e)) (const (pure s')) r
    Right m | null (modImports m) -> define s body offset m
    Right _ -> s <$ putStrLn "<interactive>: an import goes on a line of its own"
    Left declErr
      | Just (patText, p, blanked) <- bindParts input -> bindAction s input patText p blanked
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
  let chunk = Chunk body (concatMap declValues (modDecls m)) (concatMap declTypes (modDecls m)) []
      s' = withChunks s [chunk]
      forgotten = [(v, t) | c <- sChunks s, t : _ <- [chUses c `common` chTypes chunk], v <- chValues c, v `notElem` chValues chunk]
  r <- checkSession s' []
  case r of
    Left err -> do
      end <- endLine s'
      s <$ (putStrLn =<< report s (end - length (lines body)) offset body err)
    Right _ -> do
      mapM_ (\(v, t) -> putStrLn ("<interactive>: " ++ v ++ " is forgotten: its type " ++ t ++ " is defined again")) forgotten
      pure s'

-- | The session with these chunks added, and without those that define the
-- same names, or keep a value of a type they define.
withChunks :: Session -> [Chunk] -> Session
withChunks s new = s {sChunks = filter keep (sChunks s) ++ new}
  where
    keep c = and [null (chValues c `common` chValues n) && null (chTypes c `common` chTypes n) && null (chUses c `common` chTypes n) | n <- new]

common :: Eq a => [a] -> [a] -> [a]
common a b = filter (`elem` b) a

-- | The line after the session's module, where an expression goes.
endLine :: Session -> IO Int
endLine s = do
  lm <- loadedModule s
  pure (extraLine s (either (const Nothing) (fmap (\(n, _, _, m) -> (n, m))) lm))

-- | The names a declaration defines, so that defining one again replaces it.
declValues :: Decl -> [Name]
declValues = \case
  DBind n _ -> [n]
  DSig _ ns _ _ -> ns
  DData d -> [c | ConDecl c _ _ <- ddCons d] ++ concat [fs | ConDecl _ _ fs <- ddCons d]
  DClass _ _ _ _ ds -> concatMap declValues ds
  DForeign _ _ n _ -> [n]
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
evaluateExpr :: Session -> String -> IO ()
evaluateExpr s input = do
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
              void (runGo path)

-- | Runs the program with what it prints going straight out, and what Go
-- says about a failure cut to its first line: a stack overflow comes with a
-- trace of millions of frames.
runGo :: FilePath -> IO ExitCode
runGo path = do
  (_, _, Just err, ph) <- createProcess (proc "go" ["run", path]) {std_err = CreatePipe}
  said <- hGetContents err
  let kept = case [rest | l <- lines said, Just rest <- [stripPrefix "fatal error: " l]] of
        reason : _ -> ["error: " ++ reason]
        [] -> takeWhile (not . trace) [l | l <- lines said, not ("exit status " `isPrefixOf` l)]
      trace l = "goroutine " `isPrefixOf` l || "runtime stack:" `isPrefixOf` l
  mapM_ (hPutStrLn stdout) (reverse (dropWhile null (reverse kept)))
  waitForProcess ph

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

-- | The kind of a type constructor applied to some arguments, or of a class:
-- Maybe :: * -> *, Either String :: * -> *, Functor :: (* -> *) -> Constraint.
kindOf :: Session -> String -> IO ()
kindOf s input = do
  r <- checkSession s []
  case r of
    Left err -> putStrLn =<< report s 0 0 "" err
    Right (_, everything, _) -> case typeHead (trim input) of
      Nothing -> putStrLn ("<interactive>: :kind takes a type, as in :kind Maybe")
      Just (name, args) -> case paramKinds everything name of
        Nothing -> putStrLn ("<interactive>: not in scope: the type " ++ name)
        Just (ks, isClass)
          | args > length ks -> putStrLn ("<interactive>: " ++ name ++ " takes " ++ count (length ks) ++ ", not " ++ show args)
          | otherwise -> putStrLn (trim input ++ " :: " ++ intercalate " -> " (map star (drop args ks) ++ [if isClass then "Constraint" else "*"]))
  where
    count n = if n == 1 then "1 argument" else show n ++ " arguments"
    star k = if k == 0 then "*" else "(" ++ intercalate " -> " (replicate (k + 1) "*") ++ ")"

-- | The constructor at the head of a type and how many arguments it is
-- given there, counting a parenthesised argument as one.
typeHead :: String -> Maybe (Name, Int)
typeHead t = case atoms t of
  [] -> Nothing
  h : rest -> Just (h, length rest)
  where
    atoms str = case dropWhile isSpace str of
      "" -> []
      str'@('(' : _) -> let (a, more) = group 0 "" str' in a : atoms more
      str'@('[' : ']' : more) -> take 2 str' : atoms more
      str'@('[' : _) -> let (a, more) = bracket 0 "" str' in a : atoms more
      str' -> let (a, more) = break isSpace str' in a : atoms more
    group :: Int -> String -> String -> (String, String)
    group _ acc "" = (reverse acc, "")
    group d acc (c : cs)
      | c == '(' = group (d + 1) (c : acc) cs
      | c == ')' && d == 1 = (reverse (c : acc), cs)
      | c == ')' = group (d - 1) (c : acc) cs
      | otherwise = group d (c : acc) cs
    bracket :: Int -> String -> String -> (String, String)
    bracket _ acc "" = (reverse acc, "")
    bracket d acc (c : cs)
      | c == '[' = bracket (d + 1) (c : acc) cs
      | c == ']' && d == 1 = (reverse (c : acc), cs)
      | c == ']' = bracket (d - 1) (c : acc) cs
      | otherwise = bracket d (c : acc) cs

-- | How many arguments each parameter of a type constructor or a class takes,
-- and whether it is a class.
paramKinds :: Checked -> Name -> Maybe ([Int], Bool)
paramKinds ck name = case lookup name builtin of
  Just ks -> Just (ks, False)
  Nothing -> case [d | (n, d) <- M.toList (ckData ck), matches n] of
    d : _ -> Just (diKinds d, False)
    [] -> case [c | (n, c) <- M.toList (ckClasses ck), matches n] of
      c : _ -> Just (clsKinds c, True)
      [] -> Nothing
  where
    base = unqual name
    matches n = unqual n == base
    builtin =
      [ ("Int", []), ("Integer", []), ("Double", []), ("Bool", []), ("Char", []), ("String", [])
      , ("()", []), ("[]", [0]), ("IO", [0]), ("Lazy", [0]), ("(->)", [0, 0]) ]
        ++ [("(" ++ replicate (n - 1) ',' ++ ")", replicate n 0) | n <- [2 .. 15]]

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

-- * PAT <- ACTION

-- | "PAT <- EXPR", when the arrow is on the first line, outside brackets and
-- literals, and what comes before it is a pattern: the pattern's text, its
-- parse, and the input with the pattern and the arrow blanked, so that the
-- expression keeps its columns.
bindParts :: String -> Maybe (String, Pat, String)
bindParts input = case lines input of
  [] -> Nothing
  l : rest -> do
    i <- arrowAt l
    let patText = take i l
    m <- either (const Nothing) Just (parseModule "<interactive>" ("hagoPattern (" ++ patText ++ ") = ()"))
    p <- case modDecls m of
      [DBind _ [Clause [p] _]] -> Just p
      _ -> Nothing
    pure (patText, p, intercalate "\n" ((replicate (i + 2) ' ' ++ drop (i + 2) l) : rest))

-- | Where the first <- outside brackets, literals and comments is.
arrowAt :: String -> Maybe Int
arrowAt = go 0 (0 :: Int) ' '
  where
    go i d prev str = case str of
      [] -> Nothing
      '-' : '-' : more | not (symbolic prev), not (startsSymbol (dropWhile (== '-') more)) -> Nothing
      '<' : '-' : more | d == 0, not (symbolic prev), not (startsSymbol more) -> Just i
      '"' : more -> literal '"' (i + 1) d more
      '\'' : more | not (identChar prev) -> literal '\'' (i + 1) d more
      c : more
        | c `elem` "([{" -> go (i + 1) (d + 1) c more
        | c `elem` ")]}" -> go (i + 1) (d - 1) c more
        | otherwise -> go (i + 1) d c more
    literal q i d str = case str of
      '\\' : _ : more -> literal q (i + 2) d more
      c : more | c == q -> go (i + 1) d c more
      _ : more -> literal q (i + 1) d more
      [] -> Nothing
    symbolic c = c `elem` ("!#$%&*+./<=>?@\\^|-~:" :: String)
    startsSymbol = \case
      c : _ -> symbolic c
      [] -> False
    identChar c = isAlphaNum c || c == '_' || c == '\''

patternVars :: Pat -> [Name]
patternVars = \case
  PVar v -> [v]
  PAs v q -> v : patternVars q
  PCon _ qs -> concatMap patternVars qs
  PRec _ fs -> concatMap (patternVars . snd) fs
  PLoc _ q -> patternVars q
  _ -> []

-- | PAT <- EXPR runs the action once and keeps the values the pattern binds.
-- Each line runs as a program of its own, which cannot hand a value to the
-- next one, so a value is kept as the text Show gives, in a definition that
-- reads it back with Read, at the type it had. What cannot be kept is said
-- before anything runs, and the action is never run again.
bindAction :: Session -> String -> String -> Pat -> String -> IO Session
bindAction s input patText p blanked = do
  line0 <- endLine s
  r <- checkSession s exprL
  case r of
    Left err -> s <$ (putStrLn =<< report s line0 5 input err)
    Right (ck, everything, _) -> case schemeOf ck of
      Nothing -> s <$ putStrLn "hago: the expression's type was lost (a bug in hago)"
      Just sc@(Forall _ _ t)
        | Nothing <- actionResult t -> say
            [ "<interactive>: on the right of <- goes an action, and " ++ exprText ++ " :: " ++ prettyScheme (ckClasses everything) sc ++ " is not one"
            , "let " ++ trim patText ++ " = " ++ exprText ++ " names a value" ]
        | "it" `elem` vars -> say ["<interactive>: it names the expression typed at the prompt; bind another name"]
        | otherwise -> typed (line0 + length exprL)
  where
    exprL = lines (expressionLines blanked)
    exprText = trim (drop (length patText + 2) input)
    vars = nub (patternVars p)
    say ls = s <$ mapM_ putStrLn ls
    indices = [0 .. length vars - 1]
    num i = let d = show i in replicate (3 - length d) '0' ++ d
    -- one line per variable, its type taken from the action's without
    -- running it; every one has the pattern at the same column
    prefix i = "hagoT" ++ num i ++ " = hagoResult (do { "
    typeLines = [prefix i ++ patText ++ " <- hagoIO it; Prelude.pure " ++ v ++ " })" | (i, v) <- zip [0 :: Int ..] (if null vars then ["()"] else vars)]
    wholeLine = "hagoWhole = hagoResult (hagoIO it)"
    typed tLine = do
      r <- checkSession s (exprL ++ typeLines ++ [wholeLine] ++ bindHelpers)
      case r of
        Left err -> s <$ (putStrLn =<< patternError tLine err)
        Right (ck, everything, virtual) -> do
          let typeIn n = case M.lookup ("Interactive." ++ n) (ckVars ck) of
                Just (Forall _ _ (TCon _ [ty])) -> ty
                _ -> TCon "()" []
              tys = [typeIn ("hagoT" ++ num i) | i <- indices]
              whole = typeIn "hagoWhole"
              showType ty = prettyScheme (ckClasses everything) (Forall [] [] ty)
              -- a type not fixed yet is tried with Int, for a message about the type
              -- (MVar a has no Show whatever a is) to come before one about fixing it
              witness i ty
                | null (typeVars ty) = "hagoT" ++ num i
                | otherwise = "(Prelude.Nothing :: Prelude.Maybe " ++ prettyAtom (fixed ty) ++ ")"
              vts = zip3 indices vars tys
          missing <- carried [(v, ty, witness i ty) | (i, v, ty) <- vts]
          case missing of
            Just (v, ty, shows') -> say
              [ "<interactive>: " ++ v ++ " cannot be kept for the next lines: its type, " ++ showType ty ++ ", has "
                  ++ (if shows' then "Show but no Read" else "no Show") ++ (if derivable everything virtual ty then " (deriving (Show, Read) gives a data type both)" else "")
              , "each line runs as a program of its own, so a value reaches the next lines only as the text Show writes and Read reads back; nothing was run"
              , "use " ++ v ++ " within one line, as in " ++ exprText ++ " >>= \\" ++ v ++ " -> ..., or in a program; a pure value can be named with let" ]
            Nothing -> case [(v, ty) | (_, v, ty) <- vts, not (null (typeVars ty))] of
              (v, ty) : _ -> say
                [ "<interactive>: the type of " ++ v ++ ", " ++ showType ty ++ ", is not fixed by the action; give it one, as in "
                    ++ trim patText ++ " <- (" ++ exprText ++ " :: IO " ++ prettyAtom (fixed whole) ++ ")" ]
              [] -> declared [(v, ty) | (_, v, ty) <- vts]
    patternError tLine err = case errorAt err of
      Just ("<interactive>", l, c, rest)
        | l >= tLine, l < tLine + length typeLines, c > width ->
            -- past the pattern, it is the pattern that does not fit the action
            let c' = if c > width + length patText then width + 1 + length (takeWhile isSpace patText) else c
             in report s tLine width input ("<interactive>:" ++ show tLine ++ ":" ++ show c' ++ ":" ++ dropContext rest)
        | otherwise -> pure ("<interactive>:" ++ dropContext rest)
      _ -> report s 0 0 "" err
    width = length (prefix (0 :: Int))
    fixed = \case
      TVar _ -> TCon "Int" []
      TCon c ts -> TCon c (map fixed ts)
      TFun a b -> TFun (fixed a) (fixed b)
      TApp f x -> TApp (fixed f) (fixed x)
      other -> other
    -- Nothing if every variable's type has Show and Read, or the first
    -- that does not, and whether it has Show
    carried vws = do
      let check ls = either (const False) (const True) <$> checkSession s (exprL ++ typeLines ++ ls ++ bindHelpers)
          line i cls w = "hagoC" ++ num i ++ " = " ++ cls ++ " " ++ w
      every <- check [line i "hagoCarries" w | (i, (_, _, w)) <- zip indices vws]
      let first [] = pure Nothing
          first ((v, ty, w) : more) = do
            shows' <- check [line (0 :: Int) "hagoShows" w]
            reads' <- if shows' then check [line (0 :: Int) "hagoReads" w] else pure False
            if shows' && reads' then first more else pure (Just (v, ty, shows'))
      if every then pure Nothing else first vws
    -- the definitions, checked with an empty text before the action runs
    declared vts = do
      let s' = withChunks s [keptChunk v ty "" | (v, ty) <- vts]
      r <- checkSession s' []
      case r of
        Left err -> do
          msg <- report s 0 0 "" err
          say [msg, "so " ++ intercalate ", " vars ++ " cannot be kept; the action was not run"]
        Right _ -> run vts
    files = [sDir s </> ("kept" ++ num i) | i <- indices]
    runLine = "hagoRun = do { " ++ patText ++ " <- hagoIO it; "
      ++ intercalate "; " (["hagoKeep " ++ hagoString f ++ " " ++ v | (f, v) <- zip files vars] ++ ["Prelude.pure ()"]) ++ " }"
    run vts = do
      mapM_ (\f -> try (removeFile f) :: IO (Either IOException ())) files
      r <- runSession s (exprL ++ [runLine] ++ bindHelpers) ["main = hagoRun"]
      case r of
        Left err -> s <$ (putStrLn =<< report s 0 0 "" err)
        Right (_, _, virtual) -> do
          checked <- checkProgram virtual "<main>"
          case checked >>= generateProgram "<main>" of
            Left err -> s <$ (putStrLn =<< report s 0 0 "" err)
            Right go -> do
              let path = sDir s </> "main.go"
              writeFile path go
              hFlush stdout
              code <- runGo path
              texts <- mapM readKept files
              case (code, sequence texts) of
                (ExitSuccess, Just ts) -> case [v | (v, "") <- zip vars ts] of
                  v : _ -> say ["<interactive>: " ++ v ++ " cannot be kept: Read does not read back what Show gives for its value (the action did run)"]
                  [] -> pure (withChunks s [keptChunk v ty txt | ((v, ty), txt) <- zip vts ts])
                _ -> pure s

-- | The result's type, if this is the type of an action run at the prompt.
actionResult :: Type -> Maybe Type
actionResult = \case
  TCon "IO" [r] -> Just r
  TApp (TVar _) r -> Just r
  _ -> Nothing

typeVars :: Type -> [Name]
typeVars = \case
  TVar v -> [v]
  TCon _ ts -> concatMap typeVars ts
  TFun a b -> typeVars a ++ typeVars b
  TApp f x -> typeVars f ++ typeVars x
  _ -> []

typeCons :: Type -> [Name]
typeCons = \case
  TCon c ts -> c : concatMap typeCons ts
  TFun a b -> typeCons a ++ typeCons b
  TApp f x -> typeCons f ++ typeCons x
  _ -> []

-- | Whether the type is made of data types declared at the prompt or in the
-- loaded file (the virtual modules), which could derive Show and Read, and
-- the Prelude's.
derivable :: Checked -> Virtual -> Type -> Bool
derivable everything virtual ty = noFunctions ty && any own cons && all ordinary cons
  where
    cons = nub (typeCons ty)
    own c = case splitQual c of
      (Just m, _) -> M.member m virtual
      _ -> False
    ordinary c = case M.lookup c (ckData everything) of
      Just d -> null (diForeign d) && not (null (diCons d))
      Nothing -> c `elem` ["Int", "Integer", "Double", "Bool", "Char", "String", "()", "[]"] || isJust (tupleArity c)
    noFunctions = \case
      TFun _ _ -> False
      TCon c ts -> c /= "IO" && all noFunctions ts
      TApp _ _ -> False
      _ -> True

-- | A definition that gives back a value kept as text.
keptChunk :: Name -> Type -> String -> Chunk
keptChunk v ty text = Chunk src [v] [] (nub (map unqual (typeCons ty)))
  where
    src = unlines
      [ v ++ " :: " ++ pretty ty
      , v ++ " = case Prelude.read " ++ hagoString text ++ " of { Prelude.Just hagoValue -> hagoValue; Prelude.Nothing -> Prelude.error "
          ++ hagoString (v ++ ": its value could not be read back") ++ " }" ]

-- | What the program writes for a value kept, read whole, as UTF-8.
readKept :: FilePath -> IO (Maybe String)
readKept f = do
  r <- try (withFile f ReadMode (\h -> hSetEncoding h utf8 >> hGetContents h >>= \t -> length t `seq` pure t)) :: IO (Either IOException String)
  pure (either (const Nothing) Just r)

-- | A string literal of Hago's.
hagoString :: String -> String
hagoString str = "\"" ++ concatMap esc str ++ "\""
  where
    esc = \case
      '"' -> "\\\""
      '\\' -> "\\\\"
      '\n' -> "\\n"
      '\r' -> "\\r"
      c -> [c]

-- | What the lines binding a pattern use; names from the Prelude are
-- qualified, as the file loaded or the prompt may define the same.
bindHelpers :: [String]
bindHelpers =
  [ "hagoIO :: IO a -> IO a"
  , "hagoIO hagoX = hagoX"
  , "hagoResult :: IO a -> Prelude.Maybe a"
  , "hagoResult _ = Prelude.Nothing"
  , "hagoCarries :: (Prelude.Show a, Prelude.Read a) => Prelude.Maybe a -> ()"
  , "hagoCarries _ = ()"
  , "hagoShows :: Prelude.Show a => Prelude.Maybe a -> ()"
  , "hagoShows _ = ()"
  , "hagoReads :: Prelude.Read a => Prelude.Maybe a -> ()"
  , "hagoReads _ = ()"
  , "hagoKeep :: (Prelude.Show a, Prelude.Read a) => String -> a -> IO ()"
  , "hagoKeep hagoPath hagoX = do { _ <- Prelude.writeFile hagoPath (if hagoSame hagoX (Prelude.read (Prelude.show hagoX)) then Prelude.show hagoX else \"\"); Prelude.pure () }"
  , "hagoSame :: a -> Prelude.Maybe a -> Bool"
  , "hagoSame _ hagoR = case hagoR of { Prelude.Just _ -> True; Prelude.Nothing -> False }" ]

-- | An error's file, line, column and what follows them.
errorAt :: String -> Maybe (String, Int, Int, String)
errorAt e = case break (== ':') e of
  (path, ':' : more)
    | (l, ':' : more') <- span isDigit more
    , (c, ':' : rest) <- span isDigit more'
    , not (null l), not (null c) -> Just (path, read l, read c, rest)
  _ -> Nothing

-- | " in hagoT000: msg" is " msg": the helper lines are not the user's.
dropContext :: String -> String
dropContext r = case stripPrefix " in " r of
  Just more | (n, ':' : rest) <- break (== ':') more, "hago" `isPrefixOf` n || n == "it" -> rest
  _ -> r

-- * :info and :browse

-- | What a name is: a value's type, a constructor's and its type's, a
-- method's and its class, a type's or a class's definition and instances.
info :: Session -> Name -> IO ()
info s typed = do
  r <- sessionExports s [] []
  case r of
    Left err -> putStrLn =<< report s 0 0 "" err
    Right (_, everything, rn, syns, virtual) -> do
      let -- constructors a module does not export are not shown
          visible t = case splitQual t of
            (Just m, _) | Just table <- M.lookup m (rnExports rn) -> Just (M.elems (tVals table))
            _ -> Nothing
          types = [describeType everything syns (visible t) t ++ instancesOf everything t | t <- candidates (M.keys (ckData everything) ++ M.keys syns ++ M.keys (ckClasses everything))]
            ++ [["data " ++ b ++ maybe "" (" = " ++) (lookup b [("Bool", "False | True"), ("()", "()")])] ++ instancesOf everything b | b <- [base], b `elem` builtinTypes]
          own = ordered virtual id
          candidates ks = take 1 (own [k | k <- ks, matches k])
          base = unqual name
          qualifier = fst (splitQual name)
          matches k = unqual k == base && maybe True (\q -> fst (splitQual k) == Just q || aliased q k) qualifier
          aliased q k = or [fst (splitQual k) == Just (impModule i) | imp <- sImports s, Right m <- [parseModule "<interactive>" imp], i <- modImports m, impAs i == Just q]
      value <- if isConName base && not (isTupleName base) || not (isConName base)
        then do
          v <- checkSession s ["it = " ++ (if isOperatorName base then "(" ++ name ++ ")" else name)]
          pure $ case v of
            Right (ck, _, _) | Just sc <- schemeOf ck ->
              [ [(if isOperatorName base then "(" ++ base ++ ")" else base) ++ " :: " ++ prettyScheme (ckClasses everything) sc]
                  ++ [ "  -- a method of class " ++ unqual c | (c, ci) <- M.toList (ckClasses everything), (mn, _) <- clsMethods ci, unqual mn == base, not (isConName base) ]
                  ++ take 1 [ "  -- a constructor of " ++ unqual (ciType ci) | (k, ci) <- ordered virtual fst (M.toList (ckCons everything)), unqual k == base, isConName base ] ]
            _ -> []
        else pure []
      case value ++ types of
        [] -> putStrLn ("<interactive>: not in scope: " ++ name)
        found -> mapM_ (mapM_ putStrLn) found
  where
    name = case typed of
      '(' : more@(_ : _) | last more == ')', isOperatorName (init more) -> init more
      _ -> typed
    isTupleName n = isJust (tupleArity n)
    builtinTypes = ["Int", "Integer", "Double", "Char", "String", "Bool", "()", "IO"]
    -- what the prompt and the loaded file define first, then the Prelude's, then the rest
    ordered :: Virtual -> (a -> Name) -> [a] -> [a]
    ordered virtual key = sortOn (rank . fst . splitQual . key)
      where
        rank = \case
          Just "Interactive" -> 0 :: Int
          Just m | M.member m virtual -> 1
          Nothing -> 2
          _ -> 3

-- | A data type, a type synonym or a class, as it could be declared.
describeType :: Checked -> M.Map Name ([Name], SType) -> Maybe [Name] -> Name -> [String]
describeType everything syns visible t = case (M.lookup t (ckData everything), M.lookup t syns, M.lookup t (ckClasses everything)) of
  (Just d, _, _) -> [dataLine everything visible t d]
  (_, Just (ps, st), _) -> ["type " ++ unwords (unqual t : ps) ++ " = " ++ prettySType st]
  (_, _, Just ci) -> classLines t ci
  _ -> []

dataLine :: Checked -> Maybe [Name] -> Name -> DataInfo -> String
dataLine everything visible t d = case diForeign d of
  Just sym -> "foreign import go type " ++ show sym ++ " " ++ unwords (unqual t : diParams d)
  Nothing -> keyword ++ unwords (unqual t : diParams d) ++ constructors
  where
    keyword = if diNewtype d then "newtype " else "data "
    shown = [k | k <- diCons d, maybe True (k `elem`) visible]
    constructors
      | null shown = ""
      | otherwise = " = " ++ intercalate " | " (map con shown)
    con k = case M.lookup k (ckCons everything) of
      Just ci -> unwords (conName (unqual k) : [(if lz then "~" else "") ++ prettyAtom ft | (lz, ft) <- ciFields ci])
      Nothing -> unqual k
    conName k = if isOperatorName k then "(" ++ k ++ ")" else k

classLines :: Name -> ClassInfo -> [String]
classLines c ci =
  [ "class " ++ contextOf (clsSupers ci) ++ unwords (unqual c : clsVars ci) ++ (if null (clsMethods ci) then "" else " where") ]
    ++ [ "  " ++ var m ++ " :: " ++ contextOf own ++ pretty t | (m, Forall _ (_ : own) t) <- clsMethods ci ]
  where
    var m = let b = unqual m in if isOperatorName b then "(" ++ b ++ ")" else b

-- | A context as written: "Eq a => ", "(Eq a, Show a) => ".
contextOf :: [Pred] -> String
contextOf ps = case [unqual c ++ " " ++ unwords (map prettyAtom ts) | IsIn c ts <- ps] of
  [] -> ""
  [p] -> p ++ " => "
  many -> "(" ++ intercalate ", " many ++ ") => "

-- | The instances of a class, or for a type.
instancesOf :: Checked -> Name -> [String]
instancesOf everything t =
  map snd $ nub $ sortOn id
    [ ((unqual (instClass i), map pretty (instHead i)), "instance " ++ contextOf (instCtx i) ++ unqual (instClass i) ++ " " ++ unwords (map prettyAtom (instHead i)))
    | i <- ckInstInfos everything, instClass i == t || any ((== Just t) . headCon) (instHead i) ]
  where
    headCon = \case
      TCon k _ -> Just k
      _ -> Nothing

prettySType :: SType -> String
prettySType = go (0 :: Int)
  where
    go _ (STVar v) = v
    go _ (STCon "[]" [a]) = "[" ++ go 0 a ++ "]"
    go _ (STCon c ts) | Just n <- tupleArity c, length ts == n = "(" ++ intercalate ", " (map (go 0) ts) ++ ")"
    go _ (STCon c []) = unqual c
    go p (STCon c ts) = paren (p > 1) (unwords (unqual c : map (go 2) ts))
    go p (STFun a b) = paren (p > 0) (go 1 a ++ " -> " ++ go 0 b)
    go p (STApp f xs) = paren (p > 1) (unwords (go 2 f : map (go 2) xs))
    paren True x = "(" ++ x ++ ")"
    paren False x = x

-- | What a module exports: its types and classes, then its values with
-- their types, as declarations.
browse :: Session -> Name -> IO ()
browse s m = do
  let brought = s {sImports = sImports s ++ ["import qualified " ++ m | m `notElem` ["Prelude", "Interactive"]]}
  r <- sessionExports brought [] []
  case r of
    Left err -> putStrLn =<< report s 0 0 "" err
    Right (_, everything, rn, syns, _) -> case M.lookup m (rnExports rn) of
      Nothing -> putStrLn ("<interactive>: no module " ++ m)
      Just table -> do
        let vals = tVals table
            exported = M.elems vals
            typeLine = describeType everything syns (Just exported)
            methods = [mn | t <- M.elems (tTypes table), Just ci <- [M.lookup t (ckClasses everything)], (mn, _) <- clsMethods ci]
            constructors = M.keys (ckCons everything)
            valueLine (n, i) = case M.lookup i (ckVars everything) of
              Just sc | i `notElem` methods, i `notElem` constructors -> [(if isOperatorName n then "(" ++ n ++ ")" else n) ++ " :: " ++ prettyScheme (ckClasses everything) sc]
              _ -> []
        mapM_ putStrLn (concatMap typeLine (M.elems (tTypes table)) ++ concatMap valueLine (M.toList vals))
