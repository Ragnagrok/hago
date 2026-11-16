{-# LANGUAGE LambdaCase #-}

-- | Parser from tokens (after layout) to the surface syntax, plus fixity
-- resolution of operator sequences.
module Hago.Parser (parseModule, resolveFixity) where

import Control.Monad
import Data.List (groupBy)
import qualified Data.Map as M
import Data.Maybe (fromMaybe)
import Hago.Lexer
import Hago.Syntax
import Text.Parsec hiding (token, tokens)
import Text.Parsec.Pos (initialPos)
import qualified Text.Parsec as P

type Parser = Parsec [Token] ()

parseModule :: FilePath -> String -> Either String [Decl]
parseModule file src = do
  toks <- either (\e -> Left (file ++ ":" ++ e)) Right (lexer src)
  ds <- either (Left . show) Right (runParser pModule () file (layout toks))
  pure (groupClauses ds)

-- Token primitives -----------------------------------------------------------

satisfyT :: (Tok -> Maybe a) -> Parser a
satisfyT f = P.token (show . tokVal) pos (f . tokVal)
  where pos t = newPos' (tokLine t) (tokCol t)
        newPos' l c = setSourceColumn (setSourceLine (initialPos "") l) c

tokEq :: Tok -> Parser ()
tokEq t = satisfyT (\x -> if x == t then Just () else Nothing) <?> show t

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

pModule :: Parser [Decl]
pModule = do
  optional (key "module" >> conId >> key "where")
  ds <- block topDecl
  eof
  pure (concat ds)

topDecl :: Parser [Decl]
topDecl = choice
  [ pure <$> dataDecl
  , pure <$> foreignDecl
  , pure <$> classDecl
  , pure <$> instanceDecl
  , [] <$ (key "import" >> skipMany1 (satisfyT notSemi))
  , decl
  ]
  where notSemi (TSpecial ";") = Nothing
        notSemi (TSpecial "}") = Nothing
        notSemi _ = Just ()

dataDecl :: Parser Decl
dataDecl = do
  key "data" <|> key "newtype"
  name <- conId
  params <- many varId
  key "="
  cons <- conDecl `sepBy1` key "|"
  derivs <- option [] (key "deriving" >> ((pure <$> conId) <|> parens (conId `sepBy` special ",")))
  pure (DData name params cons derivs)

-- | An optional context, as in @(Eq a, Show b) =>@.
context :: Parser Context
context = option [] (try (preds <* key "=>"))
  where
    preds = (pure <$> predicate) <|> parens (predicate `sepBy` special ",")
    predicate = (,) <$> conId <*> varId

classDecl :: Parser Decl
classDecl = do
  key "class"
  supers <- context
  cls <- conId
  v <- varId
  body <- option [] (key "where" >> localDecls)
  pure (DClass supers cls v body)

instanceDecl :: Parser Decl
instanceDecl = do
  key "instance"
  ctx <- context
  cls <- conId
  t <- aType
  body <- option [] (key "where" >> localDecls)
  pure (DInstance ctx cls t body)

conDecl :: Parser ConDecl
conDecl = try infixCon <|> prefixCon
  where
    prefixCon = ConDecl <$> (conId <|> try (parens conSym)) <*> many field
    infixCon = do
      l <- field
      op <- conSym
      r <- field
      pure (ConDecl op [l, r])
    field = ((,) True <$> (key "~" *> aType))
        <|> ((,) False <$> (optional (tokEq (TVarSym "!")) *> aType))

foreignDecl :: Parser Decl
foreignDecl = do
  key "foreign" >> key "import"
  lang <- varId
  unless (lang == "go") (fail "only `foreign import go` is supported")
  sym <- satisfyT (\t -> case t of TStr s -> Just s; _ -> Nothing)
  name <- var
  key "::"
  DForeign sym name <$> pType

-- | Declarations allowed in let/where and at the top: signatures, fixity
-- declarations and function clauses.
decl :: Parser [Decl]
decl = fixity <|> try sig <|> (pure <$> binding)
  where
    sig = do
      names <- var `sepBy1` special ","
      key "::"
      ctx <- context
      t <- pType
      pure [DSig names ctx t]
    fixity = do
      assoc <- (AssocL <$ key "infixl") <|> (AssocR <$ key "infixr") <|> (AssocN <$ key "infix")
      prec <- option 9 (satisfyT (\t -> case t of TInt n -> Just (fromInteger n); _ -> Nothing))
      ops <- operator `sepBy1` special ","
      pure [DFixity assoc prec ops]

binding :: Parser Decl
binding = try infixDef <|> prefixDef
  where
    prefixDef = do
      name <- var
      ps <- many aPat
      r <- rhs (key "=")
      pure (DBind name [Clause ps r])
    infixDef = do
      l <- pat
      op <- varSym <|> (special "`" *> varId <* special "`")
      r <- pat
      body <- rhs (key "=")
      pure (DBind op [Clause [l, r] body])

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
      <|> try (do n <- many1 (special ","); special ")"; pure (STCon (tupleCon (length n + 1)) []))
      <|> do
      ts <- pType `sepBy1` special ","
      special ")"
      pure $ case ts of
        [t] -> t
        _ -> STCon (tupleCon (length ts)) ts

tupleCon :: Int -> Name
tupleCon n = "(" ++ replicate (n - 1) ',' ++ ")"

-- Patterns -------------------------------------------------------------------

pat :: Parser Pat
pat = do
  l <- lPat
  option l $ do
    op <- conSym
    r <- pat
    pure (PCon op [l, r])

lPat :: Parser Pat
lPat = try (PCon <$> conId <*> many1 aPat) <|> negLit <|> aPat
  where negLit = do
          tokEq (TVarSym "-")
          n <- satisfyT (\t -> case t of TInt i -> Just i; _ -> Nothing)
          pure (PLit (LInt (negate n)))

aPat :: Parser Pat
aPat = choice
  [ try (PAs <$> varId <* key "@") <*> aPat
  , PVar <$> var
  , PWild <$ key "_"
  , (`PCon` []) <$> conId
  , PLit <$> literal
  , listPat <$> brackets (pat `sepBy` special ",")
  , special "(" *> tuplePat
  ]
  where
    tuplePat = (PCon "()" [] <$ special ")") <|> do
      ps <- pat `sepBy1` special ","
      special ")"
      pure $ case ps of
        [p] -> p
        _ -> PCon (tupleCon (length ps)) ps
    listPat = foldr (\p acc -> PCon ":" [p, acc]) (PCon "[]" [])

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
  neg <- optionMaybe (tokEq (TVarSym "-"))
  e0 <- expr10
  let first = maybe e0 (const (EApp (EVar "negate") e0)) neg
  rest <- many (try ((,) <$> operator <*> expr10))
  let e = if null rest then first else EOpSeq first rest
  option e (EAnn e <$> (key "::" *> pType))

expr10 :: Parser Expr
expr10 = choice
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

aExpr :: Parser Expr
aExpr = choice
  [ EVar <$> varId
  , ECon <$> conId
  , ELit <$> literal
  , special "[" *> listExpr
  , special "(" *> parenExpr
  ]

listExpr :: Parser Expr
listExpr = (ECon "[]" <$ special "]") <|> do
  e <- expr
  choice
    [ do key ".."
         hi <- optionMaybe expr
         special "]"
         pure $ maybe (EApp (EVar "enumFrom") e) (EApp (EApp (EVar "enumFromTo") e)) hi
    , do es <- many (special "," *> expr)
         special "]"
         pure (foldr (\x acc -> EApp (EApp (ECon ":") x) acc) (ECon "[]") (e : es))
    ]

-- | After an opening parenthesis: unit, an operator as a value, a section, a
-- parenthesised expression or a tuple.
parenExpr :: Parser Expr
parenExpr = choice
  [ ECon "()" <$ special ")"
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
             pure (foldl EApp (ECon (tupleCon (length es + 1))) (e : es))
        ]
  ]
  where
    opValue = opExpr <$> (varSym <|> conSym)
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

