{-# LANGUAGE LambdaCase #-}

-- | The type checker's monad: unification, instantiation, and the solver
-- that turns class constraints into dictionaries.
module Hago.TcMonad where

import Control.Monad
import Control.Monad.Except
import Control.Monad.State
import qualified Data.IntMap as IM
import Data.List (intercalate, nub)
import qualified Data.Map as M
import Data.Maybe (fromMaybe)
import Hago.Core
import Hago.Syntax (Name)

data InstHead = InstHead {ihId :: Name, ihVars :: [Name], ihCtx :: [Pred]}

data Env = Env
  { envVars :: M.Map Name (Scheme, Bool)   -- ^ scheme, and whether it is a recursive group member
  , envCons :: M.Map Name ConInfo
  , envTypes :: M.Map Name Int             -- ^ type constructors and their arity
  , envClasses :: M.Map Name ClassInfo
  , envInsts :: M.Map (Name, Name) InstHead -- ^ by class and type constructor
  , envGivens :: [(Pred, Dict)]            -- ^ constraints available as dictionary parameters
  }

data St = St
  { stNext :: Int
  , stSub :: Subst
  , stWanted :: [(Int, Pred)]   -- ^ constraints waiting to be solved, by hole
  , stSolved :: IM.IntMap Dict
  }

type TC = StateT St (Either String)

throw :: String -> TC a
throw = throwError

withCtx :: Name -> TC a -> TC a
withCtx n act = act `catchError` \e -> throwError ("in " ++ n ++ ": " ++ e)

next :: TC Int
next = do
  n <- gets stNext
  modify (\s -> s {stNext = n + 1})
  pure n

fresh :: TC Type
fresh = TMeta <$> next

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

-- | A new constraint to solve; returns the hole its dictionary will fill.
newHole :: Pred -> TC Dict
newHole p = do
  h <- next
  modify (\s -> s {stWanted = (h, p) : stWanted s})
  pure (DHole h)

-- | Fresh type variables for the scheme, and a hole for each constraint.
instantiate :: Scheme -> TC (Type, [Type], [Dict])
instantiate (Forall vs ps t) = do
  ms <- mapM (const fresh) vs
  let s = M.fromList (zip vs ms)
  ds <- mapM (\(IsIn c pt) -> newHole (IsIn c (substT s pt))) ps
  pure (substT s t, ms, ds)

-- | An environment where the given constraints, and their superclasses, are
-- available as dictionary parameters.
withGivens :: Env -> [Pred] -> Env
withGivens env ps = env {envGivens = concatMap close [(p, DParam (dictName c v)) | p@(IsIn c (TVar v)) <- ps]}
  where
    close (p@(IsIn c t), d) =
      (p, d) : concat [close (IsIn s t, DSuper d s) | s <- maybe [] clsSupers (M.lookup c (envClasses env))]

-- | Solves every waiting constraint. Constraints on a type constructor are
-- reduced with instances; those on a variable come from the givens; those
-- left on a unification variable are generalised when the variable is in
-- the map (and returned), and defaulted otherwise.
solve :: Env -> M.Map Int Name -> TC [Pred]
solve env gen = nub <$> loop []
  where
    loop deferred = do
      ws <- gets stWanted
      modify (\s -> s {stWanted = []})
      if null ws
        then finish deferred
        else do
          ds <- concat <$> mapM step ws
          loop (deferred ++ ds)
    step (h, IsIn c t) = do
      t' <- zonkT t
      case lookup (IsIn c t') (envGivens env) of
        Just d -> solved h d >> pure []
        Nothing -> case t' of
          TMeta m -> pure [(h, c, m)]
          TCon k ts | Just ih <- M.lookup (c, k) (envInsts env) -> do
            let s = M.fromList (zip (ihVars ih) ts)
            subs <- mapM (\(IsIn c' pt) -> newHole (IsIn c' (substT s pt))) (ihCtx ih)
            solved h (DInst (ihId ih) ts subs)
            pure []
          TVar v -> throw ("no instance for (" ++ c ++ " " ++ v ++ "): add it to the type signature")
          _ -> throw ("no instance for " ++ c ++ " " ++ prettyAtom t')
    finish deferred = do
      deferred' <- forM deferred $ \(h, c, m) -> do
        t <- zonkT (TMeta m)
        pure (h, c, t)
      let stillMeta = [(h, c, m) | (h, c, TMeta m) <- deferred']
          resolvedNow = [(h, IsIn c t) | (h, c, t) <- deferred', not (isMetaT t)]
      -- defaulting may have resolved some of them already
      unless (null resolvedNow) $ modify (\s -> s {stWanted = resolvedNow ++ stWanted s})
      let (generalised, ambiguous) = span' (\(_, _, m) -> M.member m gen) stillMeta
      preds <- forM generalised $ \(h, c, m) -> do
        let v = gen M.! m
        solved h (DParam (dictName c v))
        pure (IsIn c (TVar v))
      forM_ (nub [m | (_, _, m) <- ambiguous]) $ \m -> do
        let cs = nub [c | (_, c, m') <- ambiguous, m' == m]
        case defaultFor cs of
          Just t -> bindMeta m t
          Nothing -> throw ("ambiguous type variable with constraints " ++ intercalate ", " cs)
      unless (null ambiguous) $
        modify (\s -> s {stWanted = [(h, IsIn c (TMeta m)) | (h, c, m) <- ambiguous] ++ stWanted s})
      rest <- if null ambiguous && null resolvedNow then pure [] else loop []
      pure (preds ++ rest)
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
  | "Fractional" `elem` cs = Just tDouble
  | any (`elem` ["Num", "Integral"]) cs = Just tInt
  | all (`elem` ["Eq", "Ord", "Show"]) cs = Just tUnit
  | otherwise = Nothing

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

prettyAtom :: Type -> String
prettyAtom t = case t of
  TCon _ (_ : _) -> "(" ++ pretty t ++ ")"
  TFun _ _ -> "(" ++ pretty t ++ ")"
  _ -> pretty t
