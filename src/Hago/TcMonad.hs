{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE LambdaCase #-}

-- | The type checker's monad: unification, instantiation, and the solver
-- that turns class constraints into dictionaries.
module Hago.TcMonad where

import Control.Monad
import Control.Monad.Except
import Control.Monad.State
import Data.Data (Data)
import qualified Data.IntMap as IM
import Data.List (intercalate, nub)
import qualified Data.Map as M
import qualified Data.Set as S
import Hago.Core
import Hago.Syntax (Loc, Name, showLoc, tupleArity, unqual)

-- | An instance: its name, its type variables (those of the type that
-- chooses it first), its context, and its types, one per class parameter.
data InstHead = InstHead {ihId :: Name, ihVars :: [Name], ihCtx :: [Pred], ihHead :: [Type]}
  deriving (Show, Data)

data Env = Env
  { envVars :: M.Map Name (Scheme, Bool)   -- ^ scheme, and whether it is a recursive group member
  , envCons :: M.Map Name ConInfo
  , envTypes :: M.Map Name Int             -- ^ type constructors and their arity
  , envClasses :: M.Map Name ClassInfo
  , envInsts :: M.Map (Name, Name) InstHead -- ^ by class and type constructor
  , envGivens :: [(Pred, Dict)]            -- ^ constraints available as dictionary parameters
  , envRecords :: M.Map Name Record        -- ^ the fields of each record type
  , envLocal :: S.Set Name                 -- ^ the local variables in scope
  , envMono :: [Type]                      -- ^ the types of everything not generalised yet
  , envCalls :: M.Map Name (Name, [(Name, Type)])
      -- ^ local functions moved to the top: the new name, and the variables passed to it
  }

-- | A record type: its constructors, and each field's laziness, type (over
-- the type's parameters) and position in the constructors that have it.
data Record = Record {recParams :: [Name], recCons :: [Name], recFields :: M.Map Name (Bool, Type, [(Name, Int)])}
  deriving (Show, Data)

data St = St
  { stNext :: Int
  , stSub :: Subst
  , stWanted :: [(Int, Pred, Maybe Loc)]   -- ^ constraints waiting to be solved, by hole, with where they arose
  , stSolved :: IM.IntMap Dict
  , stLoc :: Maybe Loc                     -- ^ the innermost expression or pattern being checked
  , stLifted :: [(TopBind, [Name])]        -- ^ local functions moved to the top, with their own type variables
  , stModule :: Name                       -- ^ the module being checked, which names what it moves to the top
  }

-- | An error: where, inside which definitions (outermost first), and what.
data TcErr = TcErr (Maybe Loc) [Name] String

type TC = StateT St (Either TcErr)

throw :: String -> TC a
throw msg = do
  l <- gets stLoc
  throwError (TcErr l [] msg)

withCtx :: Name -> TC a -> TC a
withCtx n act
  -- the name the parser gives a pattern binding is no help in a message
  | take 3 (unqual n) == "_pb" = act
  | otherwise = act `catchError` \(TcErr l cs m) -> throwError (TcErr l (n : cs) m)

withLoc :: Loc -> TC a -> TC a
withLoc l act = do
  old <- gets stLoc
  modify (\s -> s {stLoc = Just l})
  r <- act
  modify (\s -> s {stLoc = old})
  pure r

atLoc :: Maybe Loc -> TC a -> TC a
atLoc = maybe id withLoc

-- | file:line:col: in f, in g: message. Without a location, the file alone.
formatErr :: FilePath -> TcErr -> String
formatErr file (TcErr l cs m) =
  maybe file showLoc l ++ ": " ++ (if null cs then "" else "in " ++ intercalate ", in " (map unqual cs) ++ ": ") ++ m

next :: TC Int
next = do
  n <- gets stNext
  modify (\s -> s {stNext = n + 1})
  pure n

fresh :: TC Type
fresh = TMeta <$> next

-- | A local name no program can write.
uniq :: String -> TC Name
uniq prefix = (("_" ++ prefix) ++) . show <$> next

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
    -- f a against a known application: f takes the constructor with one argument fewer
    go (TApp f a) (TApp g b) = unify f g >> unify a b
    go (TApp f a) (TCon c us@(_ : _)) = unify f (TCon c (init us)) >> unify a (last us)
    go (TCon c us@(_ : _)) (TApp f a) = unify (TCon c (init us)) f >> unify (last us) a
    go (TApp f a) (TFun b r) = unify f (TCon "->" [b]) >> unify a r
    go (TFun b r) (TApp f a) = unify (TCon "->" [b]) f >> unify r a
    go _ _ = do
      x' <- zonkT x
      y' <- zonkT y
      throw ("type mismatch: expected " ++ pretty y' ++ ", got " ++ pretty x' ++ stringHint x' y')
    -- a String where a list or a Foldable is expected, or the other way round
    stringHint a b
      | isString a && listLike b || isString b && listLike a =
          "\na String is not a list: unpack turns it into a [Char], and pack turns one back"
      | otherwise = ""
    isString t = t == TCon "String" []
    listLike = \case
      TCon "[]" [_] -> True
      TApp _ _ -> True
      _ -> False
    bindVar m t
      | m `elem` metas t = throw ("infinite type: ?" ++ show m ++ " ~ " ++ pretty t)
      | otherwise = bindMeta m t

metas :: Type -> [Int]
metas = \case
  TMeta m -> [m]
  TCon _ ts -> concatMap metas ts
  TFun a b -> metas a ++ metas b
  TApp f x -> metas f ++ metas x
  TVar _ -> []

substT :: M.Map Name Type -> Type -> Type
substT = substTV

-- | A new constraint to solve; returns the hole its dictionary will fill.
newHole :: Pred -> TC Dict
newHole p = do
  h <- next
  modify (\s -> s {stWanted = (h, p, stLoc s) : stWanted s})
  pure (DHole h)

-- | Fresh type variables for the scheme, and a hole for each constraint.
instantiate :: Scheme -> TC (Type, [Type], [Dict])
instantiate (Forall vs ps t) = do
  ms <- mapM (const fresh) vs
  let s = M.fromList (zip vs ms)
  ds <- mapM (\(IsIn c pts) -> newHole (IsIn c (map (substT s) pts))) ps
  pure (substT s t, ms, ds)

-- | An environment where the given constraints, and their superclasses, are
-- available as dictionary parameters.
withGivens :: Env -> [Pred] -> Env
withGivens env ps = env {envGivens = concatMap close [(p, DParam (dictName p)) | p <- ps]}
  where
    close (p@(IsIn c ts), d) =
      (p, d) : concat
        [ close (IsIn s (map (substT sub) sts), DSuper d s)
        | Just ci <- [M.lookup c (envClasses env)]
        , let sub = M.fromList (zip (clsVars ci) ts)
        , IsIn s sts <- clsSupers ci ]

-- | The position of the type that chooses an instance of the class: the
-- only one in a class with one parameter, the one the others depend on in
-- a class with several.
keyPos :: Env -> Name -> Int
keyPos env c = maybe 0 clsKey (M.lookup c (envClasses env))

keyOf :: Env -> Pred -> Type
keyOf env (IsIn c ts) = ts !! keyPos env c

-- | The types the key determines.
dependents :: Env -> Pred -> [Type]
dependents env (IsIn c ts) = [t | (i, t) <- zip [0 ..] ts, i /= keyPos env c]

showPred :: Pred -> String
showPred (IsIn c ts) = unwords (unqual c : map prettyAtom ts)

-- | Chooses the instance's types for a constraint whose key is its type:
-- those of the key, and fresh ones for the variables only the context
-- fixes. The dependency makes the other types the instance's.
byInstance :: Env -> InstHead -> Pred -> TC (M.Map Name Type)
byInstance env ih p@(IsIn c _) = do
  let keyVars = tyVarsOf (keyOf env (IsIn c (ihHead ih)))
      kts = case keyOf env p of
        TCon _ ts -> ts
        _ -> []
  others <- mapM (\v -> (,) v <$> fresh) (filter (`notElem` keyVars) (ihVars ih))
  let s = M.fromList (zip keyVars kts ++ others)
  zipWithM_ unify (dependents env p) (map (substT s) (dependents env (IsIn c (ihHead ih))))
  pure s

-- | Applies the functional dependencies of the waiting constraints whose
-- key is known by now, so what they fix is known while checking goes on:
-- after n <- get, with MonadState Int m given, n is an Int.
improve :: Env -> TC ()
improve env = do
  ws <- gets stWanted
  forM_ [(p, l) | (_, p@(IsIn _ (_ : _ : _)), l) <- ws] $ \(IsIn c ts, l) -> atLoc l $ do
    p <- IsIn c <$> mapM zonkT ts
    let k = keyOf env p
    case [g | (g@(IsIn gc _), _) <- envGivens env, gc == c, keyOf env g == k] of
      g : _ -> zipWithM_ unify (dependents env p) (dependents env g)
      [] -> case k of
        TCon kc _ | Just ih <- M.lookup (c, kc) (envInsts env) -> void (byInstance env ih p)
        _ -> pure ()

-- | Solves every waiting constraint. Constraints on a type constructor are
-- reduced with instances; those on a variable come from the givens; those
-- left on a unification variable are generalised when the variable is in
-- the map (and returned), and defaulted otherwise.
solve :: Env -> M.Map Int Name -> TC [Pred]
solve env gen = fst <$> solveGen env gen

-- | The same, also returning the unification variables generalised because
-- a functional dependency ties them to those in the map: in
-- MonadState s m, generalising m generalises s. The caller binds them, as
-- it binds those in the map.
solveGen :: Env -> M.Map Int Name -> TC ([Pred], [(Int, Name)])
solveGen env gen0 = do
  (ps, extra) <- loop gen0 []
  pure (nub ps, extra)
  where
    loop gen deferred = do
      ws <- gets stWanted
      modify (\s -> s {stWanted = []})
      if null ws
        then finish gen deferred
        else do
          ds <- concat <$> mapM step ws
          loop gen (deferred ++ ds)
    step (h, IsIn c ts, l) = atLoc l $ do
      p <- IsIn c <$> mapM zonkT ts
      let k = keyOf env p
      case [(g, d) | (g@(IsIn gc _), d) <- envGivens env, gc == c, keyOf env g == k] of
        -- the dependency fixes the other types to the given's
        (g, d) : _ -> do
          zipWithM_ unify (dependents env p) (dependents env g)
          solved h d >> pure []
        [] -> case k of
          TMeta _ -> pure [(h, p, l)]
          TCon kc _ | Just ih <- M.lookup (c, kc) (envInsts env) -> do
            s <- byInstance env ih p
            subs <- mapM (\(IsIn c' pts) -> newHole (IsIn c' (map (substT s) pts))) (ihCtx ih)
            solved h (DInst (ihId ih) [s M.! v | v <- ihVars ih] subs)
            pure []
          TVar _ -> throw ("no instance for (" ++ showPred p ++ "): add it to the type signature")
          TCon "Double" [] | c == "Enum" ->
            throw "no instance for Enum Double: a range of floating-point numbers is not exact; map over a range of Int instead, as in map (\\i -> fromIntegral i / 10) [0 .. 10]"
          _ -> throw ("no instance for " ++ showPred p)
    finish gen deferred = do
      -- two waiting constraints of a class on the same type agree on the rest
      let tied = [(h, p) | (h, p@(IsIn _ (_ : _ : _)), _) <- deferred]
      forM_ tied $ \(h, p@(IsIn c _)) -> forM_ [q | (h', q@(IsIn c' _)) <- tied, h' > h, c' == c] $ \q -> do
        k1 <- zonkT (keyOf env p)
        k2 <- zonkT (keyOf env q)
        when (k1 == k2) $ zipWithM_ unify (dependents env p) (dependents env q)
      deferred' <- forM deferred $ \(h, IsIn c ts, l) -> do
        ts' <- mapM zonkT ts
        pure (h, IsIn c ts', l)
      let stillMeta = [(h, p, m, l) | (h, p, l) <- deferred', TMeta m <- [keyOf env p]]
          resolvedNow = [(h, p, l) | (h, p, l) <- deferred', not (isMetaT (keyOf env p))]
      -- defaulting may have resolved some of them already
      unless (null resolvedNow) $ modify (\s -> s {stWanted = resolvedNow ++ stWanted s})
      gen' <- close gen stillMeta
      let (generalised, ambiguous) = span' (\(_, _, m, _) -> M.member m gen') stillMeta
      preds <- forM generalised $ \(h, IsIn c ts, _, _) -> do
        let p = IsIn c (map (toVars gen') ts)
        solved h (DParam (dictName p))
        pure p
      forM_ (nub [m | (_, _, m, _) <- ambiguous]) $ \m -> do
        let cs = nub [c | (_, IsIn c _, m', _) <- ambiguous, m' == m]
            l = case [l' | (_, _, m', l') <- ambiguous, m' == m] of
              (l' : _) -> l'
              [] -> Nothing
        case defaultFor cs of
          Just t -> bindMeta m t
          Nothing -> atLoc l (throw ("ambiguous type: nothing fixes the type with " ++ intercalate ", " cs))
      unless (null ambiguous) $
        modify (\s -> s {stWanted = [(h, p, l) | (h, p, _, l) <- ambiguous] ++ stWanted s})
      let extra = M.toList (M.difference gen' gen)
      (rest, extra') <- if null ambiguous && null resolvedNow then pure ([], []) else loop gen' []
      pure (preds ++ rest, extra ++ extra')
    -- the variables a generalised constraint's key determines are generalised too
    close gen ds = do
      let new = nub [m | (_, p, k, _) <- ds, M.member k gen, t <- dependents env p, m <- metas t, not (M.member m gen)]
      if null new
        then pure gen
        else do
          vs <- mapM (const (uniq "f")) new
          close (M.union gen (M.fromList (zip new vs))) ds
    toVars gen = \case
      TMeta m | Just v <- M.lookup m gen -> TVar v
      TCon c ts -> TCon c (map (toVars gen) ts)
      TFun a b -> TFun (toVars gen a) (toVars gen b)
      TApp f x -> tApp (toVars gen f) (toVars gen x)
      t -> t
    solved :: Int -> Dict -> TC ()
    solved h d = modify (\s -> s {stSolved = IM.insert h d (stSolved s)})
    span' :: (a -> Bool) -> [a] -> ([a], [a])
    span' p xs = (filter p xs, filter (not . p) xs)
    isMetaT (TMeta _) = True
    isMetaT _ = False

-- | Haskell's defaulting, extended to () for constraints that only ask for
-- equality, order or showing.
defaultFor :: [Name] -> Maybe Type
defaultFor cs
  | any (`elem` ["Fractional", "Floating"]) cs = Just tDouble
  | any (`elem` ["Num", "Integral"]) cs = Just tInt
  | all (`elem` ["Eq", "Ord", "Show"]) cs = Just tUnit
  | otherwise = Nothing

pretty :: Type -> String
pretty = go (0 :: Int)
  where
    go _ (TVar v) = v
    go _ (TMeta _) = "_"
    go _ (TCon "[]" [t]) = "[" ++ go 0 t ++ "]"
    go _ (TCon c ts) | take 2 c == "(,", length ts == length c - 1 = "(" ++ intercalate ", " (map (go 0) ts) ++ ")"
    go p (TCon "->" [a]) = paren (p > 1) ("(->) " ++ go 2 a)
    go p (TCon c ts) | take 2 c == "(,", not (null ts) = paren (p > 1) (unwords (c : map (go 2) ts))
    go _ (TCon c []) = unqual c
    go p (TCon c ts) = paren (p > 1) (unwords (unqual c : map (go 2) ts))
    go p (TFun a b) = paren (p > 0) (go 1 a ++ " -> " ++ go 0 b)
    go p (TApp f x) = paren (p > 1) (go 1 f ++ " " ++ go 2 x)
    paren True s = "(" ++ s ++ ")"
    paren False s = s

prettyAtom :: Type -> String
prettyAtom t = case t of
  TCon "[]" [_] -> pretty t
  TCon c ts | Just n <- tupleArity c, length ts == n -> pretty t
  TCon _ (_ : _) -> "(" ++ pretty t ++ ")"
  TFun _ _ -> "(" ++ pretty t ++ ")"
  TApp _ _ -> "(" ++ pretty t ++ ")"
  _ -> pretty t
