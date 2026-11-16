{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}

-- | Specialisation of everything polymorphic over a type constructor.
--
-- Go generics range over types, not over type constructors: there is no
-- @F[_]@, so a dictionary for @Functor f@ cannot exist at run time. Every
-- function with a higher-kinded type parameter is therefore a template,
-- copied once per constructor it is used at, as Rust and MLton do. So is
-- every function with a class constraint: copying it per instance removes
-- the dictionaries altogether, and with them the indirect calls. Type
-- variables without constraints stay Go generics, so map is still one
-- function.
--
-- The pass also turns instance methods into ordinary top-level functions,
-- resolves every method call whose instance is known into a direct call,
-- fills in solved constraints, and turns do blocks outside IO into (>>=).
module Hago.Specialize (specialize, instMethodName, typeTag) where

import Control.Monad
import Control.Monad.State
import qualified Data.IntMap as IM
import Data.List (intercalate)
import qualified Data.Map as M
import Data.Maybe (fromMaybe)
import qualified Data.Set as S
import Hago.Core
import Hago.Syntax (Lit (..), Name, tupleArity)

-- | Something compiled to a Go function or variable.
data Ent = Ent
  { eName :: Name
  , eTParams :: [Name]
  , eDicts :: [(Name, Pred)]
  , eType :: Type
  , eArity :: Int
  , eBody :: CExpr
  , eShared :: Bool
  }

data Job = Job Ent Name (M.Map Name Type) (M.Map Name Dict) [Name] [(Name, Pred)]

data SS = SS
  { ssDone :: M.Map String Name
  , ssUsed :: S.Set Name
  , ssQueue :: [Job]
  , ssOut :: [TopBind]
  , ssJobs :: Int
  }

type SM = StateT SS (Either String)

data RC = RC
  { rcTy :: M.Map Name Type     -- ^ higher-kinded variables to their constructors
  , rcDict :: M.Map Name Dict   -- ^ static dictionary parameters to their instances
  , rcCur :: Ent
  , rcLocals :: S.Set Name
  }

instMethodName :: Name -> Name -> Name
instMethodName i m = i ++ "_m_" ++ m

