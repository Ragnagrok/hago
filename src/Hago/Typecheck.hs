{-# LANGUAGE LambdaCase #-}

-- | Hindley-Milner type inference that also elaborates the program into the
-- typed core. Laziness is type-directed: an expression checked against
-- @Lazy t@ is suspended, and a variable of type @Lazy t@ used where a @t@ is
-- expected is forced.
module Hago.Typecheck (typecheck, primSchemes, pretty) where

import Control.Monad
import Control.Monad.Except
import Control.Monad.State
import Data.Graph (flattenSCC, flattenSCCs, stronglyConnComp)
import qualified Data.IntMap as IM
import Data.List (intercalate, nub)
import qualified Data.Map as M
import Data.Maybe (fromMaybe)
import Hago.Core
import Hago.Syntax

data Env = Env
  { envVars :: M.Map Name (Scheme, Bool)   -- ^ scheme, and whether it is a recursive group member
  , envCons :: M.Map Name ConInfo
  , envTypes :: M.Map Name Int             -- ^ type constructors and their arity
  }

data St = St {stNext :: Int, stSub :: Subst}

type TC = StateT St (Either String)

-- Primitives -------------------------------------------------------------------

primSchemes :: M.Map Name Scheme
primSchemes = M.fromList $
  [(op, mono (tInt ~> tInt ~> tInt)) | op <- ["+", "-", "*", "div", "mod"]]
    ++ [(op, Forall ["a"] (a ~> a ~> tBool)) | op <- ["==", "/=", "<", "<=", ">", ">="]]
    ++ [ ("negate", mono (tInt ~> tInt))
       , ("show", Forall ["a"] (a ~> tString))
       , ("print", Forall ["a"] (a ~> tIO tUnit))
       , ("putStrLn", mono (tString ~> tIO tUnit))
       , ("putStr", mono (tString ~> tIO tUnit))
       , ("getLine", mono (tIO tString))
       , ("return", Forall ["a"] (a ~> tIO a))
       , (">>=", Forall ["a", "b"] (tIO a ~> (a ~> tIO b) ~> tIO b))
       , (">>", Forall ["a", "b"] (tIO a ~> tLazy (tIO b) ~> tIO b))
       , ("error", Forall ["a"] (tString ~> a))
       , ("++", Forall ["a"] (a ~> tLazy a ~> a))
       , ("pack", mono (tList tChar ~> tString))
       , ("unpack", mono (tString ~> tList tChar))
       , ("ord", mono (tChar ~> tInt))
       , ("chr", mono (tInt ~> tChar))
       ]
  where
    a = TVar "a"
    b = TVar "b"
    mono = Forall []

infixr 5 ~>
(~>) :: Type -> Type -> Type
(~>) = TFun

builtinTypes :: M.Map Name Int
builtinTypes = M.fromList
  [ ("Int", 0), ("Bool", 0), ("Char", 0), ("String", 0), ("()", 0)
  , ("[]", 1), ("IO", 1), ("Lazy", 1), ("(,)", 2), ("(,,)", 3) ]

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

-- Monad helpers --------------------------------------------------------------

throw :: String -> TC a
throw = throwError

withCtx :: Name -> TC a -> TC a
withCtx n act = act `catchError` \e -> throwError ("in " ++ n ++ ": " ++ e)

fresh :: TC Type
fresh = do
  n <- gets stNext
  modify (\s -> s {stNext = n + 1})
  pure (TMeta n)

zonkT :: Type -> TC Type
zonkT t = gets (\s -> zonk (stSub s) t)

bindMeta :: Int -> Type -> TC ()
bindMeta m t = modify (\s -> s {stSub = IM.insert m t (stSub s)})

unify :: Type -> Type -> TC ()
unify x y = do
  x' <- zonkT x
  y' <- zonkT y
  go x' y'
  where
    go (TMeta m) (TMeta n) | m == n = pure ()
    go (TMeta m) t = bindVar m t
    go t (TMeta m) = bindVar m t
    go (TVar a) (TVar b) | a == b = pure ()
    go (TCon c ts) (TCon d us) | c == d, length ts == length us = zipWithM_ unify ts us
    go (TFun a b) (TFun c d) = unify a c >> unify b d
    go _ _ = do
      x' <- zonkT x
      y' <- zonkT y
      throw ("type mismatch: expected " ++ pretty y' ++ ", got " ++ pretty x')
    bindVar m t
      | m `elem` metas t = throw ("infinite type: ?" ++ show m ++ " ~ " ++ pretty t)
      | otherwise = bindMeta m t

metas :: Type -> [Int]
metas = \case
  TMeta m -> [m]
  TCon _ ts -> concatMap metas ts
  TFun a b -> metas a ++ metas b
  TVar _ -> []

substT :: M.Map Name Type -> Type -> Type
substT s = \case
  TVar v -> fromMaybe (TVar v) (M.lookup v s)
  TCon c ts -> TCon c (map (substT s) ts)
  TFun a b -> TFun (substT s a) (substT s b)
  t -> t

instantiate :: Scheme -> TC (Type, [Type])
instantiate (Forall vs t) = do
  ms <- mapM (const fresh) vs
  pure (substT (M.fromList (zip vs ms)) t, ms)

pretty :: Type -> String
pretty = go (0 :: Int)
  where
    go _ (TVar v) = v
    go _ (TMeta m) = "?" ++ show m
    go _ (TCon "[]" [t]) = "[" ++ go 0 t ++ "]"
    go _ (TCon c ts) | take 2 c == "(," = "(" ++ intercalate ", " (map (go 0) ts) ++ ")"
    go _ (TCon c []) = c
    go p (TCon c ts) = paren (p > 1) (unwords (c : map (go 2) ts))
    go p (TFun a b) = paren (p > 0) (go 1 a ++ " -> " ++ go 0 b)
    paren True s = "(" ++ s ++ ")"
    paren False s = s

-- Types written by the programmer -----------------------------------------------

stypeVars :: SType -> [Name]
stypeVars = nub . go
  where
    go (STVar v) = [v]
    go (STCon _ ts) = concatMap go ts
    go (STFun a b) = go a ++ go b

fromSType :: Env -> M.Map Name Type -> SType -> TC Type
fromSType env vars = go
  where
    go (STVar v) = maybe (throw ("type variable not in scope: " ++ v)) pure (M.lookup v vars)
    go (STFun a b) = TFun <$> go a <*> go b
    go (STCon c ts) = case M.lookup c (envTypes env) of
      Nothing -> throw ("unknown type: " ++ c)
      Just n
        | n /= length ts -> throw ("type " ++ c ++ " expects " ++ show n ++ " arguments")
        | otherwise -> TCon c <$> mapM go ts

rigid :: SType -> M.Map Name Type
rigid st = M.fromList [(v, TVar v) | v <- stypeVars st]

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
extend env bs = env {envVars = foldr (\(n, t) -> M.insert n (Forall [] t, False)) (envVars env) bs}

litType :: Lit -> Type
litType (LInt _) = tInt
litType (LChar _) = tChar
litType (LStr _) = tString

inferVarRaw :: Env -> Name -> TC (CExpr, Type)
inferVarRaw env x = case M.lookup x (envVars env) of
  Nothing -> throw ("not in scope: " ++ x)
  Just (sc, self) -> do
    (t, targs) <- instantiate sc
    pure (CVar x (if self then SelfGroup else Inst targs) t, t)

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
  ELit l -> pure (CLit l, litType l)
  EApp {} -> do
    let (f, args) = spine e
    (cf, tf) <- infer env f
    (cargs, tr) <- applyArgs tf args
    pure (CApp cf cargs, tr)
  EDo ss -> do
    (r, cs) <- doStmts env ss
    pure (CDo r cs, tIO r)
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
          var = CVar n (Inst []) xp
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
        _ -> CMatch [CVar n (Inst []) t | (n, t, _) <- toMatch] [CRow [p | (_, _, p) <- toMatch] [] [(Nothing, cbody)]] r
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

doStmts :: Env -> [Stmt] -> TC (Type, [CStmt])
doStmts env = \case
  [] -> throw "empty do block"
  [SExpr e] -> do
    r <- fresh
    c <- check env e (tIO r)
    pure (r, [CSExpr c])
  [_] -> throw "the last statement of a do block must be an expression"
  SExpr e : rest -> do
    a <- fresh
    c <- check env e (tIO a)
    (r, cs) <- doStmts env rest
    pure (r, CSExpr c : cs)
  SBind x e : rest -> do
    a <- fresh
    c <- check env e (tIO a)
    let env' = if x == "_" then env else extend env [(x, a)]
    (r, cs) <- doStmts env' rest
    pure (r, CSBind x a c : cs)
  SLet ds : rest -> do
    (env', bs) <- localBinds env ds
    (r, cs) <- doStmts env' rest
    pure (r, CSLet bs : cs)

-- | Local bindings (let and where): recursive and monomorphic, since Go
-- function literals cannot be generic.
localBinds :: Env -> [Decl] -> TC (Env, [CBind])
localBinds env ds = do
  let sigs = M.fromList [(n, t) | DSig ns t <- ds, n <- ns]
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
      let scruts = zipWith (\n p -> CVar n (Inst []) p) names ps
      pure (ar, CLam (zip names ps) r (CMatch scruts rows r))
  where
    simple [] [(Nothing, e)] = e
    simple bs alts = CMatch [] [CRow [] bs alts] t
    peel 0 ty = pure ([], ty)
    peel n ty = do
      (p, r) <- splitArrow ty
      (ps, res) <- peel (n - 1 :: Int) r
      pure (p : ps, res)

-- Module --------------------------------------------------------------------------

typecheck :: [Decl] -> Either String Program
typecheck ds = evalStateT (tcModule ds) (St 0 IM.empty)

tcModule :: [Decl] -> TC Program
tcModule ds = do
  let datas = [(n, ps, cons) | DData n ps cons <- ds]
      types = M.union builtinTypes (M.fromList [(n, length ps) | (n, ps, _) <- datas])
      env00 = Env M.empty builtinCons types
  userCons <- fmap concat . forM datas $ \(n, ps, cons) ->
    forM (zip [0 ..] cons) $ \(i, ConDecl k fields) -> withCtx n $ do
      fts <- mapM (\(lz, st) -> (,) lz <$> fromSType env00 (M.fromList [(p, TVar p) | p <- ps]) st) fields
      pure (k, ConInfo n ps fts i)
  let cons = M.union builtinCons (M.fromList userCons)
      dataInfos = M.fromList $
        [("[]", DataInfo ["a"] ["[]", ":"]), ("Bool", DataInfo [] ["False", "True"])]
          ++ [(n, DataInfo ps [k | ConDecl k _ <- cs]) | (n, ps, cs) <- datas]
      env0 = env00 {envCons = cons}
  foreigns <- forM [(s, n, st) | DForeign s n st <- ds] $ \(s, n, st) -> withCtx n $ do
    t <- fromSType env0 (rigid st) st
    pure (n, (Forall (stypeVars st) t, Foreign s t (arrows t)))
  let sigs = M.fromList [(n, st) | DSig ns st <- ds, n <- ns]
      binds = [(n, cs) | DBind n cs <- ds]
      names = map fst binds
  case [n | (n, k) <- M.toList (M.fromListWith (+) [(n, 1 :: Int) | n <- names]), k > 1] of
    (n : _) -> throw ("in " ++ n ++ ": defined more than once")
    [] -> pure ()
  sigSchemes <- forM (M.toList sigs) $ \(n, st) -> withCtx n $ do
    t <- fromSType env0 (rigid st) st
    pure (n, Forall (stypeVars st) t)
  let env1 = env0
        { envVars = M.fromList ([(n, (sc, False)) | (n, sc) <- M.toList primSchemes]
            ++ [(n, (sc, False)) | (n, (sc, _)) <- foreigns]
            ++ [(n, (sc, False)) | (n, sc) <- sigSchemes]) }
      unsigned = [b | b@(n, _) <- binds, n `M.notMember` sigs]
      unsignedNames = map fst unsigned
      sccs = stronglyConnComp [(b, n, filter (`elem` unsignedNames) (clausesRefs cs)) | b@(n, cs) <- unsigned]
  (env2, groupBinds) <- foldM tcGroup (env1, []) (zip [1 :: Int ..] sccs)
  signedBinds <- forM [b | b@(n, _) <- binds, n `M.member` sigs] $ \(n, cs) -> withCtx n $ do
    let st = sigs M.! n
    t <- fromSType env0 (rigid st) st
    (ar, body) <- tcClauses env2 cs t
    pure (TopBind n (stypeVars st) t ar body)
  -- main must be an IO action
  case M.lookup "main" (envVars env2) of
    Nothing -> throw "no main defined"
    Just (sc, _) -> withCtx "main" $ do
      (t, _) <- instantiate sc
      unify t (tIO tUnit)
  let byName = M.fromList [(tbName b, b) | b <- groupBinds ++ signedBinds]
      order = flattenSCCs (stronglyConnComp
        [(n, n, filter (`M.member` byName) (clausesRefs cs)) | (n, cs) <- binds])
  sub <- gets stSub
  pure Program
    { progData = dataInfos
    , progCons = cons
    , progForeign = M.fromList [(n, f) | (n, (_, f)) <- foreigns]
    , progBinds = map (byName M.!) order
    , progSubst = sub
    }
  where
    tcGroup (env, acc) (gi, scc) = do
      let members = flattenSCC scc
      tys <- mapM (const fresh) members
      let envG = env {envVars = foldr (\((n, _), t) -> M.insert n (Forall [] t, True)) (envVars env) (zip members tys)}
      results <- forM (zip members tys) $ \((n, cs), t) -> withCtx n (tcClauses envG cs t)
      zts <- mapM zonkT tys
      let ms = nub (concatMap metas zts)
          vs = ["t" ++ show gi ++ "_" ++ show i | i <- [1 .. length ms]]
      zipWithM_ (\m v -> bindMeta m (TVar v)) ms vs
      zts' <- mapM zonkT tys
      let env' = env {envVars = foldr (\((n, _), t) -> M.insert n (Forall vs t, False)) (envVars env) (zip members zts')}
      pure (env', acc ++ [TopBind n vs t ar body | (((n, _), t), (ar, body)) <- zip (zip members zts') results])

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
  _ -> []
  where
    stmtRefs (SBind _ e) = exprRefs e
    stmtRefs (SLet ds) = declsRefs ds
    stmtRefs (SExpr e) = exprRefs e
