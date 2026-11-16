{-# LANGUAGE LambdaCase #-}

-- | Resolves names across modules. Every top-level name becomes an internal
-- name qualified by its module ("Geometry.Shapes.area"), so the rest of the
-- compiler sees one flat program. The Prelude keeps its names unqualified,
-- and Main's main is "main".
--
-- Scoping: locals shadow everything, a module's own definitions shadow what
-- it imports, and a name imported from two modules with different meanings
-- is ambiguous. Instances are global, as in Haskell.
module Hago.Rename (renameModules, moduleQualify) where

import Control.Monad
import Data.List (intercalate, nub, sort)
import qualified Data.Map as M
import Data.Maybe (fromMaybe)
import qualified Data.Set as S
import Hago.Syntax

-- | What a module defines at the top, by surface name.
data Table = Table
  { tVals :: M.Map Name Name               -- ^ functions, constructors, methods, foreign imports
  , tTypes :: M.Map Name Name              -- ^ data types and classes
  , tChildren :: M.Map Name [Name]         -- ^ a type's constructors, a class's methods
  }

data Scope = Scope
  { scOwnVals :: M.Map Name Name
  , scOwnTypes :: M.Map Name Name
  , scVals :: M.Map Name [Name]            -- ^ unqualified imports, possibly ambiguous
  , scTypes :: M.Map Name [Name]
  , scQVals :: M.Map (Name, Name) Name     -- ^ (module or alias, name)
  , scQTypes :: M.Map (Name, Name) Name
  , scLocals :: S.Set Name
  , scLoc :: Maybe Loc
  , scModule :: Name
  }

type Rn = Either String

moduleQualify :: Name -> Name -> Name
moduleQualify m x
  | m == "Prelude" = x
  | m == "Main" && x == "main" = "main"
  | otherwise = m ++ "." ++ x

tableOf :: Module -> Table
tableOf m = Table vals types children
  where
    q = moduleQualify (modName m)
    ds = modDecls m
    vals = M.fromList [(n, q n) | n <- valueNames]
    types = M.fromList [(n, q n) | n <- [t | DData t _ _ _ <- ds] ++ [c | DClass _ c _ _ <- ds]]
    valueNames = nub $
      [n | DBind n _ <- ds] ++ [n | DSig ns _ _ <- ds, n <- ns] ++ [n | DForeign _ n _ <- ds]
        ++ [k | DData _ _ cs _ <- ds, ConDecl k _ <- cs] ++ methods
    methods = [n | DClass _ _ _ body <- ds, DSig ns _ _ <- body, n <- ns]
    children = M.fromList $
      [(t, [k | ConDecl k _ <- cs]) | DData t _ cs _ <- ds]
        ++ [(c, [n | DSig ns _ _ <- body, n <- ns]) | DClass _ c _ body <- ds]

-- | The part of a table a module lets others see.
exportsOf :: Module -> Table -> Rn Table
exportsOf m t = case modExports m of
  Nothing -> pure t
  Just items -> do
    picked <- mapM pick items
    let vs = concat [v | (v, _) <- picked]
        ts = concat [ty | (_, ty) <- picked]
    pure (Table (M.restrictKeys (tVals t) (S.fromList vs)) (M.restrictKeys (tTypes t) (S.fromList ts)) (tChildren t))
  where
    pick = \case
      IVar x
        | M.member x (tVals t) -> pure ([x], [])
        | otherwise -> Left (modName m ++ ": exports " ++ x ++ ", which it does not define")
      IType x sub
        | M.member x (tTypes t) -> pure (subNames x sub, [x])
        | otherwise -> Left (modName m ++ ": exports " ++ x ++ ", which it does not define")
    subNames x = \case
      SubNone -> []
      SubAll -> M.findWithDefault [] x (tChildren t)
      SubSome ns -> ns

-- | What an import brings, after its list or hiding clause.
imported :: Import -> Table -> (M.Map Name Name, M.Map Name Name)
imported imp t = (M.filterWithKey keepV (tVals t), M.filterWithKey keepT (tTypes t))
  where
    named items = (S.fromList (concatMap valsOf items), S.fromList [x | IType x _ <- items])
    valsOf = \case
      IVar x -> [x]
      IType x SubAll -> M.findWithDefault [] x (tChildren t)
      IType _ (SubSome ns) -> ns
      IType _ SubNone -> []
    (onlyV, onlyT) = maybe (S.empty, S.empty) named (impOnly imp)
    (hideV, hideT) = named (impHiding imp)
    keepV k _ = maybe True (const (S.member k onlyV)) (impOnly imp) && not (S.member k hideV)
    keepT k _ = maybe True (const (S.member k onlyT)) (impOnly imp) && not (S.member k hideT)

-- | Renames every module (the Prelude first) into one list of declarations.
renameModules :: [Module] -> Rn [Decl]
renameModules mods = do
  let tables = M.fromList [(modName m, tableOf m) | m <- mods]
  exportTables <- M.fromList <$> forM mods (\m -> (,) (modName m) <$> exportsOf m (tables M.! modName m))
  concat <$> forM mods (\m -> renameModule exportTables (tables M.! modName m) m)

renameModule :: M.Map Name Table -> Table -> Module -> Rn [Decl]
renameModule exportTables ownTable m = do
  let explicitPrelude = any ((== "Prelude") . impModule) (modImports m)
      implicit = [Import "Prelude" False Nothing Nothing [] ("", 0, 0) | modName m /= "Prelude", not explicitPrelude]
      imports = modImports m ++ implicit
  brought <- forM imports $ \imp -> case M.lookup (impModule imp) exportTables of
    Nothing -> Left (showLoc (impLoc imp) ++ ": unknown module " ++ impModule imp)
    Just t -> pure (imp, imported imp t)
  let prelude = M.findWithDefault (Table M.empty M.empty M.empty) "Prelude" exportTables
      unq f = M.fromListWith (++) [(k, [v]) | (imp, bs) <- brought, not (impQualified imp), (k, v) <- M.toList (f bs)]
      qual f = M.fromList $
        [((alias, k), v) | (imp, bs) <- brought, let alias = fromMaybe (impModule imp) (impAs imp), (k, v) <- M.toList (f bs)]
          ++ [(("Prelude", k), v) | (k, v) <- M.toList (f (tVals prelude, tTypes prelude))]
          ++ [((modName m, k), v) | (k, v) <- M.toList (f (tVals ownTable, tTypes ownTable))]
      scope = Scope
        { scOwnVals = tVals ownTable
        , scOwnTypes = tTypes ownTable
        , scVals = unq fst
        , scTypes = unq snd
        , scQVals = qual fst
        , scQTypes = qual snd
        , scLocals = S.empty
        , scLoc = Nothing
        , scModule = modName m
        }
  mapM (topDecl scope) (modDecls m)

-- Resolution ----------------------------------------------------------------------

failAt :: Scope -> String -> Rn a
failAt sc msg = Left (maybe "" ((++ ": ") . showLoc) (scLoc sc) ++ msg)

resolveVal :: Scope -> Name -> Rn Name
resolveVal sc x
  | S.member x (scLocals sc) = pure x
  | otherwise = case splitQual x of
      (Nothing, n) -> case M.lookup n (scOwnVals sc) of
        Just i -> pure i
        Nothing -> pick n (M.findWithDefault [] n (scVals sc))
      (Just q, n) -> case M.lookup (q, n) (scQVals sc) of
        Just i -> pure i
        -- the Prelude also reaches the primitives and built-in constructors
        Nothing | q == "Prelude" -> pure n
        Nothing -> failAt sc ("not in scope: " ++ x)
  where
    pick n = \case
      [] -> pure n   -- unknown: the type checker reports it
      is -> case nub is of
        [i] -> pure i
        is' -> failAt sc ("ambiguous name " ++ n ++ ": it could be " ++ intercalate " or " (sort is'))