resolveFixity :: [Decl] -> [Decl]
resolveFixity ds = map (rDecl fixities) ds
  where
    fixities = M.fromList ((":", (AssocR, 5)) : [(op, (a, p)) | DFixity a p ops <- allDecls ds, op <- ops])

allDecls :: [Decl] -> [Decl]
allDecls ds = ds ++ concat [concatMap whereDecls cs | DBind _ cs <- ds]
  ++ concat [allDecls b | DClass _ _ _ b <- ds] ++ concat [allDecls b | DInstance _ _ _ b <- ds]
  where whereDecls (Clause _ (Rhs _ w)) = allDecls w

rDecl :: Fixities -> Decl -> Decl
rDecl fx (DBind n cs) = DBind n [Clause ps (rRhs fx r) | Clause ps r <- cs]
rDecl fx (DClass sup c v ds) = DClass sup c v (map (rDecl fx) ds)
rDecl fx (DInstance ctx c t ds) = DInstance ctx c t (map (rDecl fx) ds)
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
      _ -> e
    stmtR (SBind x e) = SBind x (go e)
    stmtR (SBindPat p e) = SBindPat p (go e)
    stmtR (SLet ds) = SLet (map (rDecl fx) ds)
    stmtR (SExpr e) = SExpr (go e)
    fixOf op = fromMaybe (AssocL, 9) (M.lookup op fx)
    prec = snd . fixOf
    climb lhs rest = fst (loop 0 lhs rest)
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
    bin op a b = EApp (EApp (opExpr op) a) b

localDecls :: Parser [Decl]
localDecls = groupClauses . concat <$> block decl