specialize :: Program -> Either String Program
specialize prog = do
  let sub = progSubst prog
      classes = progClasses prog
      instMap = M.fromList [(instId i, i) | i <- progInsts prog]
      methodClass = M.fromList [(m, c) | (c, ci) <- M.toList classes, (m, _) <- clsMethods ci]
      -- every constraint is resolved at compile time
      isStatic :: Name -> Bool
      isStatic _ = True
      topEnts = [Ent n ps ds (zonk sub t) ar b sh | TopBind n ps ds t ar b sh <- progBinds prog]
      instEnts =
        [ Ent (instMethodName (instId inst) m) (instVars inst ++ own)
              [(dictName p, p) | p <- instCtx inst ++ mpreds] t (arrows t)
              (fromMaybe (missing m t) mbody) False
        | inst <- progInsts prog
        , let ci = classes M.! instClass inst
        , ((m, Forall vs ps mt), (_, mbody)) <- zip (clsMethods ci) (instMethods inst)
        , let own = drop (length (clsVars ci)) vs
        , let mpreds = drop 1 ps
        , let t = norm (substTV (M.fromList (zip (clsVars ci) (instHead inst))) (zonk sub mt)) ]
      ents = M.fromList [(eName e, e) | e <- topEnts ++ instEnts]
      hkParams e
        | isValue e = eTParams e
        | otherwise =
            [ v | v <- eTParams e
            , v `elem` headVars (eType e) || v `elem` dataHkVars (progData prog) (eType e)
                || or [v `elem` concatMap tyVarsOf ts | (_, IsIn _ ts) <- eDicts e] ]
      -- a polymorphic value, like xs :: [a] or table :: Num a => [a], is a
      -- template too: each copy at concrete types is computed once and shared
      isValue e = eArity e == 0 && arrows (eType e) == 0
      isTemplate e = not (null (hkParams e))

      ty rc t = norm (substTV (rcTy rc) (zonk sub t))

      dict rc = \case
        DHole h -> dict rc (fromMaybe (error ("unsolved constraint " ++ show h)) (IM.lookup h (progSolved prog)))
        DParam n -> M.findWithDefault (DParam n) n (rcDict rc)
        DInst i ts ds -> DInst i (map (ty rc) ts) (map (dict rc) ds)
        DSuper d s -> superOf (dict rc d) s

      -- the superclass dictionary inside a known instance is known too
      superOf d s = case d of
        DInst i ts ds | Just inst <- M.lookup i instMap, Just sd <- lookup s (instSupers inst) ->
          let rc = RC (M.fromList (zip (instVars inst) ts))
                      (M.fromList (zip (map dictName (instCtx inst)) ds))
                      (error "superOf") S.empty
           in dict rc sd
        _ -> DSuper d s

      rw :: RC -> CExpr -> SM CExpr
      rw rc = \case
        CVar x ref t
          | x `S.member` rcLocals rc -> pure (CVar x ref (ty rc t))
          | otherwise -> do
              let cur = rcCur rc
                  (ts, ds) = case ref of
                    Inst a b -> (a, b)
                    SelfGroup -> (map TVar (eTParams cur), map (DParam . fst) (eDicts cur))
                  ts' = map (ty rc) ts
                  ds' = map (dict rc) ds
                  t' = ty rc t
              case (M.lookup x methodClass, ds') of
                (Just c, DInst i its subs : rest) ->
                  useEnt (instMethodName i x) (its ++ drop (length (clsVars (classes M.! c))) ts') (subs ++ rest) t'
                (Just c, _) | isStatic c -> lift (Left ("cannot resolve " ++ c ++ " for " ++ x ++ " in " ++ eName cur))
                (Just _, _) -> pure (CVar x (Inst ts' ds') t')
                (Nothing, _)
                  | M.member x ents -> useEnt x ts' ds' t'
                  | otherwise -> pure (CVar x (Inst ts' ds') t')
        CCon k ts t -> pure (CCon k (map (ty rc) ts) (ty rc t))
        CLit l -> pure (CLit l)
        -- literals at Int and Double are Go literals; elsewhere, a call
        CNum n t d -> case ty rc t of
          t'@(TCon c []) | c `elem` ["Int", "Double"] -> pure (CNum n t' (dict rc d))
          _ -> rw rc (CApp (CVar "fromInteger" (Inst [t] [d]) (TFun tInt t)) [CLit (LInt n)])
        CFrac x t d -> case ty rc t of
          t'@(TCon "Double" []) -> pure (CFrac x t' (dict rc d))
          _ -> rw rc (CApp (CVar "fromDouble" (Inst [t] [d]) (TFun tDouble t)) [CLit (LDouble x)])
        CApp f as -> CApp <$> rw rc f <*> mapM (rw rc) as
        CLam ps r b -> CLam [(p, ty rc pt) | (p, pt) <- ps] (ty rc r) <$> rw (locals rc (map fst ps)) b
        CLet bs b t -> do
          let rc' = locals rc [n | CBind n _ _ _ <- bs]
          CLet <$> mapM (rwBind rc') bs <*> rw rc' b <*> pure (ty rc t)
        CMatch ss rows t -> CMatch <$> mapM (rw rc) ss <*> mapM (rwRow rc) rows <*> pure (ty rc t)
        CIf a b c t -> CIf <$> rw rc a <*> rw rc b <*> rw rc c <*> pure (ty rc t)
        CDelay t e -> CDelay (ty rc t) <$> rw rc e
        CForce e -> CForce <$> rw rc e
        CDo m d r ss -> case ty rc m of
          m'@(TCon "IO" []) -> CDo m' (dict rc d) (ty rc r) <$> rwStmts rc ss
          _ -> rw rc (desugarDo m d r ss)

      rwBind rc (CBind n t ar b) = CBind n (ty rc t) ar <$> rw rc b

      rwRow rc (CRow pats bs gs) = do
        let rc1 = locals rc (concatMap patVars pats)
            rc2 = locals rc1 [n | CBind n _ _ _ <- bs]
        CRow <$> mapM (rwPat rc) pats <*> mapM (rwBind rc2) bs
          <*> mapM (\(g, e) -> (,) <$> traverse (rw rc2) g <*> rw rc2 e) gs

      rwPat rc = \case
        CPVar x t -> pure (CPVar x (ty rc t))
        CPWild -> pure CPWild
        CPLit l -> pure (CPLit l)
        CPNum n t a b -> case ty rc t of
          t'@(TCon c []) | c `elem` ["Int", "Double"] -> pure (CPNum n t' (dict rc a) (dict rc b))
          _ -> CPEq <$> rw rc (CVar "==" (Inst [t] [a]) (TFun t (TFun t tBool))) <*> rw rc (CNum n t b)
        CPEq f v -> CPEq <$> rw rc f <*> rw rc v
        CPCon k ts ps -> CPCon k (map (ty rc) ts) <$> mapM (rwPat rc) ps
        CPForce p -> CPForce <$> rwPat rc p
        CPAs x t p -> CPAs x (ty rc t) <$> rwPat rc p

      rwStmts _ [] = pure []
      rwStmts rc (s : rest) = case s of
        CSBind x t e -> do
          e' <- rw rc e
          (CSBind x (ty rc t) e' :) <$> rwStmts (locals rc [x]) rest
        CSExpr t e -> do
          e' <- rw rc e
          (CSExpr (ty rc t) e' :) <$> rwStmts rc rest
        CSLet bs -> do
          let rc' = locals rc [n | CBind n _ _ _ <- bs]
          bs' <- mapM (rwBind rc') bs
          (CSLet bs' :) <$> rwStmts rc' rest

      -- a call to a template: find or schedule the copy for these constructors
      useEnt x ts0 ds t = do
        let ent = ents M.! x
            hk = hkParams ent
            -- a type nothing fixes is (), as everywhere else
            ts = if isValue ent then map defaultMetas ts0 else ts0
        if null hk
          then pure (CVar x (Inst ts ds) t)
          else do
            let tpairs = zip (eTParams ent) ts
                dpairs = zip (eDicts ent) ds
                (canon, (_, extraT, _, extraD)) = flip runState (M.empty, [], 0 :: Int, []) $ do
                  hkTs <- mapM (canonType . snd) [p | p@(v, _) <- tpairs, v `elem` hk]
                  sds <- mapM canonDict [d | ((_, IsIn c _), d) <- dpairs, isStatic c]
                  pure (hkTs, sds)
                key = show (x, fst canon, snd canon)
                restT = [a | (v, a) <- tpairs, v `notElem` hk]
                runtimeD = [d | ((_, IsIn c _), d) <- dpairs, not (isStatic c)]
                actualT = [a | (_, a) <- reverse extraT]
                actualD = [d | (_, _, d) <- reverse extraD]
            when (any hasMeta (fst canon)) $
              lift (Left ("ambiguous type constructor in a call to " ++ x))
            done <- gets ssDone
            name <- case M.lookup key done of
              Just n -> pure n
              Nothing -> do
                used <- gets ssUsed
                let base = x ++ "__" ++ intercalate "_" (map typeTag (fst canon))
                    n = case [c | c <- base : [base ++ "_" ++ show i | i <- [2 :: Int ..]], c `S.notMember` used] of
                      (c : _) -> c
                      [] -> base
                    job = Job ent n
                      (M.fromList (zip [v | (v, _) <- tpairs, v `elem` hk] (fst canon)))
                      (M.fromList (zip [dn | ((dn, IsIn c _), _) <- dpairs, isStatic c] (snd canon)))
                      [p | (p, _) <- reverse extraT]
                      [(p, pr) | (p, pr, _) <- reverse extraD]
                modify (\s -> s {ssDone = M.insert key n (ssDone s), ssUsed = S.insert n (ssUsed s), ssQueue = ssQueue s ++ [job]})
                pure n
            pure (CVar name (Inst (restT ++ actualT) (runtimeD ++ actualD)) t)

      -- the caller's own type variables and run-time dictionaries become
      -- extra parameters of the copy, so one copy serves every caller
      canonType = \case
        TVar v -> do
          (m, ts, n, ds) <- get
          case M.lookup v m of
            Just p -> pure (TVar p)
            Nothing -> do
              let p = "_sp" ++ show (M.size m)
              put (M.insert v p m, (p, TVar v) : ts, n, ds)
              pure (TVar p)
        TCon c ts -> TCon c <$> mapM canonType ts
        TFun a b -> TFun <$> canonType a <*> canonType b
        TApp f a -> TApp <$> canonType f <*> canonType a
        t -> pure t
      canonDict = \case
        DInst i ts subs | Just inst <- M.lookup i instMap -> do
          ts' <- mapM canonType ts
          let s = M.fromList (zip (instVars inst) ts')
          subs' <- forM (zip (instCtx inst) subs) $ \(IsIn c pts, sd) ->
            if isStatic c
              then canonDict sd
              else do
                (m, tsAcc, n, ds) <- get
                let p = "_sd" ++ show n
                put (m, tsAcc, n + 1, (p, IsIn c (map (norm . substTV s) pts), sd) : ds)
                pure (DParam p)
          pure (DInst i ts' subs')
        d -> pure d

      locals rc ns = rc {rcLocals = foldr S.insert (rcLocals rc) ns}

      plain e = do
        let rc = RC M.empty M.empty e S.empty
        b <- rw rc (eBody e)
        emit (TopBind (eName e) (eTParams e) [(n, IsIn c (map (ty rc) ts)) | (n, IsIn c ts) <- eDicts e] (ty rc (eType e)) (eArity e) b (eShared e))

      runJob (Job e n tmap dmap extraT extraD) = do
        let hk = hkParams e
            rc = RC tmap dmap e S.empty
            tparams = filter (`notElem` hk) (eTParams e) ++ extraT
            dicts = [(dn, IsIn c (map (ty rc) ts)) | (dn, IsIn c ts) <- eDicts e, not (isStatic c)] ++ extraD
        b <- rw rc (eBody e)
        emit (TopBind n tparams dicts (ty rc (eType e)) (eArity e) b (isValue e && null tparams && null dicts))

      emit b = modify (\s -> s {ssOut = b : ssOut s})

      drain = do
        q <- gets ssQueue
        case q of
          [] -> pure ()
          (j : rest) -> do
            n <- gets ssJobs
            when (n > 5000) $ lift (Left "specialisation does not terminate (polymorphic recursion over a type constructor?)")
            modify (\s -> s {ssQueue = rest, ssJobs = n + 1})
            runJob j
            drain

  final <- execStateT
    (mapM_ plain [e | e <- topEnts ++ instEnts, not (isTemplate e)] >> drain)
    (SS M.empty (M.keysSet ents) [] [] 0)
  pure prog
    { progBinds = reverse (ssOut final)
    -- no dictionary is left at run time
    , progInsts = []
    }
  where
    missing m t =
      let n = arrows t
          (ps, r) = splitFun n t
          names = ["_arg" ++ show i | i <- [0 .. n - 1]]
          err = CApp (CVar "error" (Inst [r] []) (TFun tString r)) [CLit (LStr ("no " ++ m ++ " in this instance"))]
       in if n == 0 then err else CLam (zip names ps) r err
    defaultMetas t = case t of
      TMeta _ -> tUnit
      TCon c ts -> TCon c (map defaultMetas ts)
      TFun a b -> TFun (defaultMetas a) (defaultMetas b)
      TApp f x -> TApp (defaultMetas f) (defaultMetas x)
      TVar v -> TVar v
    hasMeta t = case t of
      TMeta _ -> True
      TCon _ ts -> any hasMeta ts
      TFun a b -> hasMeta a || hasMeta b
      TApp f x -> hasMeta f || hasMeta x
      TVar _ -> False

-- | @do@ in a monad other than IO, as calls to (>>=).
desugarDo :: Type -> Dict -> Type -> [CStmt] -> CExpr
desugarDo m d r = go
  where
    mt = tApp m
    bindAt a = CVar ">>=" (Inst [m, a, r] [d]) (TFun (mt a) (TFun (TFun a (mt r)) (mt r)))
    go = \case
      [CSExpr _ e] -> e
      CSExpr a e : rest -> CApp (bindAt a) [e, CLam [("_unused", a)] (mt r) (go rest)]
      CSBind x a e : rest -> CApp (bindAt a) [e, CLam [(x, a)] (mt r) (go rest)]
      CSLet bs : rest -> CLet bs (go rest) (mt r)
      [] -> error "desugarDo: empty"

patVars :: CPat -> [Name]
patVars = \case
  CPVar x _ -> [x]
  CPAs x _ p -> x : patVars p
  CPCon _ _ ps -> concatMap patVars ps
  CPForce p -> patVars p
  _ -> []

-- | A readable suffix for a specialised copy.
typeTag :: Type -> String
typeTag = \case
  TCon c ts -> intercalate "_" (tag c : map typeTag ts)
  TVar v -> filter (/= '_') v
  TFun a b -> "Fn_" ++ typeTag a ++ "_" ++ typeTag b
  TApp f x -> typeTag f ++ "_" ++ typeTag x
  TMeta _ -> "X"
  where
    tag = \case
      "[]" -> "List"
      "()" -> "Unit"
      "->" -> "Fn"
      c | Just n <- tupleArity c -> "Tup" ++ show n
      c -> map (\x -> if x == '.' then '_' else x) c
