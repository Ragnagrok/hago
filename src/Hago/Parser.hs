{-# LANGUAGE LambdaCase #-}

-- | Parser from tokens (after layout) to the surface syntax, plus fixity
-- resolution of operator sequences.
module Hago.Parser (parseModule, resolveFixity, fixitiesOf) where

import Control.Monad
import Data.List (groupBy, nub)
import qualified Data.Map as M
import Data.Maybe (fromMaybe)
import Hago.Lexer
import Hago.Syntax
import Text.Parsec hiding (token, tokens)
import Text.Parsec.Error (errorMessages, showErrorMessages)
import Text.Parsec.Pos (initialPos)
import qualified Text.Parsec as P

-- | The user state is the file being parsed, for locations.
type Parser = Parsec [Token] FilePath

parseModule :: FilePath -> String -> Either String Module
parseModule file src = do
  toks <- either (\e -> Left (file ++ ":" ++ e)) Right (lexer src)
  ds <- either (Left . showParseError file) Right (runParser pModule file file (layout toks))
  pure ds

-- Token primitives -----------------------------------------------------------

showParseError :: FilePath -> ParseError -> String
showParseError file err =
  file ++ ":" ++ show (sourceLine p) ++ ":" ++ show (sourceColumn p) ++ ": syntax error"
    ++ showErrorMessages "or" "unknown parse error" "expecting" "unexpected" "end of input" (errorMessages err)
  where p = errorPos err

-- | How a token reads in an error message.
describe :: Tok -> String
describe = \case
  TVarId s -> "identifier " ++ s
  TConId s -> "constructor " ++ s
  TVarSym s -> "operator " ++ s
  TConSym s -> "operator " ++ s
  TInt n -> "number " ++ show n
  TFloat d -> "number " ++ show d
  TChar c -> "character " ++ show c
  TStr s -> "string " ++ show s
  TProj s -> "field access ." ++ s
  TSpecial "{" -> "the start of a block"
  TSpecial "}" -> "the end of a block"
  TSpecial ";" -> "a new line"
  TSpecial s -> show s
  TKey k -> show k
  TOpenN _ _ -> "layout"
  TLineN _ -> "layout"

satisfyT :: (Tok -> Maybe a) -> Parser a
satisfyT f = P.token (describe . tokVal) pos (f . tokVal)
  where pos t = newPos' (tokLine t) (tokCol t)
        newPos' l c = setSourceColumn (setSourceLine (initialPos "") l) c

tokEq :: Tok -> Parser ()
tokEq t = satisfyT (\x -> if x == t then Just () else Nothing) <?> describe t

-- | The location of the next token.
here :: Parser Loc
here = do
  file <- getState
  t <- lookAhead (P.token (describe . tokVal) pos Just)
  pure (file, tokLine t, tokCol t)
  where pos t = setSourceColumn (setSourceLine (initialPos "") (tokLine t)) (tokCol t)

locE :: Parser Expr -> Parser Expr
locE p = ELoc <$> here <*> p

locP :: Parser Pat -> Parser Pat
locP p = PLoc <$> here <*> p

special :: String -> Parser ()
special = tokEq . TSpecial

key :: String -> Parser ()
key = tokEq . TKey

varId :: Parser Name
varId = satisfyT f <?> "identifier"
  where f (TVarId s) = Just s
        f _ = Nothing

conId :: Parser Name
conId = satisfyT f <?> "constructor"
  where f (TConId s) = Just s
        f _ = Nothing

varSym :: Parser Name
varSym = satisfyT f <?> "operator"
  where f (TVarSym s) = Just s
        f _ = Nothing

proj :: Parser Name
proj = satisfyT f <?> "field access"
  where f (TProj s) = Just s
        f _ = Nothing

conSym :: Parser Name
conSym = satisfyT f <?> "constructor operator"
  where f (TConSym s) = Just s
        f _ = Nothing

parens, brackets :: Parser a -> Parser a
parens p = special "(" *> p <* special ")"
brackets p = special "[" *> p <* special "]"

-- | A layout block: @{ p ; p ; ... }@, tolerating empty items.
block :: Parser a -> Parser [a]
block p = do
  special "{"
  skipMany (special ";")
  xs <- p `sepEndBy` skipMany1 (special ";")
  special "}"
  pure xs

-- | A variable, possibly an operator in parentheses.
var :: Parser Name
var = varId <|> try (parens varSym)

-- | An operator in infix position: a symbol or a name in backquotes.
operator :: Parser Name
operator = varSym <|> conSym <|> (special "`" *> (varId <|> conId) <* special "`")

-- Module and declarations ---------------------------------------------------

pModule :: Parser Module
pModule = do
  file <- getState
  header <- optionMaybe $ do
    l <- here
    key "module"
    name <- conId
    exports <- optionMaybe (parens (exportItem `sepEndBy` special ","))
    key "where"
    pure (name, exports, l)
  items <- block ((Left <$> importDecl) <|> (Right <$> topDecl))
  eof
  let (name, exports, l) = maybe ("Main", Nothing, (file, 1, 1)) id header
  pure (Module name exports [i | Left i <- items] (groupClauses (concat [d | Right d <- items])) l)

exportItem :: Parser Item
exportItem = (IModule <$> (key "module" *> conId)) <|> item

-- | An entry of an import or export list.
item :: Parser Item
item = (IVar <$> var) <|> do
  t <- conId
  sub <- option SubNone $ parens $
    (SubAll <$ key "..") <|> (SubSome <$> ((var <|> conId) `sepBy` special ","))
  pure (IType t sub)

importDecl :: Parser Import
importDecl = do
  l <- here
  key "import"
  q <- option False (True <$ tokEq (TVarId "qualified"))
  m <- conId
  as <- optionMaybe (tokEq (TVarId "as") >> conId)
  hiding <- option False (True <$ tokEq (TVarId "hiding"))
  list <- optionMaybe (parens (item `sepEndBy` special ","))
  pure $ if hiding
    then Import m q as Nothing (maybe [] id list) l
    else Import m q as list [] l

topDecl :: Parser [Decl]
topDecl = choice
  [ pure <$> dataDecl
  , pure <$> typeDecl
  , pure <$> foreignDecl
  , pure <$> classDecl
  , pure <$> instanceDecl
  , decl
  ]

dataDecl :: Parser Decl
dataDecl = do
  l <- here
  nt <- (False <$ key "data") <|> (True <$ key "newtype")
  name <- conId
  params <- many varId
  key "="
  cons <- conDecl `sepBy1` key "|"
  derivs <- option [] (key "deriving" >> ((pure <$> conId) <|> parens (conId `sepBy` special ",")))
  pure (DData (DataDecl name params cons derivs nt l Nothing))

typeDecl :: Parser Decl
typeDecl = do
  key "type"
  name <- conId
  params <- many varId
  key "="
  DType name params <$> pType

-- | An optional context, as in @(Eq a, Show b) =>@.
context :: Parser Context
context = option [] (try (preds <* key "=>"))
  where
    preds = (pure <$> predicate) <|> parens (predicate `sepBy` special ",")
    predicate = (,) <$> conId <*> many1 aType

classDecl :: Parser Decl
classDecl = do
  key "class"
  supers <- context
  cls <- conId
  vs <- many1 varId
  deps <- option [] (key "|" >> funDep `sepBy1` special ",")
  body <- option [] (key "where" >> localDecls)
  pure (DClass supers cls vs deps body)
  where
    funDep = (,) <$> many1 varId <* key "->" <*> many1 varId

instanceDecl :: Parser Decl
instanceDecl = do
  l <- here
  key "instance"
  ctx <- context
  cls <- conId
  ts <- many1 aType
  body <- option [] (key "where" >> localDecls)
  pure (DInstance (Just l) ctx cls ts body)

conDecl :: Parser ConDecl
conDecl = try infixCon <|> try recordCon <|> prefixCon
  where
    prefixCon = ConDecl <$> (conId <|> try (parens conSym)) <*> many field <*> pure []
    -- a :+: Chain a: each side is a type applied to arguments
    infixCon = do
      l <- infixField
      op <- conSym
      r <- infixField
      pure (ConDecl op [l, r] [])
    infixField = ((,) True <$> (key "~" *> aType))
        <|> ((,) False <$> (optional (tokEq (TVarSym "!")) *> bType))
    field = ((,) True <$> (key "~" *> aType))
        <|> ((,) False <$> (optional (tokEq (TVarSym "!")) *> aType))
    -- C { x, y :: Int, next :: ~(Stream a) }
    recordCon = do
      k <- conId
      special "{"
      groups <- fieldGroup `sepBy` special ","
      special "}"
      pure (ConDecl k [f | (ns, f) <- groups, _ <- ns] (concatMap fst groups))
    fieldGroup = do
      ns <- varId `sepBy1` special ","
      key "::"
      f <- ((,) True <$> (key "~" *> pType)) <|> ((,) False <$> (optional (tokEq (TVarSym "!")) *> pType))
      pure (ns, f)

foreignDecl :: Parser Decl
foreignDecl = do
  l <- here
  key "foreign" >> key "import"
  lang <- varId
  unless (lang == "go") (fail "only `foreign import go` is supported")
  isType <- option False (True <$ key "type")
  -- foreign import go sequential "hog_run" run :: ... (see Hago.Core.Foreign)
  sequential <- option False (True <$ try (tokEq (TVarId "sequential")))
  sym <- satisfyT (\t -> case t of TStr s -> Just s; _ -> Nothing)
  if isType
    then do
      -- foreign import go type "*net/http.Request" Request
      name <- conId
      params <- many varId
      pure (DData (DataDecl name params [] [] False l (Just sym)))
    else do
      name <- var
      key "::"
      DForeign sequential sym name <$> pType

-- | Declarations allowed in let/where and at the top: signatures, fixity
-- declarations, function clauses and pattern bindings.
decl :: Parser [Decl]
decl = fixity <|> try sig <|> patBinding <|> (pure <$> binding)
  where
    sig = do
      l <- here
      names <- var `sepBy1` special ","
      key "::"
      ctx <- context
      t <- pType
      pure [DSig l names ctx t]
    fixity = do
      assoc <- (AssocL <$ key "infixl") <|> (AssocR <$ key "infixr") <|> (AssocN <$ key "infix")
      prec <- option 9 (satisfyT (\t -> case t of TInt n -> Just (fromInteger n); _ -> Nothing))
      ops <- operator `sepBy1` special ","
      pure [DFixity assoc prec ops]

-- | (a, b) = e, or Just x = e: one hidden binding for the value, and one per
-- variable that takes it out with a case.
patBinding :: Parser [Decl]
patBinding = do
  (_, line, col) <- here
  p <- try $ do
    _ <- lookAhead (special "(" <|> special "[" <|> (() <$ conId))
    p <- pat
    _ <- lookAhead (key "=" <|> key "|")
    pure p
  r <- rhs (key "=")
  let n = "_pb" ++ show line ++ "_" ++ show col
      takeOut v = Rhs [(Nothing, ECase (EVar n) [Alt p (Rhs [(Nothing, EVar v)] [])])] []
  pure (DBind n [Clause [] r] : [DBind v [Clause [] (takeOut v)] | v <- patVars p])

patVars :: Pat -> [Name]
patVars = \case
  PVar v -> [v]
  PAs v q -> v : patVars q
  PCon _ qs -> concatMap patVars qs
  PRec _ fs -> concatMap (patVars . snd) fs
  PLoc _ q -> patVars q
  _ -> []

binding :: Parser Decl
binding = do
  (name, ps) <- funLhs
  r <- rhs (key "=")
  pure (DBind name [Clause ps r])

-- | What is being defined, and its arguments, as in the Report's funlhs:
-- @f x y@, @x <+> y@, @x `op` y@, or one of those in parentheses with more
-- arguments after it, as in @(f >=> g) x@.
funLhs :: Parser (Name, [Pat])
funLhs = try parenthesised <|> try infixLhs <|> prefixLhs
  where
    prefixLhs = (,) <$> var <*> many (locP aPat)
    infixLhs = do
      l <- pat
      op <- varSym <|> (special "`" *> varId <* special "`")
      r <- pat
      pure (op, [l, r])
    parenthesised = do
      (name, ps) <- special "(" *> funLhs <* special ")"
      more <- many1 (locP aPat)
      pure (name, ps ++ more)

rhs :: Parser () -> Parser Rhs
rhs sep = do
  alts <- guarded <|> (pure . (,) Nothing <$> (sep *> expr))
  wh <- option [] (key "where" >> localDecls)
  pure (Rhs alts wh)
  where
    guarded = many1 $ do
      key "|"
      g <- expr
      sep
      e <- expr
      pure (Just g, e)

-- | Consecutive clauses of the same function become one binding.
groupClauses :: [Decl] -> [Decl]
groupClauses = map merge . groupBy same
  where
    same (DBind a _) (DBind b _) = a == b
    same _ _ = False
    merge ds@(DBind n _ : _) = DBind n (concat [cs | DBind _ cs <- ds])
    merge [d] = d
    merge ds = error ("groupClauses: " ++ show ds)

-- Types ------------------------------------------------------------------------

pType :: Parser SType
pType = do
  t <- bType
  option t (STFun t <$> (key "->" *> pType))

bType :: Parser SType
bType = do
  h <- aType
  args <- many aType
  pure $ case (h, args) of
    (_, []) -> h
    (STCon c xs, _) -> STCon c (xs ++ args)
    _ -> STApp h args

aType :: Parser SType
aType = choice
  [ STVar <$> varId
  , (\c -> STCon c []) <$> conId
  , special "[" *> ((STCon "[]" [] <$ special "]") <|> (STCon "[]" . pure <$> pType <* special "]"))
  , special "(" *> tupleType
  ]
  where
    tupleType = (STCon "()" [] <$ special ")")
      <|> try (STCon "->" [] <$ (key "->" >> special ")"))
      <|> try (do n <- many1 (special ","); special ")"; flip STCon [] <$> tupleOf (length n + 1))
      <|> do
      ts <- pType `sepBy1` special ","
      special ")"
      case ts of
        [t] -> pure t
        _ -> flip STCon ts <$> tupleOf (length ts)

-- | A tuple of n elements. The type checker refuses those past the largest,
-- where it knows where the tuple is.
tupleOf :: Int -> Parser Name
tupleOf = pure . tupleCon

-- Patterns -------------------------------------------------------------------

pat :: Parser Pat
pat = do
  l <- lPat
  option l $ do
    op <- conSym
    r <- pat
    pure (PCon op [l, r])

lPat :: Parser Pat
lPat = locP (try (PCon <$> conId <*> many1 aPat) <|> negLit) <|> aPat
  where negLit = do
          tokEq (TVarSym "-")
          n <- satisfyT (\t -> case t of TInt i -> Just i; _ -> Nothing)
          pure (PLit (LInt (negate n)))

aPat :: Parser Pat
aPat = locP $ choice
  [ try (PAs <$> varId <* key "@") <*> aPat
  , PVar <$> var
  , PWild <$ key "_"
  , conId >>= \k -> option (PCon k []) (PRec k <$> recordPat)
  , PLit <$> literal
  , listPat <$> brackets (pat `sepBy` special ",")
  , special "(" *> tuplePat
  ]
  where
    tuplePat = (PCon "()" [] <$ special ")") <|> do
      ps <- pat `sepBy1` special ","
      special ")"
      case ps of
        [p] -> pure p
        _ -> flip PCon ps <$> tupleOf (length ps)
    listPat = foldr (\p acc -> PCon ":" [p, acc]) (PCon "[]" [])
    -- { x = p, y }: y alone binds a variable named like the field
    recordPat = between (special "{") (special "}") $ flip sepBy (special ",") $ do
      l <- varId
      option (l, PVar l) ((,) l <$> (key "=" *> pat))

literal :: Parser Lit
literal = satisfyT f <?> "literal"
  where f (TInt n) = Just (LInt n)
        f (TFloat d) = Just (LDouble d)
        f (TChar c) = Just (LChar c)
        f (TStr s) = Just (LStr s)
        f _ = Nothing

-- Expressions ----------------------------------------------------------------

expr :: Parser Expr
expr = do
  e0 <- operand
  rest <- many (try ((,) <$> (here >>= \l -> operator >>= \op -> pure (op, l)) <*> operand))
  let e = if null rest then unmarked e0 else EOpSeq e0 rest
  option e (EAnn e <$> (key "::" *> pType))
  where
    -- an operand, which a minus before it negates, at the start or after an
    -- operator: x < -0.4 (see 'resolveFixity')
    operand = do
      neg <- optionMaybe (tokEq (TVarSym "-"))
      e <- expr10
      pure (maybe e (const (EApp (EVar negated) e)) neg)
    unmarked = \case
      EApp (EVar m) e | m == negated -> EApp (EVar "Prelude.negate") e
      e -> e

-- | The mark of an operand with a minus before it, until fixities are
-- resolved: a name no source can write.
negated :: Name
negated = "-negated"

expr10 :: Parser Expr
expr10 = locE $ choice
  [ lambda
  , letIn
  , ifThen
  , caseOf
  , EDo . patBinds <$> (key "do" *> block stmt)
  , fexpr
  ]
  where
    lambda = do
      key "\\"
      ps <- many1 aPat
      key "->"
      ELam ps <$> expr
    letIn = do
      key "let"
      ds <- localDecls
      key "in"
      ELet ds <$> expr
    ifThen = do
      key "if"
      c <- expr
      optional (special ";")
      key "then"
      t <- expr
      optional (special ";")
      key "else"
      EIf c t <$> expr
    caseOf = do
      key "case"
      s <- expr
      key "of"
      ECase s <$> block (Alt <$> pat <*> rhs (key "->"))

stmt :: Parser Stmt
stmt = try bind <|> try patBind <|> try letStmt <|> (SExpr <$> expr)
  where
    bind = do
      x <- (var <|> ("_" <$ key "_"))
      key "<-"
      SBind x <$> expr
    patBind = do
      p <- pat
      key "<-"
      SBindPat p <$> expr
    letStmt = do
      key "let"
      ds <- localDecls
      notFollowedBy (key "in")
      pure (SLet ds)

-- | @p <- e; rest@ binds a variable and matches it: @x <- e; case x of p -> do rest@.
patBinds :: [Stmt] -> [Stmt]
patBinds = \case
  SBindPat p e : rest@(_ : _) ->
    [SBind "_pat" e, SExpr (ECase (EVar "_pat") [Alt p (Rhs [(Nothing, EDo (patBinds rest))] [])])]
  s : rest -> s : patBinds rest
  [] -> []

fexpr :: Parser Expr
fexpr = foldl1 EApp <$> many1 aExpr

-- | An atom followed by field accesses (@p.pos.x@) and record braces
-- (@C { x = 1 }@ builds, @p { x = 1 }@ updates), which bind tighter than
-- application.
aExpr :: Parser Expr
aExpr = do
  l <- here
  a <- locE $ choice
    [ EVar <$> varId
    , ECon <$> conId
    , ELit <$> literal
    , special "[" *> listExpr
    , special "(" *> parenExpr
    ]
  postfix l a
  where
    postfix l a =
      (here >>= \lf -> proj >>= \f -> postfix l (ELoc lf (EField a f [])))
        <|> (recordBraces >>= recordExpr a >>= postfix l . ELoc l)
        <|> pure a

-- | @{ x = e, y, pos.x = e }@: a field without a value is the variable of
-- that name; a path updates a field of a field.
recordBraces :: Parser [([Name], Expr)]
recordBraces = between (special "{") (special "}") $ flip sepBy (special ",") $ do
  l <- here
  x <- varId
  path <- (x :) <$> many proj
  v <- optionMaybe (key "=" *> expr)
  case v of
    Just e -> pure (path, e)
    Nothing
      | null (drop 1 path) -> pure (path, ELoc l (EVar x))
      | otherwise -> fail "a field path needs a value"

recordExpr :: Expr -> [([Name], Expr)] -> Parser Expr
recordExpr a fs = case unLoc a of
  ECon k
    | all ((== 1) . length . fst) fs -> pure (ERecCon k [(l, v) | ([l], v) <- fs])
    | otherwise -> fail "field paths are for updates; build the inner record instead"
  _
    | null fs -> fail "an update must change at least one field"
    | otherwise -> update (0 :: Int) a fs
  where
    -- p { pos.x = 1, name = n } is let u = p in u { pos = u.pos { x = 1 }, name = n }
    update depth e paths
      | all ((== 1) . length . fst) paths = pure (ERecUpd e [(l, v) | ([l], v) <- paths] [])
      | otherwise = do
          let u = "_upd" ++ show depth
          fields <- forM (nub [l | (l : _, _) <- paths]) $ \l ->
            case [(rest, v) | (l' : rest, v) <- paths, l' == l] of
              [([], v)] -> pure (l, v)
              subs
                | any (null . fst) subs -> fail ("field " ++ l ++ " is changed twice")
                | otherwise -> (,) l <$> update (depth + 1) (EField (EVar u) l []) subs
          pure (ELet [DBind u [Clause [] (Rhs [(Nothing, e)] [])]] (ERecUpd (EVar u) fields []))

listExpr :: Parser Expr
listExpr = (ECon "[]" <$ special "]") <|> do
  e <- expr
  choice
    [ do key ".."
         hi <- optionMaybe expr
         special "]"
         pure $ maybe (EApp (EVar "Prelude.enumFrom") e) (EApp (EApp (EVar "Prelude.enumFromTo") e)) hi
    , do key "|"
         qs <- qualifier `sepBy1` special ","
         special "]"
         pure (comprehension e qs)
    , do es <- many (special "," *> expr)
         let items = foldr (\x acc -> EApp (EApp (ECon ":") x) acc) (ECon "[]") (e : es)
         case es of
           [next] -> (items <$ special "]") <|> do
             key ".."
             hi <- optionMaybe expr
             special "]"
             pure $ maybe (app2 "Prelude.enumFromThen" e next) (EApp (app2 "Prelude.enumFromThenTo" e next)) hi
           _ -> items <$ special "]"
    ]
  where
    app2 f a b = EApp (EApp (EVar f) a) b

data Qualifier = QGen Pat Expr | QLet [Decl] | QGuard Expr

qualifier :: Parser Qualifier
qualifier = gen <|> letQ <|> (QGuard <$> expr)
  where
    gen = do
      p <- try (pat <* key "<-")
      QGen p <$> expr
    letQ = try $ do
      key "let"
      ds <- localDecls
      notFollowedBy (key "in")
      pure (QLet ds)

-- | The translation GHC makes, which means what the Haskell report's does
-- (generators are concatMap, guards are if, and an element that does not
-- match a generator's pattern is skipped) without lists of one element
-- joined with ++: a generator is a foldr whose step is given the rest of
-- the list, puts an element before it or skips to it, and
-- [b | (k, b) <- xs, p k] is foldr (\x r -> case x of (k, b) -> if p k then
-- b : r else r; _ -> r) [] xs. Hago's foldr computes its end first, so a
-- generator inside another is a list of its own followed by the rest with
-- ++, which would otherwise be computed before the inner list is visited.
comprehension :: Expr -> [Qualifier] -> Expr
comprehension e qs0 = go (0 :: Int) Nothing qs0
  where
    -- the list that follows, a variable, or [] for the outermost generator
    end = maybe (ECon "[]") EVar
    go n tl = \case
      [] -> EApp (EApp (ECon ":") e) (end tl)
      QGuard b : qs -> EIf b (go n tl qs) (end tl)
      QLet ds : qs -> ELet ds (go n tl qs)
      QGen p l : qs ->
        let r = "_lr" ++ show n
            body = go (n + 1) (Just r) qs
            step = case unLocP p of
              PVar _ -> ELam [p, PVar r] body
              _ ->
                let x = "_lc" ++ show n
                 in ELam [PVar x, PVar r] (ECase (EVar x) [Alt p (Rhs [(Nothing, body)] []), Alt PWild (Rhs [(Nothing, EVar r)] [])])
            fold = EApp (EApp (EApp (EVar "Prelude.foldr") step) (ECon "[]")) l
         in case tl of
              Nothing -> fold
              Just t -> EApp (EApp (EVar "Prelude.append") fold) (EVar t)

-- | After an opening parenthesis: unit, a tuple constructor, an operator as a
-- value, a section, a parenthesised expression or a tuple.
parenExpr :: Parser Expr
parenExpr = choice
  [ ECon "()" <$ special ")"
  , do n <- many1 (special ","); special ")"; ECon <$> tupleOf (length n + 1)
  , selector
  , try (opValue <* special ")")
  , try rightSection
  , do
      e <- expr
      choice
        [ do op <- operator
             special ")"
             pure (EApp (opExpr op) e)
        , special ")" >> pure e
        , do es <- many1 (special "," *> expr)
             special ")"
             k <- tupleOf (length es + 1)
             pure (foldl EApp (ECon k) (e : es))
        ]
  ]
  where
    opValue = opExpr <$> (varSym <|> conSym)
    -- (.name) and (.pos.x): the function that reads that field
    selector = do
      fs <- many1 proj
      special ")"
      pure (ELam [PVar "_sel"] (foldl (\x f -> EField x f []) (EVar "_sel") fs))
    rightSection = do
      op <- operator
      when (op == "-") (fail "negation")
      e <- expr
      special ")"
      pure (ELam [PVar "sec'"] (EApp (EApp (opExpr op) (EVar "sec'")) e))

opExpr :: Name -> Expr
opExpr op = if isConName op then ECon op else EVar op

-- Fixity resolution --------------------------------------------------------

type Fixities = M.Map Name (Assoc, Int)

-- | Resolves operators with the fixities a module declares and those of the
-- modules before it.
resolveFixity :: [(Name, (Assoc, Int))] -> [Decl] -> [Decl]
resolveFixity before ds = map (rDecl fixities) ds
  where
    fixities = M.fromList ((":", (AssocR, 5)) : before ++ fixitiesOf ds)

-- | The fixities declared anywhere in a module.
fixitiesOf :: [Decl] -> [(Name, (Assoc, Int))]
fixitiesOf ds = [(op, (a, p)) | DFixity a p ops <- allDecls ds, op <- ops]

allDecls :: [Decl] -> [Decl]
allDecls ds = ds ++ concat [concatMap whereDecls cs | DBind _ cs <- ds]
  ++ concat [allDecls b | DClass _ _ _ _ b <- ds] ++ concat [allDecls b | DInstance _ _ _ _ b <- ds]
  where whereDecls (Clause _ (Rhs _ w)) = allDecls w

rDecl :: Fixities -> Decl -> Decl
rDecl fx (DBind n cs) = DBind n [Clause ps (rRhs fx r) | Clause ps r <- cs]
rDecl fx (DClass sup c vs deps ds) = DClass sup c vs deps (map (rDecl fx) ds)
rDecl fx (DInstance l ctx c t ds) = DInstance l ctx c t (map (rDecl fx) ds)
rDecl _ d = d

rRhs :: Fixities -> Rhs -> Rhs
rRhs fx (Rhs alts w) = Rhs [(rExpr fx <$> g, rExpr fx e) | (g, e) <- alts] (map (rDecl fx) w)

rExpr :: Fixities -> Expr -> Expr
rExpr fx = go
  where
    go e = case e of
      EApp a b -> EApp (go a) (go b)
      ELam ps b -> ELam ps (go b)
      ELet ds b -> ELet (map (rDecl fx) ds) (go b)
      EIf a b c -> EIf (go a) (go b) (go c)
      ECase s alts -> ECase (go s) [Alt p (rRhs fx r) | Alt p r <- alts]
      EDo ss -> EDo (map stmtR ss)
      EOpSeq e0 rest -> climb (go e0) [(op, go x) | (op, x) <- rest]
      EAnn x t -> EAnn (go x) t
      EField x f c -> EField (go x) f c
      ERecCon k fs -> ERecCon k [(l, go v) | (l, v) <- fs]
      ERecUpd x fs c -> ERecUpd (go x) [(l, go v) | (l, v) <- fs] c
      ELoc l x -> ELoc l (go x)
      _ -> e
    stmtR (SBind x e) = SBind x (go e)
    stmtR (SBindPat p e) = SBindPat p (go e)
    stmtR (SLet ds) = SLet (map (rDecl fx) ds)
    stmtR (SExpr e) = SExpr (go e)
    fixOf (op, _) = fromMaybe (AssocL, 9) (M.lookup op fx)
    prec = snd . fixOf
    climb lhs0 rest0 = let (lhs, rest) = unneg lhs0 rest0 in fst (loop 0 lhs rest)
    -- A minus is negation, of precedence 6, as in Haskell: a negated
    -- operand takes the operators after it that bind tighter (7 and up,
    -- as * and ^) before negate applies, so -2 ^ 2 is -(2 ^ 2) and - a + b
    -- is (-a) + b. After any operator it negates what follows it too:
    -- x < -0.4, and a * -b (which Haskell refuses) is a * (-b).
    unneg x rest =
      let (x', rest1) = operandWith x rest
       in case rest1 of
            [] -> (x', [])
            (op, y) : more -> let (y', more') = unneg y more in (x', (op, y') : more')
    operandWith x rest = case x of
      -- after renaming: the Prelude's names are their own
      EApp (EVar m) operand | m == negated ->
        let (tight, after) = span ((> 6) . prec . fst) rest
            (operand', tight') = unneg operand tight
         in (EApp (EVar "negate") (fst (loop 0 operand' tight')), after)
      _ -> (x, rest)
    -- precedence climbing over e0 op1 e1 op2 e2 ...
    loop minP lhs ((op, r) : rest)
      | prec op >= minP =
          let (r', rest') = inner op r rest
           in loop minP (bin op lhs r') rest'
    loop _ lhs rest = (lhs, rest)
    inner op r rest@((op2, _) : _)
      | prec op2 > prec op || (prec op2 == prec op && fst (fixOf op2) == AssocR) =
          let (r', rest') = loop (if prec op2 > prec op then prec op + 1 else prec op) r rest
           in inner op r' rest'
    inner _ r rest = (r, rest)
    -- an operator's application is where the operator is, so that what
    -- it asks of its operands' types is reported there
    bin (op, l) a b = ELoc l (EApp (EApp (opExpr op) a) b)

localDecls :: Parser [Decl]
localDecls = groupClauses . concat <$> block decl
