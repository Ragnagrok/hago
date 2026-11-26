{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- | Local functions that are only called become top-level functions, given
-- what they use from around them as parameters, as GHC's lambda lifting
-- does. A local function is a Go closure: made again each time the code
-- around it runs, and on the heap when it calls itself, since the closure
-- holds the variable that holds it. A top-level function is made once.
--
-- First, a function whose body only makes local functions and cheap values
-- and gives one of the functions, as @eval c s f = go@ with @go@ defined in
-- its @where@, takes the argument that function takes (@eval c s f t = go
-- t@), so that the local function is only called: what is computed again
-- on each call (a variable, a constructor, a field of a value of a type of
-- one constructor) is cheaper than a closure.
--
-- Then, in a @let@ or a row's bindings, a group of mutually recursive
-- functions whose every use, inside the group and out, is a call with all
-- their arguments, is moved to the top. Its free local variables, in a
-- fixed order, come first in each function's parameters and in each call;
-- the type variables are those of the function around it. Binders are made
-- unique first, so that no variable passed at a call can be taken by
-- another of the same name there.
--
-- It runs after inlining, on code where every type is known and no
-- dictionary is left.
module Hago.Lift (liftLocals) where

import Control.Monad (foldM, forM, forM_)
import Control.Monad.State
import Data.Graph (flattenSCC, stronglyConnComp)
import Data.List (nub)
import qualified Data.Map as M
import qualified Data.Set as S
import Hago.Core
import Hago.Inline (freeVars, renameBinders)
import Hago.Syntax (Name)
import Hago.Typecheck (primSchemes)

data S = S
  { sNext :: Int
  , sNew :: [TopBind]        -- ^ the functions moved to the top, for the binding being lifted
  , sGlobals :: S.Set Name   -- ^ top-level names, the new ones among them
  }

type M = State S

liftLocals :: Program -> Program
liftLocals prog = prog {progBinds = concat (evalState (mapM top (progBinds prog)) s0)}
  where
    s0 = S 0 [] (S.unions [S.fromList (map tbName (progBinds prog)), M.keysSet (progForeign prog), M.keysSet primSchemes])
    top tb0 = do
      let tb = etaExpand prog tb0
      body <- renameBinders fresh (tbBody tb)
      modify (\s -> s {sNew = []})
      body' <- expr tb body
      new <- gets sNew
      pure (reverse new ++ [tb {tbBody = body'}])
    fresh :: Name -> M Name
    fresh x = do
      n <- gets sNext
      modify (\s -> s {sNext = n + 1})
      pure (takeWhile (`notElem` "#%") x ++ "#" ++ show n)

-- | The expression with its liftable local functions moved to the top
-- (recorded in the state), and the calls to them given their variables.
expr :: TopBind -> CExpr -> M CExpr
expr tb = go
  where
    go = \case
      CLet bs b t -> do
        (bs', scope) <- binds tb bs [b]
        let b' = case scope of
              [x] -> x
              _ -> error "lift: the body lost"
        bs'' <- mapM (\(CBind n ty ar x) -> CBind n ty ar <$> go x) bs'
        b'' <- go b'
        pure (if null bs'' then b'' else CLet bs'' b'' t)
      CMatch ss rows t -> CMatch <$> mapM go ss <*> mapM row rows <*> pure t
      CApp f as -> CApp <$> go f <*> mapM go as
      CLam ps r b -> CLam ps r <$> go b
      CIf a b c t -> CIf <$> go a <*> go b <*> go c <*> pure t
      CDelay t x -> CDelay t <$> go x
      CForce x -> CForce <$> go x
      CDo m d r ss -> CDo m d r <$> mapM stmt ss
      e -> pure e
    row (CRow ps bs gs) = do
      let scope = concat [maybe [] pure g ++ [e] | (g, e) <- gs]
      (bs', scope') <- binds tb bs scope
      bs'' <- mapM (\(CBind n ty ar x) -> CBind n ty ar <$> go x) bs'
      gs' <- mapM (\(g, e) -> (,) <$> traverse go g <*> go e) (regroup gs scope')
      pure (CRow ps bs'' gs')
    -- the guards and bodies, back in their places
    regroup [] _ = []
    regroup ((Just _, _) : gs) (g : e : rest) = (Just g, e) : regroup gs rest
    regroup ((Nothing, _) : gs) (e : rest) = (Nothing, e) : regroup gs rest
    regroup _ _ = error "lift: guards lost"
    stmt = \case
      CSBind x t e -> CSBind x t <$> go e
      CSExpr t e -> CSExpr t <$> go e
      CSLet bs -> CSLet <$> mapM (\(CBind n ty ar x) -> CBind n ty ar <$> go x) bs

-- | Of these bindings, the groups of functions that can be moved to the
-- top, moved, and the rest of the bindings and the expressions of their
-- scope with the calls to them rewritten. The groups are taken callees
-- first, so that a group calling one moved before passes on its variables.
binds :: TopBind -> [CBind] -> [CExpr] -> M ([CBind], [CExpr])
binds tb bs0 scope0 = foldM one (bs0, scope0) groups
  where
    names = [n | CBind n _ _ _ <- bs0]
    groups =
      map (map (\(CBind n _ _ _) -> n) . flattenSCC) $
        stronglyConnComp [(b, n, filter (`elem` names) (coreRefs x)) | b@(CBind n _ _ x) <- bs0]
    one (bs, scope) g = do
      globals <- gets sGlobals
      let members = [b | b@(CBind n _ _ _) <- bs, n `elem` g]
          arities = M.fromList [(n, ar) | CBind n _ ar _ <- members]
          everythingIn = [x | CBind _ _ _ x <- bs] ++ scope
          isFunction (CBind _ _ ar x) = ar > 0 && case x of
            CLam ps _ _ -> length ps == ar
            _ -> False
          used = nub [x | CBind _ _ _ b <- members, x <- S.toList (freeVars b), x `notElem` g, not (S.member x globals)]
          typeOf x = case [t | CBind _ _ _ b <- members, CVar y _ t <- everything @CExpr b, y == x] of
            t : _ -> Just t
            [] -> Nothing
          typed = [(x, t) | x <- used, Just t <- [typeOf x]]
      if length members /= length g || not (all isFunction members) || not (all (saturated arities) everythingIn)
         || length typed /= length used
        then pure (bs, scope)
        else do
          lifted <- forM members $ \(CBind n _ _ _) -> do
            k <- gets sNext
            modify (\s -> s {sNext = k + 1})
            pure (n, tbName tb ++ "'" ++ takeWhile (`notElem` "#%") n ++ "'" ++ show k)
          let liftedOf = M.fromList lifted
              targs = map TVar (tbParams tb)
              passed = [CVar x (Inst [] []) t | (x, t) <- typed]
              call = everywhere $ \case
                CApp (CVar f _ ft) as | Just f' <- M.lookup f liftedOf, length as >= arities M.! f ->
                  CApp (CVar f' (Inst targs []) (foldr (TFun . snd) ft typed)) (passed ++ as)
                e -> e
          forM_ members $ \(CBind n t ar x) -> case call x of
            CLam ps r b -> do
              let tb' = TopBind (liftedOf M.! n) (tbParams tb) [] (foldr (TFun . snd) t typed) (length typed + ar) (CLam (typed ++ ps) r b) False
              b' <- expr tb' (tbBody tb')
              modify (\s -> s {sNew = tb' {tbBody = b'} : sNew s, sGlobals = S.insert (tbName tb') (sGlobals s)})
            _ -> error "lift: not a function"
          pure ([CBind n t ar (call x) | CBind n t ar x <- bs, n `notElem` g], map call scope)
    -- every occurrence of a function of the group is the head of a call
    -- with all its arguments
    saturated arities e =
      let occurrences = length [() | CVar x _ _ <- everything @CExpr e, M.member x arities]
          calls = length [() | CApp (CVar x _ _) as <- everything @CExpr e, Just ar <- [M.lookup x arities], length as >= ar]
       in occurrences == calls

-- | A function whose body makes local functions and cheap values and gives
-- one of the functions takes that function's argument too.
etaExpand :: Program -> TopBind -> TopBind
etaExpand prog tb = case tbBody tb of
  CLam ps r inner
    | tbArity tb > 0, not (tbShared tb), length ps == tbArity tb
    , TFun a b <- zonk (progSubst prog) r
    , Just inner' <- push a b inner ->
        etaExpand prog tb {tbArity = tbArity tb + 1, tbBody = CLam (ps ++ [(q, a)]) b inner'}
  _ -> tb
  where
    q = "eta#" ++ show (tbArity tb)
    push a b = \case
      CLet bs body _ | all cheap bs -> (\body' -> CLet bs body' b) <$> push a b body
      -- a clause's patterns and its where
      CMatch ss [CRow pats bs [(Nothing, body)]] _
        | all irrefutable pats, all cheap bs -> (\body' -> CMatch ss [CRow pats bs [(Nothing, body')]] b) <$> push a b body
      CVar f ref t | f `elem` locals -> Just (CApp (CVar f ref t) [CVar q (Inst [] []) a])
      _ -> Nothing
    locals =
      [n | CLet bs _ _ <- everything @CExpr (tbBody tb), CBind n _ ar _ <- bs, ar > 0]
        ++ [n | CRow _ bs _ <- everything @CRow (tbBody tb), CBind n _ ar _ <- bs, ar > 0]
    cheap (CBind _ _ ar x) = ar > 0 || cheapValue x
    cheapValue = \case
      CVar {} -> True
      CLit _ -> True
      CNum {} -> True
      CCon {} -> True
      CApp (CCon {}) as -> all cheapValue as
      -- arithmetic and comparisons that cannot fail
      CApp (CVar p _ _) as | p `elem` cheapPrims -> all cheapValue as
      CMatch [CVar {}] [CRow [p] [] [(Nothing, body)]] _ -> irrefutable p && cheapValue body
      _ -> False
    cheapPrims = ["primAdd", "primSub", "primMul", "primNeg", "primEq", "primNeq", "primLt", "primLe", "primGt", "primGe"]
    -- a pattern that cannot fail: variables under constructors that are
    -- the only ones of their types
    irrefutable = \case
      CPVar _ _ -> True
      CPWild -> True
      CPCon k _ qs
        | Just ci <- M.lookup k (progCons prog), Just di <- M.lookup (ciType ci) (progData prog), length (diCons di) == 1 -> all irrefutable qs
      _ -> False
