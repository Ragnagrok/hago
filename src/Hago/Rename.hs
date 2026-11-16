{-# LANGUAGE LambdaCase #-}

-- | Resolves names across modules. Every top-level name becomes an internal
-- name qualified by its module ("Geometry.Shapes.area"), so the rest of the
-- compiler sees one flat program. The Prelude keeps its names unqualified,
-- and Main's main is "main".
--
-- Scoping: locals shadow everything, a module's own definitions shadow what
-- it imports, and a name imported from two modules with different meanings
-- is ambiguous. Instances are global, as in Haskell.
module Hago.Rename (Table (..), Renamed (..), renameModule, moduleQualify) where

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
  , scFields :: M.Map Name [Name]          -- ^ a field name to the record types that have it, if their constructors are visible
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
    types = M.fromList [(n, q n) | n <- [ddName d | DData d <- ds] ++ [t | DType t _ _ <- ds] ++ [c | DClass _ c _ _ _ <- ds]]
    valueNames = nub $
      [n | DBind n _ <- ds] ++ [n | DSig ns _ _ <- ds, n <- ns] ++ [n | DForeign _ n _ <- ds]
        ++ [k | DData d <- ds, ConDecl k _ _ <- ddCons d] ++ methods
    methods = [n | DClass _ _ _ _ body <- ds, DSig ns _ _ <- body, n <- ns]
    children = M.fromList $
      [(ddName d, [k | ConDecl k _ _ <- ddCons d]) | DData d <- ds]
        ++ [(c, [n | DSig ns _ _ <- body, n <- ns]) | DClass _ c _ _ body <- ds]

-- | The part of a table a module lets others see: its own names, the names
-- it imports, and whole modules it imports (@module M@). Children maps a
-- type's internal name to its constructors or methods.
exportsOf :: M.Map Name [Name] -> [(Import, (M.Map Name Name, M.Map Name Name))] -> Table -> Module -> Rn Table
exportsOf children brought ownT m = case modExports m of
  Nothing -> pure ownT
  Just items -> do
    picked <- mapM pick items
    vals <- merge (concatMap fst picked)
    types <- merge (concatMap snd picked)
    pure (Table vals types (M.map (\i -> M.findWithDefault [] i children) types))
  where
    unq f = M.fromListWith (++) [(k, [v]) | (imp, bs) <- brought, not (impQualified imp), (k, v) <- M.toList (f bs)]
    -- own names shadow imported ones, as inside the module
    lookupIn ownMap impMap x = case M.lookup x ownMap of
      Just i -> pure (Just i)
      Nothing -> case nub (M.findWithDefault [] x impMap) of
        [] -> pure Nothing
        [i] -> pure (Just i)
        is -> failExport (x ++ " is ambiguous: it could be " ++ intercalate " or " (sort is))
    val = lookupIn (tVals ownT) (unq fst)
    typ = lookupIn (tTypes ownT) (unq snd)
    notDefined x = failExport (x ++ " is not in scope")
    failExport msg = Left (showLoc (modLoc m) ++ ": in the export list of " ++ modName m ++ ": " ++ msg)
    pick = \case
      IVar x -> val x >>= maybe (notDefined x) (\i -> pure ([(x, i)], []))
      IType x sub -> typ x >>= \case
        Nothing -> notDefined x
        Just i -> do
          let kids = case sub of
                SubNone -> []
                SubAll -> M.findWithDefault [] i children
                SubSome ns -> ns
          vs <- forM kids (\k -> fmap ((,) k) <$> val k)
          pure ([v | Just v <- vs], [(x, i)])
      IModule q
        | q == modName m -> pure (M.toList (tVals ownT), M.toList (tTypes ownT))
        | otherwise -> case [bs | (imp, bs) <- brought, not (impQualified imp), fromMaybe (impModule imp) (impAs imp) == q] of
            [] -> failExport ("module " ++ q ++ " is not imported, or only qualified")
            bss -> pure (concatMap (M.toList . fst) bss, concatMap (M.toList . snd) bss)
    merge = foldM add M.empty
    add acc (k, v) = case M.lookup k acc of
      Just v' | v' /= v -> failExport ("two things named " ++ k ++ " are exported: " ++ v' ++ " and " ++ v)
      _ -> pure (M.insert k v acc)

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
      IModule _ -> []
    (onlyV, onlyT) = maybe (S.empty, S.empty) named (impOnly imp)
    (hideV, hideT) = named (impHiding imp)
    keepV k _ = maybe True (const (S.member k onlyV)) (impOnly imp) && not (S.member k hideV)
    keepT k _ = maybe True (const (S.member k onlyT)) (impOnly imp) && not (S.member k hideT)

-- | What renaming a module gives the modules after it.
data Renamed = Renamed
  { rnExports :: M.Map Name Table             -- ^ what each module exports
  , rnChildren :: M.Map Name [Name]           -- ^ a type's or class's internal name to its constructors or methods
  , rnFields :: M.Map Name [(Name, [Name])]   -- ^ a field name to the record types that have it, and their constructors
  }

instance Semigroup Renamed where
  a <> b = Renamed (M.union (rnExports a) (rnExports b)) (M.union (rnChildren a) (rnChildren b)) (M.unionWith (++) (rnFields a) (rnFields b))

instance Monoid Renamed where
  mempty = Renamed M.empty M.empty M.empty

-- | Renames one module, given what the modules before it give: its
-- dependencies come first, so what a module exports, which can include what
-- it imports, is known before anyone imports it. Returns the declarations
-- and what the module gives.
renameModule :: Renamed -> Module -> Rn ([Decl], Renamed)
renameModule before m = do
  let ownTable = tableOf m
      q = moduleQualify (modName m)
      ownChildren = M.fromList [(i, M.findWithDefault [] k (tChildren ownTable)) | (k, i) <- M.toList (tTypes ownTable)]
      ownFields = M.fromListWith (++)
        [ (lab, [(q (ddName d), map q ks)])
        | DData d <- modDecls m
        , let ks = [k | ConDecl k _ _ <- ddCons d], lab <- nub (concat [ls | ConDecl _ _ ls <- ddCons d]) ]
      children = M.union (rnChildren before) ownChildren
      fields = M.unionWith (++) (rnFields before) ownFields
  brought <- importsOf (rnExports before) m
  exports <- exportsOf children brought ownTable m
  ds <- renameDecls (M.insert (modName m) exports (rnExports before)) brought fields ownTable m
  pure (ds, Renamed (M.singleton (modName m) exports) ownChildren ownFields)

-- | Each import of a module, with what it brings.
importsOf :: M.Map Name Table -> Module -> Rn [(Import, (M.Map Name Name, M.Map Name Name))]
importsOf exportTables m = do
  let explicitPrelude = any ((== "Prelude") . impModule) (modImports m)
      implicit = [Import "Prelude" False Nothing Nothing [] ("", 0, 0) | modName m /= "Prelude", not explicitPrelude]
  forM (modImports m ++ implicit) $ \imp -> case M.lookup (impModule imp) exportTables of
    Nothing -> Left (showLoc (impLoc imp) ++ ": unknown module " ++ impModule imp)
    Just t -> pure (imp, imported imp t)

-- | The fields of a record type can be used wherever one of its constructors
-- is in scope, qualified or not: a type exported abstractly keeps them hidden.
renameDecls :: M.Map Name Table -> [(Import, (M.Map Name Name, M.Map Name Name))] -> M.Map Name [(Name, [Name])] -> Table -> Module -> Rn [Decl]
renameDecls exportTables brought fields ownTable m = do
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
        , scFields = M.map (\ts -> [t | (t, ks) <- ts, any (`S.member` visible) ks]) fields
        , scLocals = S.empty
        , scLoc = Nothing
        , scModule = modName m
        }
      visible = S.fromList (M.elems (tVals ownTable) ++ concat (M.elems (unq fst)) ++ M.elems (qual fst))
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
  DData d -> do
    let sc' = sc {scLoc = Just (ddLoc d)}
    cons' <- forM (ddCons d) $ \(ConDecl k fs ls) ->
      ConDecl (own sc k) <$> mapM (\(lz, t) -> (,) lz <$> rnType sc' t) fs <*> pure ls
    derivs <- mapM (resolveType sc') (ddDeriving d)
    pure (DData d {ddName = own sc (ddName d), ddCons = cons', ddDeriving = derivs})
  DType n ps t -> DType (own sc n) ps <$> rnType sc t
  DSig ns ctx t -> DSig (map (own sc) ns) <$> rnContext sc ctx <*> rnType sc t
  DBind n cs -> DBind (own sc n) <$> mapM (rnClause sc) cs
  DClass sup c vs deps body -> do
    sup' <- rnContext sc sup
    body' <- forM body $ \case
      DSig ns ctx t -> DSig (map (own sc) ns) <$> rnContext sc ctx <*> rnType sc t
      DBind n cs -> DBind (own sc n) <$> mapM (rnClause sc) cs
      d -> pure d
    pure (DClass sup' (own sc c) vs deps body')
  DInstance l ctx c ts body -> do
    let sc' = sc {scLoc = l}
    c' <- resolveType sc' c
    ctx' <- rnContext sc' ctx
    t' <- mapM (rnType sc') ts
    body' <- forM body $ \case
      DBind n cs -> DBind (methodOf c' n) <$> mapM (rnClause sc) cs
      d -> pure d
    pure (DInstance l ctx' c' t' body')
  DFixity a p ops -> pure (DFixity a p [M.findWithDefault op op (scOwnVals sc) | op <- ops])
  DForeign s n t -> DForeign s (own sc n) <$> rnType sc t

rnContext :: Scope -> Context -> Rn Context
rnContext sc = mapM (\(c, ts) -> (,) <$> resolveType sc c <*> mapM (rnType sc) ts)

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
  PRec _ fs -> concatMap (patVars . snd) fs
  PLoc _ p -> patVars p
  _ -> []

rnPat :: Scope -> Pat -> Rn Pat
rnPat sc = \case
  PCon k ps -> PCon <$> resolveVal sc k <*> mapM (rnPat sc) ps
  PAs x p -> PAs x <$> rnPat sc p
  PRec k fs -> PRec <$> resolveVal sc k <*> mapM (\(l, p) -> (,) l <$> rnPat sc p) fs
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
  EField x f _ -> EField <$> rnExpr sc x <*> pure f <*> pure (M.findWithDefault [] f (scFields sc))
  ERecCon k fs -> ERecCon <$> resolveVal sc k <*> mapM (\(l, v) -> (,) l <$> rnExpr sc v) fs
  ERecUpd x fs _ -> do
    let cands = foldr1 (\a b -> filter (`elem` b) a) [M.findWithDefault [] l (scFields sc) | (l, _) <- fs]
    ERecUpd <$> rnExpr sc x <*> mapM (\(l, v) -> (,) l <$> rnExpr sc v) fs <*> pure cands
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
