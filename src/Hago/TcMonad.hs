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
import Hago.Core
import Hago.Syntax (Loc, Name, showLoc, unqual)

data InstHead = InstHead {ihId :: Name, ihVars :: [Name], ihCtx :: [Pred]}

data Env = Env
  { envVars :: M.Map Name (Scheme, Bool)   -- ^ scheme, and whether it is a recursive group member
  , envCons :: M.Map Name ConInfo
  , envTypes :: M.Map Name Int             -- ^ type constructors and their arity
  , envClasses :: M.Map Name ClassInfo
  , envInsts :: M.Map (Name, Name) InstHead -- ^ by class and type constructor
  , envGivens :: [(Pred, Dict)]            -- ^ constraints available as dictionary parameters
  , envRecords :: M.Map Name Record        -- ^ the fields of each record type
  }

-- | A record type: its constructors, and each field's laziness, type (over
-- the type's parameters) and position in the constructors that have it.
data Record = Record {recParams :: [Name], recCons :: [Name], recFields :: M.Map Name (Bool, Type, [(Name, Int)])}

data St = St
  { stNext :: Int
  , stSub :: Subst
  , stWanted :: [(Int, Pred, Maybe Loc)]   -- ^ constraints waiting to be solved, by hole, with where they arose
  , stSolved :: IM.IntMap Dict
  , stLoc :: Maybe Loc                     -- ^ the innermost expression or pattern being checked
  }

-- | An error: where, inside which definitions (outermost first), and what.
data TcErr = TcErr (Maybe Loc) [Name] String

type TC = StateT St (Either TcErr)

throw :: String -> TC a
throw msg = do
  l <- gets stLoc
  throwError (TcErr l [] msg)

withCtx :: Name -> TC a -> TC a
withCtx n act = act `catchError` \(TcErr l cs m) -> throwError (TcErr l (n : cs) m)

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
      throw ("type mismatch: expected " ++ pretty y' ++ ", got " ++ pretty x')
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
    step (h, IsIn c t, l) = atLoc l $ do
      t' <- zonkT t
      case lookup (IsIn c t') (envGivens env) of
        Just d -> solved h d >> pure []
        Nothing -> case t' of
          TMeta m -> pure [(h, c, m, l)]
          TCon k ts | Just ih <- M.lookup (c, k) (envInsts env) -> do
            let s = M.fromList (zip (ihVars ih) ts)
            subs <- mapM (\(IsIn c' pt) -> newHole (IsIn c' (substT s pt))) (ihCtx ih)
            solved h (DInst (ihId ih) ts subs)
            pure []
          TVar v -> throw ("no instance for (" ++ c ++ " " ++ v ++ "): add it to the type signature")
          TCon "Double" [] | c == "Enum" ->
            throw "no instance for Enum Double: a range of floating-point numbers is not exact; map over a range of Int instead, as in map (\\i -> fromIntegral i / 10) [0 .. 10]"
          _ -> throw ("no instance for " ++ c ++ " " ++ prettyAtom t')
    finish deferred = do
      deferred' <- forM deferred $ \(h, c, m, l) -> do
        t <- zonkT (TMeta m)
        pure (h, c, t, l)
      let stillMeta = [(h, c, m, l) | (h, c, TMeta m, l) <- deferred']
          resolvedNow = [(h, IsIn c t, l) | (h, c, t, l) <- deferred', not (isMetaT t)]
      -- defaulting may have resolved some of them already
      unless (null resolvedNow) $ modify (\s -> s {stWanted = resolvedNow ++ stWanted s})
      let (generalised, ambiguous) = span' (\(_, _, m, _) -> M.member m gen) stillMeta
      preds <- forM generalised $ \(h, c, m, _) -> do
        let v = gen M.! m
        solved h (DParam (dictName c v))
        pure (IsIn c (TVar v))
      forM_ (nub [m | (_, _, m, _) <- ambiguous]) $ \m -> do
        let cs = nub [c | (_, c, m', _) <- ambiguous, m' == m]
            l = case [l' | (_, _, m', l') <- ambiguous, m' == m] of
              (l' : _) -> l'
              [] -> Nothing
        case defaultFor cs of
          Just t -> bindMeta m t
          Nothing -> atLoc l (throw ("ambiguous type: nothing fixes the type with " ++ intercalate ", " cs))
      unless (null ambiguous) $
        modify (\s -> s {stWanted = [(h, IsIn c (TMeta m), l) | (h, c, m, l) <- ambiguous] ++ stWanted s})
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
  TCon _ (_ : _) -> "(" ++ pretty t ++ ")"
  TFun _ _ -> "(" ++ pretty t ++ ")"
  TApp _ _ -> "(" ++ pretty t ++ ")"
  _ -> pretty t
