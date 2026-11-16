{-# LANGUAGE LambdaCase #-}

-- | Hindley-Milner type inference with type classes, which also elaborates
-- the program into the typed core. Laziness is type-directed: an expression
-- checked against @Lazy t@ is suspended, and a variable of type @Lazy t@ used
-- where a @t@ is expected is forced. Constraints become dictionaries.
module Hago.Typecheck (typecheck, primSchemes, pretty) where

import Control.Monad
import Control.Monad.State
import Data.Graph (flattenSCC, flattenSCCs, stronglyConnComp)
import qualified Data.IntMap as IM
import Data.List (nub)
import qualified Data.Map as M
import Hago.Core
import Hago.Syntax
import Hago.TcMonad

-- Primitives -------------------------------------------------------------------

-- | Built-in operations. The polymorphic ones are only used by the prelude's
-- instances, at types Go can compare and add natively.
primSchemes :: M.Map Name Scheme
primSchemes = M.fromList $
  [(op, Forall ["a"] [] (a ~> a ~> tBool)) | op <- ["primEq", "primNeq", "primLt", "primLe", "primGt", "primGe"]]
    ++ [(op, Forall ["a"] [] (a ~> a ~> a)) | op <- ["primAdd", "primSub", "primMul"]]
    ++ [ ("primNeg", Forall ["a"] [] (a ~> a))
       , ("primDiv", mono (tInt ~> tInt ~> tInt))
       , ("primMod", mono (tInt ~> tInt ~> tInt))
       , ("primQuot", mono (tInt ~> tInt ~> tInt))
       , ("primRem", mono (tInt ~> tInt ~> tInt))
       , ("primFDiv", mono (tDouble ~> tDouble ~> tDouble))
       , ("primShow", Forall ["a"] [] (a ~> tString))
       , ("primIntToDouble", mono (tInt ~> tDouble))
       , ("primTruncate", mono (tDouble ~> tInt))
       , ("putStrLn", mono (tString ~> tIO tUnit))
       , ("putStr", mono (tString ~> tIO tUnit))
       , ("getLine", mono (tIO tString))
       , ("primReturnIO", Forall ["a"] [] (a ~> tIO a))
       , ("primBindIO", Forall ["a", "b"] [] (tIO a ~> (a ~> tIO b) ~> tIO b))
       , ("primThenIO", Forall ["a", "b"] [] (tIO a ~> tLazy (tIO b) ~> tIO b))
       , ("error", Forall ["a"] [] (tString ~> a))
       , ("++", Forall ["a"] [] (a ~> tLazy a ~> a))
       , ("pack", mono (tList tChar ~> tString))
       , ("unpack", mono (tString ~> tList tChar))
       , ("ord", mono (tChar ~> tInt))
       , ("chr", mono (tInt ~> tChar))
       ]
  where
    a = TVar "a"
    b = TVar "b"
    mono = Forall [] []

infixr 5 ~>
(~>) :: Type -> Type -> Type
(~>) = TFun

builtinTypes :: M.Map Name Int
builtinTypes = M.fromList
  [ ("Int", 0), ("Double", 0), ("Bool", 0), ("Char", 0), ("String", 0), ("()", 0)
  , ("[]", 1), ("IO", 1), ("Lazy", 1), ("(,)", 2), ("(,,)", 3), ("->", 2) ]

builtinCons :: M.Map Name ConInfo
builtinCons = M.fromList
  [ ("[]", ConInfo "[]" ["a"] [] 0)
  , (":", ConInfo "[]" ["a"] [(False, TVar "a"), (True, tList (TVar "a"))] 1)
  , ("()", ConInfo "()" [] [] 0)
  , ("False", ConInfo "Bool" [] [] 0)
  , ("True", ConInfo "Bool" [] [] 1)
  , ("(,)", ConInfo "(,)" ["a", "b"] [(False, TVar "a"), (False, TVar "b")] 0)
  , ("(,,)", ConInfo "(,,)" ["a", "b", "c"] [(False, TVar "a"), (False, TVar "b"), (False, TVar "c")] 0)
  ]

-- Types written by the programmer -----------------------------------------------

stypeVars :: SType -> [Name]
stypeVars = nub . go
  where
    go (STVar v) = [v]
    go (STCon _ ts) = concatMap go ts
    go (STFun a b) = go a ++ go b
    go (STApp h ts) = go h ++ concatMap go ts

-- | How many arguments each type variable is applied to: its kind, roughly.
stypeArities :: SType -> M.Map Name Int
stypeArities = \case
  STApp (STVar v) ts -> M.unionsWith max (M.singleton v (length ts) : map stypeArities ts)
  STApp h ts -> M.unionsWith max (stypeArities h : map stypeArities ts)
  STCon _ ts -> M.unionsWith max (map stypeArities ts)
  STFun a b -> M.unionWith max (stypeArities a) (stypeArities b)
  STVar _ -> M.empty

fromSType :: Env -> M.Map Name Type -> SType -> TC Type
fromSType env vars = go
  where
    go (STVar v) = maybe (throw ("type variable not in scope: " ++ v)) pure (M.lookup v vars)
    go (STFun a b) = TFun <$> go a <*> go b
    go (STApp h ts) = foldl tApp <$> go h <*> mapM go ts
    go (STCon c ts) = case M.lookup c (envTypes env) of
      Nothing -> throw ("unknown type: " ++ c)
      Just n
        | length ts > n -> throw ("type " ++ c ++ " expects " ++ show n ++ " arguments")
        | otherwise -> norm . TCon c <$> mapM go ts

rigid :: SType -> M.Map Name Type
rigid st = M.fromList [(v, TVar v) | v <- stypeVars st]

contextPreds :: Env -> Context -> TC [Pred]
contextPreds env ctx = forM ctx $ \(c, v) ->
  if M.member c (envClasses env) then pure (IsIn c (TVar v)) else throw ("unknown class: " ++ c)

-- Constructors ---------------------------------------------------------------------

lookupCon :: Env -> Name -> TC ConInfo
lookupCon env k = maybe (throw ("unknown constructor: " ++ k)) pure (M.lookup k (envCons env))

-- | Field types (lazy ones wrapped in Lazy) and result type, for given type arguments.
conSig :: ConInfo -> [Type] -> ([Type], Type)
conSig ci targs = (map field (ciFields ci), TCon (ciType ci) targs)
  where
    s = M.fromList (zip (ciParams ci) targs)
    field (lz, t) = (if lz then tLazy else id) (substT s t)

-- Expressions ---------------------------------------------------------------------

extend :: Env -> [(Name, Type)] -> Env
extend env bs = env {envVars = foldr (\(n, t) -> M.insert n (Forall [] [] t, False)) (envVars env) bs}

litType :: Lit -> Type
litType (LInt _) = tInt
litType (LDouble _) = tDouble
litType (LChar _) = tChar
litType (LStr _) = tString

inferVarRaw :: Env -> Name -> TC (CExpr, Type)
inferVarRaw env x = case M.lookup x (envVars env) of
  Nothing -> throw ("not in scope: " ++ x)
  Just (sc, self) -> do
    (t, targs, ds) <- instantiate sc
    pure (CVar x (if self then SelfGroup else Inst targs ds) t, t)

infer :: Env -> Expr -> TC (CExpr, Type)
infer env e = case e of
  EVar x -> do
    (c, t) <- inferVarRaw env x
    zonkT t >>= \case
      TCon "Lazy" [i] -> pure (CForce c, i)
      _ -> pure (c, t)
  ECon k -> do
    ci <- lookupCon env k
    targs <- mapM (const fresh) (ciParams ci)
    let (fs, r) = conSig ci targs
        t = foldr TFun r fs
    pure (CCon k targs t, t)
  ELit (LInt n) -> do
    t <- fresh
    d <- newHole (IsIn "Num" t)
    pure (CNum n t d, t)
  ELit (LDouble x) -> do
    t <- fresh
    d <- newHole (IsIn "Fractional" t)
    pure (CFrac x t d, t)
  ELit l -> pure (CLit l, litType l)
  EApp {} -> do
    let (f, args) = spine e
    (cf, tf) <- infer env f
    (cargs, tr) <- applyArgs tf args
    pure (CApp cf cargs, tr)
  EDo ss -> do
    m <- fresh
    d <- newHole (IsIn "Monad" m)
    (r, cs) <- doStmts env m ss
    pure (CDo m d r cs, tApp m r)
  EAnn x st -> do
    vs <- mapM (\v -> (,) v <$> fresh) (stypeVars st)
    t <- fromSType env (M.fromList vs) st
    c <- check env x t
    pure (c, t)
  _ -> do
    t <- fresh
    c <- check env e t
    pure (c, t)
  where
    spine (EApp f a) = let (h, as) = spine f in (h, as ++ [a])
    spine x = (x, [])
    applyArgs t [] = pure ([], t)
    applyArgs t (a : as) = do
      (p, r) <- splitArrow t
      ca <- check env a p
      (cas, tr) <- applyArgs r as
      pure (ca : cas, tr)

splitArrow :: Type -> TC (Type, Type)
splitArrow t =
  zonkT t >>= \case
    TFun p r -> pure (p, r)
    t' -> do
      p <- fresh
      r <- fresh
      unify t' (TFun p r)
      pure (p, r)

check :: Env -> Expr -> Type -> TC CExpr
check env e expected = do
  ex <- zonkT expected
  case (e, ex) of
    (_, TCon "Lazy" [inner]) -> case e of
      EVar x -> do
        (c, t) <- inferVarRaw env x
        zonkT t >>= \case
          t'@(TCon "Lazy" _) -> unify t' ex >> pure c
          t' -> unify t' inner >> pure (CDelay inner c)
      _ -> CDelay inner <$> check env e inner
    (ELam ps body, _) -> checkLam env ps body ex
    (EIf c a b, _) -> CIf <$> check env c tBool <*> check env a ex <*> check env b ex <*> pure ex
    (ECase s alts, _) -> do
      (cs, ts) <- infer env s
      rows <- forM alts $ \(Alt p r) -> do
        (cp, bs) <- checkPat env p ts
        (binds, guards) <- checkRhs (extend env bs) r ex
        pure (CRow [cp] binds guards)
      pure (CMatch [cs] rows ex)
    (ELet ds b, _) -> do
      (env', binds) <- localBinds env ds
      cb <- check env' b ex
      pure (CLet binds cb ex)
    _ -> do
      (c, t) <- infer env e
      adapt c t ex

-- | Unifies the inferred type with the expected one. When both are function
-- types that differ only in which parameters are Lazy, wraps the function
-- instead, forcing or suspending those arguments: this is what lets a strict
-- function such as @insert@ be passed to @foldr@.
adapt :: CExpr -> Type -> Type -> TC CExpr
adapt c actual expected = do
  a <- zonkT actual
  x <- zonkT expected
  if not (lazyMismatch a x)
    then unify a x >> pure c
    else do
      (params, args, r) <- go (0 :: Int) a x
      pure (CLam params r (CApp c args))
  where
    go i (TFun aq ar) (TFun xp xr) = do
      let n = "_adapt" ++ show i
          var = CVar n (Inst [] []) xp
      arg <- case (aq, xp) of
        (TCon "Lazy" _, TCon "Lazy" _) -> unify aq xp >> pure var
        (_, TCon "Lazy" [inner]) | not (isMeta aq) -> unify aq inner >> pure (CForce var)
        (TCon "Lazy" [inner], _) | not (isMeta xp) -> unify inner xp >> pure (CDelay xp var)
        _ -> unify aq xp >> pure var
      if lazyMismatch ar xr
        then do
          (ps, as, r) <- go (i + 1) ar xr
          pure ((n, xp) : ps, arg : as, r)
        else unify ar xr >> pure ([(n, xp)], [arg], xr)
    go _ _ _ = error "adapt: not a function"

lazyMismatch :: Type -> Type -> Bool
lazyMismatch (TFun a r1) (TFun x r2) =
  (isLazy a /= isLazy x && not (isMeta a) && not (isMeta x)) || lazyMismatch r1 r2
lazyMismatch _ _ = False

isLazy, isMeta :: Type -> Bool
isLazy (TCon "Lazy" _) = True
isLazy _ = False
isMeta (TMeta _) = True
isMeta _ = False

checkLam :: Env -> [Pat] -> Expr -> Type -> TC CExpr
checkLam env ps body ex = do
  (params, toMatch, bs, r) <- go (0 :: Int) ps ex
  cbody <- check (extend env bs) body r
  let core = case toMatch of
        [] -> cbody
        _ -> CMatch [CVar n (Inst [] []) t | (n, t, _) <- toMatch] [CRow [p | (_, _, p) <- toMatch] [] [(Nothing, cbody)]] r
  pure (CLam params r core)
  where
    go _ [] t = pure ([], [], [], t)
    go i (p : rest) t = do
      (pt, rt) <- splitArrow t
      (params, toMatch, bs, r) <- go (i + 1) rest rt
      case p of
        PVar x -> pure ((x, pt) : params, toMatch, (x, pt) : bs, r)
        _ -> do
          let n = "_lam" ++ show i
          (cp, pbs) <- checkPat env p pt
          pure ((n, pt) : params, (n, pt, cp) : toMatch, pbs ++ bs, r)

checkPat :: Env -> Pat -> Type -> TC (CPat, [(Name, Type)])
checkPat env p t = do
  t' <- zonkT t
  case (p, t') of
    (PVar x, _) -> pure (CPVar x t', [(x, t')])
    (PWild, _) -> pure (CPWild, [])
    (_, TCon "Lazy" [i]) -> do
      (cp, bs) <- checkPat env p i
      pure (CPForce cp, bs)
    (PAs x q, _) -> do
      (cq, bs) <- checkPat env q t'
      pure (CPAs x t' cq, (x, t') : bs)
    (PLit (LInt n), _) -> do
      dEq <- newHole (IsIn "Eq" t')
      dNum <- newHole (IsIn "Num" t')
      pure (CPNum n t' dEq dNum, [])
    (PLit l, _) -> unify t' (litType l) >> pure (CPLit l, [])
    (PCon k ps, _) -> do
      ci <- lookupCon env k
      when (length ps /= length (ciFields ci)) $
        throw ("constructor " ++ k ++ " expects " ++ show (length (ciFields ci)) ++ " arguments")
      targs <- mapM (const fresh) (ciParams ci)
      let (fs, r) = conSig ci targs
      unify t' r
      subs <- zipWithM (checkPat env) ps fs
      pure (CPCon k targs (map fst subs), concatMap snd subs)

checkRhs :: Env -> Rhs -> Type -> TC ([CBind], [(Maybe CExpr, CExpr)])
checkRhs env (Rhs alts wheres) t = do
  (env', binds) <- localBinds env wheres
  guards <- forM alts $ \(g, e) ->
    (,) <$> traverse (\x -> check env' x tBool) g <*> check env' e t
  pure (binds, guards)

-- | The statements of a do block in the monad m.
doStmts :: Env -> Type -> [Stmt] -> TC (Type, [CStmt])
doStmts env m = \case
  [] -> throw "empty do block"
  [SExpr e] -> do
    r <- fresh
    c <- check env e (tApp m r)
    pure (r, [CSExpr r c])
  [_] -> throw "the last statement of a do block must be an expression"
  SExpr e : rest -> do
    a <- fresh
    c <- check env e (tApp m a)
    (r, cs) <- doStmts env m rest
    pure (r, CSExpr a c : cs)
  SBind x e : rest -> do
    a <- fresh
    c <- check env e (tApp m a)
    let env' = if x == "_" then env else extend env [(x, a)]
    (r, cs) <- doStmts env' m rest
    pure (r, CSBind x a c : cs)
  SLet ds : rest -> do
    (env', bs) <- localBinds env ds
    (r, cs) <- doStmts env' m rest
    pure (r, CSLet bs : cs)

-- | Local bindings (let and where): recursive and monomorphic, since Go
-- function literals cannot be generic. Their constraints are solved together
-- with those of the enclosing top-level binding.
localBinds :: Env -> [Decl] -> TC (Env, [CBind])
localBinds env ds = do
  let sigs = M.fromList [(n, t) | DSig ns _ t <- ds, n <- ns]
      binds = [(n, cs) | DBind n cs <- ds]
  tys <- forM binds $ \(n, _) -> case M.lookup n sigs of
    -- local signatures are checked monomorphically: their variables are
    -- unification variables, not rigid ones
    Just st -> do
      vs <- mapM (\v -> (,) v <$> fresh) (stypeVars st)
      fromSType env (M.fromList vs) st
    Nothing -> fresh
  let env' = extend env (zip (map fst binds) tys)
  cbs <- forM (zip binds tys) $ \((n, cs), t) -> withCtx n $ do
    (ar, body) <- tcClauses env' cs t
    pure (CBind n t ar body)
  pure (env', cbs)

-- | Elaborates the clauses of one function against its type.
tcClauses :: Env -> [Clause] -> Type -> TC (Int, CExpr)
tcClauses env cs t = do
  ar <- case nub [length ps | Clause ps _ <- cs] of
    [a] -> pure a
    _ -> throw "clauses with different numbers of arguments"
  if ar == 0
    then case cs of
      [Clause [] r] -> do
        (bs, alts) <- checkRhs env r t
        pure (0, simple bs alts)
      _ -> throw "defined more than once"
    else do
      (ps, r) <- peel ar t
      let names = ["_arg" ++ show i | i <- [0 .. ar - 1]]
      rows <- forM cs $ \(Clause pats rhs) -> do
        res <- zipWithM (checkPat env) pats ps
        (bs, alts) <- checkRhs (extend env (concatMap snd res)) rhs r
        pure (CRow (map fst res) bs alts)
      let scruts = zipWith (\n p -> CVar n (Inst [] []) p) names ps
      pure (ar, CLam (zip names ps) r (CMatch scruts rows r))
  where
    simple [] [(Nothing, e)] = e
    simple bs alts = CMatch [] [CRow [] bs alts] t
    peel 0 ty = pure ([], ty)
    peel n ty = do
      (p, r) <- splitArrow ty
      (ps, res) <- peel (n - 1 :: Int) r
      pure (p : ps, res)

-- | Brings a body of arity k up to the n arrows of its type, so methods can
-- be called uncurried whatever way their instance defines them.
etaTo :: Type -> (Int, CExpr) -> TC CExpr
etaTo t (k, body) = do
  t' <- zonkT t
  let n = arrows t'
  if k >= n
    then pure body
    else do
      let (ps, r) = splitFun n t'
          names = ["_eta" ++ show i | i <- [0 .. n - 1]]
      pure (CLam (zip names ps) r (CApp body [CVar v (Inst [] []) p | (v, p) <- zip names ps]))

-- Module --------------------------------------------------------------------------

typecheck :: [Decl] -> Either String Program
typecheck ds = evalStateT (tcModule ds) (St 0 IM.empty [] IM.empty)

tyconId :: Name -> String
tyconId = \case
  "[]" -> "List"
  "()" -> "Unit"
  "(,)" -> "Tup2"
  "(,,)" -> "Tup3"
  "->" -> "Fn"
  k -> k

tcModule :: [Decl] -> TC Program
tcModule ds = do
  let datas = [(n, ps, cons) | DData n ps cons _ <- ds]
      types = M.union builtinTypes (M.fromList [(n, length ps) | (n, ps, _) <- datas])
      envD = Env M.empty builtinCons types M.empty M.empty []
  -- data types
  userCons <- fmap concat . forM datas $ \(n, ps, cons) ->
    forM (zip [0 ..] cons) $ \(i, ConDecl k fields) -> withCtx n $ do
      fts <- mapM (\(lz, st) -> (,) lz <$> fromSType envD (M.fromList [(p, TVar p) | p <- ps]) st) fields
      pure (k, ConInfo n ps fts i)
  let cons = M.union builtinCons (M.fromList userCons)
      dataInfos = M.fromList $
        [("[]", DataInfo ["a"] ["[]", ":"]), ("Bool", DataInfo [] ["False", "True"])]
          ++ [(n, DataInfo ps [k | ConDecl k _ <- cs]) | (n, ps, cs) <- datas]
      envC = envD {envCons = cons}
  -- classes
  let classDecls = [(sup, c, v, body) | DClass sup c v body <- ds]
      kindOf v body = maximum (0 : [M.findWithDefault 0 v (stypeArities st) | DSig _ _ st <- body])
      envK = envC {envClasses = M.fromList [(c, ClassInfo v (kindOf v body) (map fst sup) [] []) | (sup, c, v, body) <- classDecls]}
  classes <- fmap M.fromList . forM classDecls $ \(sup, c, v, body) -> withCtx c $ do
    let kind = kindOf v body
    forM_ sup $ \(s, sv) -> do
      unless (sv == v) (throw "a superclass must constrain the class variable")
      case M.lookup s (envClasses envK) of
        Nothing -> throw ("unknown class: " ++ s)
        Just sci -> unless (clsKind sci == kind) (throw ("superclass " ++ s ++ " is over a different kind"))
    methods <- fmap concat . forM [(ns, ctx, st) | DSig ns ctx st <- body] $ \(ns, ctx, st) -> do
      let own = filter (/= v) (stypeVars st)
      -- a dictionary of a class over plain types is a Go struct at run time,
      -- and struct fields cannot be generic
      when (kind == 0 && (not (null own) || not (null ctx))) $
        throw "methods of a class over plain types may only mention the class variable"
      t <- fromSType envK (rigid st) st
      mpreds <- contextPreds envK ctx
      when (any (\(IsIn _ pt) -> pt == TVar v) mpreds) (throw "a method cannot constrain the class variable again")
      pure [(n, Forall (v : own) (IsIn c (TVar v) : mpreds) t) | n <- ns]
    let defaults = [n | DBind n _ <- body]
    forM_ defaults $ \n -> unless (n `elem` map fst methods) (throw (n ++ " is not a method of " ++ c))
    pure (c, ClassInfo v kind (map fst sup) methods defaults)
  let envCl = envK {envClasses = classes}
  -- instance heads
  instDecls <- forM [(ctx, c, st, body) | DInstance ctx c st body <- ds] $ \(ctx, c, st, body) -> withCtx ("instance " ++ c) $ do
    unless (M.member c classes) (throw ("unknown class: " ++ c))
    t <- fromSType envCl (rigid st) st
    (k, vs) <- case t of
      TCon k args | all isTVar args, length (nub args) == length args -> pure (k, [v | TVar v <- args])
      TFun (TVar a) (TVar b) | a /= b -> pure ("->", [a, b])
      _ -> throw "an instance type must be a type constructor applied to distinct variables"
    let kind = clsKind (classes M.! c)
        arity = M.findWithDefault 0 k (envTypes envCl)
    unless (length vs + kind == arity) $
      throw ("the instance type must take " ++ show kind ++ " more argument(s) to match the class")
    preds <- contextPreds envCl ctx
    pure ((c, k), InstHead ("inst_" ++ c ++ "_" ++ tyconId k) vs preds, t, body)
  case [key | (key, n) <- M.toList (M.fromListWith (+) [(key, 1 :: Int) | (key, _, _, _) <- instDecls]), n > 1] of
    ((c, k) : _) -> throw ("duplicate instance " ++ c ++ " " ++ k)
    [] -> pure ()
  let env0 = envCl {envInsts = M.fromList [(key, ih) | (key, ih, _, _) <- instDecls]}
  -- foreign imports, signatures and bindings
  foreigns <- forM [(s, n, st) | DForeign s n st <- ds] $ \(s, n, st) -> withCtx n $ do
    t <- fromSType env0 (rigid st) st
    pure (n, (Forall (stypeVars st) [] t, Foreign s t (arrows t)))
  let sigs = M.fromList [(n, (ctx, st)) | DSig ns ctx st <- ds, n <- ns]
      binds = [(n, cs) | DBind n cs <- ds]
      names = map fst binds
      methodSchemes = [(m, sc) | ci <- M.elems classes, (m, sc) <- clsMethods ci]
  case [n | (n, k) <- M.toList (M.fromListWith (+) [(n, 1 :: Int) | n <- names ++ map fst methodSchemes]), k > 1] of
    (n : _) -> throw ("in " ++ n ++ ": defined more than once")
    [] -> pure ()
  sigSchemes <- forM (M.toList sigs) $ \(n, (ctx, st)) -> withCtx n $ do
    t <- fromSType env0 (rigid st) st
    preds <- contextPreds env0 ctx
    pure (n, Forall (stypeVars st) preds t)
  let env1 = env0
        { envVars = M.fromList ([(n, (sc, False)) | (n, sc) <- M.toList primSchemes]
            ++ [(n, (sc, False)) | (n, (sc, _)) <- foreigns]
            ++ [(n, (sc, False)) | (n, sc) <- sigSchemes]
            ++ [(n, (sc, False)) | (n, sc) <- methodSchemes]) }
      unsigned = [b | b@(n, _) <- binds, n `M.notMember` sigs]
      unsignedNames = map fst unsigned
      sccs = stronglyConnComp [(b, n, filter (`elem` unsignedNames) (clausesRefs cs)) | b@(n, cs) <- unsigned]
  (env2, groupBinds) <- foldM tcGroup (env1, []) (zip [1 :: Int ..] sccs)
  -- bindings with signatures
  signedBinds <- forM [b | b@(n, _) <- binds, n `M.member` sigs] $ \(n, cs) -> withCtx n $ do
    let (_, st) = sigs M.! n
        Forall vs preds _ = M.fromList sigSchemes M.! n
    t <- fromSType env0 (rigid st) st
    let envG = withGivens env2 preds
    (ar, body) <- tcClauses envG cs t
    _ <- solve envG M.empty
    pure (topBind n vs preds t ar body)
  -- default methods, as ordinary constrained functions
  defaultBinds <- fmap concat . forM classDecls $ \(_, c, _, body) -> do
    let ci = classes M.! c
    forM [(m, cs) | DBind m cs <- body] $ \(m, cs) -> withCtx (c ++ "." ++ m) $ do
      let Forall vs preds t = M.fromList (clsMethods ci) M.! m
          envG = withGivens env2 preds
      body' <- tcClauses envG cs t >>= etaTo t
      _ <- solve envG M.empty
      pure ((topBind (defaultName c m) vs preds t (arrows t) body') {tbShared = False})
  -- instance bodies
  insts <- forM instDecls $ \((c, _), ih, headT, body) -> withCtx ("instance " ++ c ++ " " ++ prettyAtom headT) $ do
    let ci = classes M.! c
        defined = M.fromListWith (flip (++)) [(m, cs) | DBind m cs <- body]
        self = DInst (ihId ih) (map TVar (ihVars ih)) [DParam (dictName pc pv) | IsIn pc (TVar pv) <- ihCtx ih]
    forM_ (M.keys defined) $ \m -> unless (m `elem` map fst (clsMethods ci)) (throw (m ++ " is not a method of " ++ c))
    methods <- forM (clsMethods ci) $ \(m, Forall mvs mps mt) -> withCtx m $ do
      let own = drop 1 mvs
          mpreds = drop 1 mps
          t = norm (substT (M.fromList [(clsVar ci, headT)]) mt)
          envG = withGivens env2 (ihCtx ih ++ mpreds)
      case M.lookup m defined of
        Just cs -> do
          body' <- tcClauses envG cs t >>= etaTo t
          _ <- solve envG M.empty
          pure (m, Just body')
        Nothing
          | m `elem` clsDefaults ci -> do
              let n = arrows t
                  (ps, r) = splitFun n t
                  argNames = ["_arg" ++ show i | i <- [0 .. n - 1]]
                  dm = CVar (defaultName c m) (Inst (headT : map TVar own) (self : [DParam (dictName pc pv) | IsIn pc (TVar pv) <- mpreds])) t
              pure (m, Just (if n == 0 then dm else CLam (zip argNames ps) r (CApp dm [CVar a (Inst [] []) p | (a, p) <- zip argNames ps])))
          | otherwise -> pure (m, Nothing)
    supers <- forM (clsSupers ci) $ \s -> do
      let envG = withGivens env2 (ihCtx ih)
      d <- newHole (IsIn s headT)
      _ <- solve envG M.empty
      pure (s, d)
    pure (InstInfo (ihId ih) c (ihVars ih) (ihCtx ih) headT methods supers)
  -- main must be an IO action
  case M.lookup "main" (envVars env2) of
    Nothing -> throw "no main defined"
    Just (sc, _) -> withCtx "main" $ do
      (t, _, _) <- instantiate sc
      unify t (tIO tUnit)
      modify (\s -> s {stWanted = []})
  let allBinds = groupBinds ++ signedBinds ++ defaultBinds
      byName = M.fromList [(tbName b, b) | b <- allBinds]
      order = flattenSCCs (stronglyConnComp
        [(n, n, filter (`M.member` byName) (clausesRefs cs)) | (n, cs) <- binds])
      defaults = [tbName b | b <- defaultBinds]
  st <- get
  pure Program
    { progData = dataInfos
    , progCons = cons
    , progForeign = M.fromList [(n, f) | (n, (_, f)) <- foreigns]
    , progClasses = classes
    , progInsts = insts
    , progBinds = map (byName M.!) (order ++ defaults)
    , progSubst = stSub st
    , progSolved = stSolved st
    }
  where
    isTVar (TVar _) = True
    isTVar _ = False
    tcGroup (env, acc) (gi, scc) = do
      let members = flattenSCC scc
      tys <- mapM (const fresh) members
      let envG = env {envVars = foldr (\((n, _), t) -> M.insert n (Forall [] [] t, True)) (envVars env) (zip members tys)}
      results <- forM (zip members tys) $ \((n, cs), t) -> withCtx n (tcClauses envG cs t)
      -- the monomorphism restriction: a group of plain values is not
      -- generalised over its constraints, which are defaulted instead
      let restricted = all ((== 0) . fst) results
      when restricted (void (solve env M.empty))
      zts <- mapM zonkT tys
      let ms = nub (concatMap metas zts)
          vs = ["t" ++ show gi ++ "_" ++ show i | i <- [1 .. length ms]]
          gen = M.fromList (zip ms vs)
      preds <- if restricted then pure [] else withCtx (unwords (map fst members)) (solve env gen)
      zipWithM_ (\m v -> bindMeta m (TVar v)) ms vs
      zts' <- mapM zonkT tys
      let env' = env {envVars = foldr (\((n, _), t) -> M.insert n (Forall vs preds t, False)) (envVars env) (zip members zts')}
      pure (env', acc ++ [topBind n vs preds t ar body | (((n, _), t), (ar, body)) <- zip (zip members zts') results])

topBind :: Name -> [Name] -> [Pred] -> Type -> Int -> CExpr -> TopBind
topBind n vs preds t ar body =
  TopBind n vs [(dictName c v, p) | p@(IsIn c (TVar v)) <- preds] t ar body (ar == 0 && null vs && null preds)

defaultName :: Name -> Name -> Name
defaultName c m = "_dm_" ++ c ++ "_" ++ m

-- Approximate references (ignores shadowing), used only for dependency order.
clausesRefs :: [Clause] -> [Name]
clausesRefs cs = nub (concat [rhsRefs r | Clause _ r <- cs])

rhsRefs :: Rhs -> [Name]
rhsRefs (Rhs alts ws) = concat [maybe [] exprRefs g ++ exprRefs e | (g, e) <- alts] ++ declsRefs ws

declsRefs :: [Decl] -> [Name]
declsRefs ds = concat [clausesRefs cs | DBind _ cs <- ds]

exprRefs :: Expr -> [Name]
exprRefs = \case
  EVar x -> [x]
  EApp a b -> exprRefs a ++ exprRefs b
  ELam _ b -> exprRefs b
  ELet ds b -> declsRefs ds ++ exprRefs b
  EIf a b c -> concatMap exprRefs [a, b, c]
  ECase s alts -> exprRefs s ++ concat [rhsRefs r | Alt _ r <- alts]
  EDo ss -> concatMap stmtRefs ss
  EOpSeq e0 rest -> exprRefs e0 ++ concat [op : exprRefs x | (op, x) <- rest]
  EAnn x _ -> exprRefs x
  _ -> []
  where
    stmtRefs (SBind _ e) = exprRefs e
    stmtRefs (SLet ds) = declsRefs ds
    stmtRefs (SExpr e) = exprRefs e