resolveType :: Scope -> Name -> Rn Name
resolveType sc x = case splitQual x of
  (Nothing, n) -> case M.lookup n (scOwnTypes sc) of
    Just i -> pure i
    Nothing -> case nub (M.findWithDefault [] n (scTypes sc)) of
      [] -> pure n
      [i] -> pure i
      is -> failAt sc ("ambiguous type " ++ n ++ ": it could be " ++ intercalate " or " (sort is))
  (Just q, n) -> case M.lookup (q, n) (scQTypes sc) of
    Just i -> pure i
    Nothing | q == "Prelude" -> pure n
    Nothing -> failAt sc ("not in scope: " ++ x)

own :: Scope -> Name -> Name
own sc = moduleQualify (scModule sc)

-- | A method's internal name, from its class's.
methodOf :: Name -> Name -> Name
methodOf cls m = maybe m (\q -> q ++ "." ++ m) (fst (splitQual cls))

-- Declarations --------------------------------------------------------------------

topDecl :: Scope -> Decl -> Rn Decl
topDecl sc = \case
  DData n ps cons ds -> do
    cons' <- forM cons $ \(ConDecl k fs) -> ConDecl (own sc k) <$> mapM (\(lz, t) -> (,) lz <$> rnType sc t) fs
    pure (DData (own sc n) ps cons' ds)
  DSig ns ctx t -> DSig (map (own sc) ns) <$> rnContext sc ctx <*> rnType sc t
  DBind n cs -> DBind (own sc n) <$> mapM (rnClause sc) cs
  DClass sup c v body -> do
    sup' <- rnContext sc sup
    body' <- forM body $ \case
      DSig ns ctx t -> DSig (map (own sc) ns) <$> rnContext sc ctx <*> rnType sc t
      DBind n cs -> DBind (own sc n) <$> mapM (rnClause sc) cs
      d -> pure d
    pure (DClass sup' (own sc c) v body')
  DInstance l ctx c t body -> do
    let sc' = sc {scLoc = l}
    c' <- resolveType sc' c
    ctx' <- rnContext sc' ctx
    t' <- rnType sc' t
    body' <- forM body $ \case
      DBind n cs -> DBind (methodOf c' n) <$> mapM (rnClause sc) cs
      d -> pure d
    pure (DInstance l ctx' c' t' body')
  DFixity a p ops -> pure (DFixity a p [M.findWithDefault op op (scOwnVals sc) | op <- ops])
  DForeign s n t -> DForeign s (own sc n) <$> rnType sc t

rnContext :: Scope -> Context -> Rn Context
rnContext sc = mapM (\(c, v) -> (,) <$> resolveType sc c <*> pure v)

rnType :: Scope -> SType -> Rn SType
rnType sc = \case
  STVar v -> pure (STVar v)
  STCon c ts -> STCon <$> resolveType sc c <*> mapM (rnType sc) ts
  STFun a b -> STFun <$> rnType sc a <*> rnType sc b
  STApp h ts -> STApp <$> rnType sc h <*> mapM (rnType sc) ts

-- Expressions -----------------------------------------------------------------------

bind :: Scope -> [Name] -> Scope
bind sc ns = sc {scLocals = foldr S.insert (scLocals sc) ns}

patVars :: Pat -> [Name]
patVars = \case
  PVar x -> [x]
  PAs x p -> x : patVars p
  PCon _ ps -> concatMap patVars ps
  PLoc _ p -> patVars p
  _ -> []

rnPat :: Scope -> Pat -> Rn Pat
rnPat sc = \case
  PCon k ps -> PCon <$> resolveVal sc k <*> mapM (rnPat sc) ps
  PAs x p -> PAs x <$> rnPat sc p
  PLoc l p -> PLoc l <$> rnPat sc {scLoc = Just l} p
  p -> pure p

rnClause :: Scope -> Clause -> Rn Clause
rnClause sc (Clause ps r) = Clause <$> mapM (rnPat sc) ps <*> rnRhs (bind sc (concatMap patVars ps)) r

rnRhs :: Scope -> Rhs -> Rn Rhs
rnRhs sc (Rhs alts ws) = do
  (sc', ws') <- rnLocals sc ws
  alts' <- forM alts $ \(g, e) -> (,) <$> traverse (rnExpr sc') g <*> rnExpr sc' e
  pure (Rhs alts' ws')

-- | let and where: the bound names are visible in every binding and the body.
rnLocals :: Scope -> [Decl] -> Rn (Scope, [Decl])
rnLocals sc ds = do
  let sc' = bind sc [n | DBind n _ <- ds]
  ds' <- forM ds $ \case
    DBind n cs -> DBind n <$> mapM (rnClause sc') cs
    DSig ns ctx t -> DSig ns <$> rnContext sc' ctx <*> rnType sc' t
    d -> pure d
  pure (sc', ds')

rnExpr :: Scope -> Expr -> Rn Expr
rnExpr sc = \case
  EVar x -> EVar <$> resolveVal sc x
  ECon k -> ECon <$> resolveVal sc k
  ELit l -> pure (ELit l)
  EApp f a -> EApp <$> rnExpr sc f <*> rnExpr sc a
  ELam ps b -> ELam <$> mapM (rnPat sc) ps <*> rnExpr (bind sc (concatMap patVars ps)) b
  ELet ds b -> do
    (sc', ds') <- rnLocals sc ds
    ELet ds' <$> rnExpr sc' b
  EIf a b c -> EIf <$> rnExpr sc a <*> rnExpr sc b <*> rnExpr sc c
  ECase s alts -> ECase <$> rnExpr sc s <*> forM alts (\(Alt p r) -> Alt <$> rnPat sc p <*> rnRhs (bind sc (patVars p)) r)
  EDo ss -> EDo <$> rnStmts sc ss
  EOpSeq e0 rest -> EOpSeq <$> rnExpr sc e0 <*> forM rest (\(op, x) -> (,) <$> resolveVal sc op <*> rnExpr sc x)
  EAnn x t -> EAnn <$> rnExpr sc x <*> rnType sc t
  ELoc l x -> ELoc l <$> rnExpr sc {scLoc = Just l} x

rnStmts :: Scope -> [Stmt] -> Rn [Stmt]
rnStmts sc = \case
  [] -> pure []
  SBind x e : rest -> (:) <$> (SBind x <$> rnExpr sc e) <*> rnStmts (bind sc [x]) rest
  SBindPat p e : rest -> (:) <$> (SBindPat <$> rnPat sc p <*> rnExpr sc e) <*> rnStmts (bind sc (patVars p)) rest
  SLet ds : rest -> do
    (sc', ds') <- rnLocals sc ds
    (SLet ds' :) <$> rnStmts sc' rest
  SExpr e : rest -> (:) <$> (SExpr <$> rnExpr sc e) <*> rnStmts sc rest
