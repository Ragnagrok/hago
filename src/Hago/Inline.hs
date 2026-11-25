{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- | Small functions are copied into the places that call them. The library
-- is made of them: an action on a mutable vector is a call to Go wrapped in
-- 'unsafePrimIO', which for ST wraps nothing once newtypes are gone; ST's
-- @>>=@ is IO's with a conversion that is nothing too; 'when' is an @if@.
-- Each was a Go call that built a closure, so a loop over a vector built
-- three or four of them per step. Copied, they leave the primitives
-- (@primBindIO@, a call to Go, an @if@) where code generation can see them
-- and run the action directly (see 'Hago.CodeGen').
--
-- It runs after specialisation and the erasure of newtypes, on code where
-- every type is known and no dictionary is left. A function is copied when
-- it is not recursive and its body is small, and a call is replaced by the
-- body only if that does not change what is computed or when:
--
-- * an argument that is a variable or a literal can go anywhere, any
--   number of times;
-- * a value that costs nothing to make and cannot fail (a lambda, a
--   suspension, a constructor of such values) can go where the parameter
--   is used once, as long as that is not inside a lambda, which could make
--   it many times (a lambda can go anywhere it is used once);
-- * anything else, one argument per call at most, only where the
--   parameter is used once, outside lambdas and @do@ blocks, so that it is
--   still computed once, before any action runs.
--
-- Otherwise the call stays a call. Names bound in a copied body are
-- renamed, so nothing in it can capture a variable of the arguments.
module Hago.Inline (inlineSmall) where

import Control.Monad (when)
import Control.Monad.State
import Data.Data (Data, gmapT)
import Data.Graph (flattenSCCs, stronglyConnComp)
import qualified Data.Map as M
import qualified Data.Set as S
import Data.Type.Equality ((:~:) (..))
import Data.Typeable (eqT)
import Hago.Core
import Hago.Syntax (Name)

-- | A function that can be copied: its type parameters, its parameters and
-- its body (simplified already).
data Candidate = Candidate [Name] [(Name, Type)] CExpr

data S = S {sNext :: Int, sCands :: M.Map Name Candidate}

type M = State S

inlineSmall :: Program -> Program
inlineSmall prog = prog {progBinds = map (done M.!) (map tbName (progBinds prog))}
  where
    -- callees first: specialisation adds its copies after their callers
    order = flattenSCCs (stronglyConnComp [(tb, tbName tb, coreRefs (tbBody tb)) | tb <- progBinds prog])
    done = M.fromList [(tbName tb, tb) | tb <- evalState (mapM top order) (S 0 M.empty)]
    top tb = do
      body <- simp 0 (tbBody tb)
      let tb' = tb {tbBody = body}
      when (candidate tb') $
        case body of
          CLam ps _ b -> modify (\s -> s {sCands = M.insert (tbName tb) (Candidate (tbParams tb) ps b) (sCands s)})
          _ -> pure ()
      pure tb'

-- | Whether a top-level binding is copied where it is called: a function,
-- not recursive, small, and either an action or an expression that is not
-- a @case@, an @if@ or a @let@, which in the middle of an expression would
-- become a Go function called on the spot instead of a call. The Prelude's
-- @&&@ and @||@ are Go's operators already.
candidate :: TopBind -> Bool
candidate tb = case tbBody tb of
  CLam ps r b ->
    tbArity tb == length ps
      && tbArity tb > 0
      && not (tbShared tb)
      && null (tbDicts tb)
      && tbName tb `notElem` ["&&", "||"]
      && tbName tb `notElem` coreRefs b
      && null [() | CVar _ SelfGroup _ <- everything b]
      && size b <= 16
      && (isIO r || not (branches b))
  _ -> False
  where
    isIO = \case
      TCon "IO" _ -> True
      _ -> False
    branches = \case
      CMatch {} -> True
      CIf {} -> True
      CLet {} -> True
      _ -> False

size :: CExpr -> Int
size e = length (everything @CExpr e) + length (everything @CStmt e)

-- Simplification ------------------------------------------------------------------

-- | Copies known small functions in, then removes what that leaves behind:
-- a suspension forced at once, a lambda applied at once, a @case@ that only
-- names its scrutinees. The depth keeps a chain of copies finite.
simp :: Int -> CExpr -> M CExpr
simp d = \case
  CApp f as -> do
    f' <- simp d f
    as' <- mapM (simp d) as
    app d f' as'
  CLam ps r b -> CLam ps r <$> simp d b
  CLet bs b t -> CLet <$> mapM (simpBind d) bs <*> simp d b <*> pure t
  CMatch ss rows t -> do
    ss' <- mapM (simp d) ss
    rows' <- mapM (simpRow d) rows
    pure (match ss' rows' t)
  CIf a b c t -> CIf <$> simp d a <*> simp d b <*> simp d c <*> pure t
  CDelay t x -> CDelay t <$> simp d x
  CForce x -> do
    x' <- simp d x
    pure $ case x' of
      CDelay _ y -> y
      _ -> CForce x'
  CDo m dict r ss -> CDo m dict r <$> mapM (simpStmt d) ss
  e -> pure e

simpBind :: Int -> CBind -> M CBind
simpBind d (CBind n t ar b) = CBind n t ar <$> simp d b

simpRow :: Int -> CRow -> M CRow
simpRow d (CRow ps bs gs) = CRow ps <$> mapM (simpBind d) bs <*> mapM (\(g, e) -> (,) <$> traverse (simp d) g <*> simp d e) gs

simpStmt :: Int -> CStmt -> M CStmt
simpStmt d = \case
  CSBind x t e -> CSBind x t <$> simp d e
  CSExpr t e -> CSExpr t <$> simp d e
  CSLet bs -> CSLet <$> mapM (simpBind d) bs

-- | An application, with its arguments simplified already.
app :: Int -> CExpr -> [CExpr] -> M CExpr
app d f as = case f of
  _ | null as -> pure f
  CApp g bs -> app d g (bs ++ as)
  CLam ps _ _ | length as >= length ps -> do
    -- rename what the lambda binds if an argument mentions it, or if it
    -- binds a name twice
    let bs = coreBinders f
        clean = length bs == S.size (S.fromList bs) && S.disjoint (S.fromList bs) (S.fromList (concatMap coreRefs as))
    (ps', b) <- lamParts <$> if clean then pure f else freshen f
    let (now, later) = splitAt (length ps') as
    r <- bindArgs (zip ps' now) b
    case r of
      Just b' -> simp (d + 1) b' >>= \b'' -> app d b'' later
      Nothing -> pure (CApp f as)
  CVar x (Inst ts _) _ | d < 8 -> do
    cands <- gets sCands
    case M.lookup x cands of
      Just (Candidate tps ps b) | length ts == length tps, length as >= length ps -> do
        let s = M.fromList (zip tps ts)
        (ps', b') <- lamParts <$> freshen (outermostT (substTV s) (CLam ps tUnit b))
        let (now, later) = splitAt (length ps') as
        r <- bindArgs (zip ps' now) b'
        case r of
          Just b'' -> simp (d + 1) b'' >>= \e -> app d e later
          Nothing -> pure (CApp f as)
      _ -> pure (CApp f as)
  _ -> pure (CApp f as)

lamParts :: CExpr -> ([(Name, Type)], CExpr)
lamParts = \case
  CLam ps _ b -> (ps, b)
  _ -> error "inline: not a lambda"

-- | The body with its parameters replaced by the arguments, if every one of
-- them can be (see the module's comment). The parameters are fresh names,
-- bound nowhere else.
bindArgs :: [((Name, Type), CExpr)] -> CExpr -> M (Maybe CExpr)
bindArgs pas body
  | all ok pas && length [() | (_, a) <- pas, not (atomic a), not (value a)] <= 1 =
      pure (Just (substVars (M.fromList [(p, a) | ((p, _), a) <- pas]) body))
  | otherwise = pure Nothing
  where
    ok ((p, _), a)
      | atomic a = True
      | CLam {} <- a = uses p body <= 1
      | value a = uses p body <= 1 && not (underLam p body)
      | otherwise = uses p body == 1 && not (underLam p body) && not (inDo p body)

-- | A variable or a literal: copying it costs nothing.
atomic :: CExpr -> Bool
atomic = \case
  CVar {} -> True
  CLit _ -> True
  CNum {} -> True
  CFrac {} -> True
  CCon {} -> True
  _ -> False

-- | Made at once and never failing.
value :: CExpr -> Bool
value = \case
  CLam {} -> True
  CDelay {} -> True
  CApp (CCon {}) as -> all (\a -> atomic a || value a) as
  e -> atomic e

uses :: Name -> CExpr -> Int
uses p e = length [() | CVar x _ _ <- everything e, x == p]

-- | Whether the variable is used inside a lambda in the expression.
underLam :: Name -> CExpr -> Bool
underLam p e = or [uses p b > 0 | CLam _ _ b <- everything e]

-- | Whether the variable is used inside a do block, whose statements run
-- after the actions before them.
inDo :: Name -> CExpr -> Bool
inDo p e = or [p `elem` coreRefs d | d@CDo {} <- everything e]

-- | A @case@ whose one row only names its scrutinees, which are variables,
-- is its body with the names replaced, when nothing in it binds them again.
match :: [CExpr] -> [CRow] -> Type -> CExpr
match ss rows t = case rows of
  [CRow ps [] [(Nothing, body)]]
    | length ps == length ss
    , Just named' <- sequence (zipWith named ps ss)
    , let pairs = [(x, s) | (Just x, s) <- named']
    , S.disjoint (S.fromList (coreBinders body)) (S.fromList (concatMap coreRefs ss ++ map fst pairs)) ->
        substVars (M.fromList pairs) body
  _ -> CMatch ss rows t
  where
    named p s = case (p, s) of
      (CPVar x _, CVar {}) -> Just (Just x, s)
      (CPWild, _) | atomic s -> Just (Nothing, s)
      _ -> Nothing

-- | Replaces free variables. Every binder the expression has is assumed not
-- to be one of them (the caller renamed them, or checked).
substVars :: M.Map Name CExpr -> CExpr -> CExpr
substVars s = everywhere $ \case
  CVar x _ _ | Just e <- M.lookup x s -> e
  e -> e

-- Renaming ---------------------------------------------------------------------------

-- | The expression with every name it binds made new: x becomes x#n.
freshen :: CExpr -> M CExpr
freshen = expr M.empty
  where
    fresh :: Name -> M Name
    fresh x = do
      n <- gets sNext
      modify (\s -> s {sNext = n + 1})
      pure (takeWhile (/= '#') x ++ "#" ++ show n)
    freshAll env xs = do
      ys <- mapM fresh xs
      pure (foldr (uncurry M.insert) env (zip xs ys))
    ren env x = M.findWithDefault x x env

    expr env = \case
      CVar x ref t -> pure (CVar (ren env x) ref t)
      CApp f as -> CApp <$> expr env f <*> mapM (expr env) as
      CLam ps r b -> do
        env' <- freshAll env (map fst ps)
        CLam [(ren env' p, t) | (p, t) <- ps] r <$> expr env' b
      CLet bs b t -> do
        env' <- freshAll env [n | CBind n _ _ _ <- bs]
        CLet <$> mapM (bind env') bs <*> expr env' b <*> pure t
      CMatch ss rows t -> CMatch <$> mapM (expr env) ss <*> mapM (row env) rows <*> pure t
      CIf a b c t -> CIf <$> expr env a <*> expr env b <*> expr env c <*> pure t
      CDelay t x -> CDelay t <$> expr env x
      CForce x -> CForce <$> expr env x
      CDo m d r ss -> CDo m d r <$> stmts env ss
      e -> pure e

    bind env (CBind n t ar b) = CBind (ren env n) t ar <$> expr env b

    row env (CRow ps bs gs) = do
      env1 <- freshAll env (concatMap patBinders ps)
      ps' <- mapM (pat env env1) ps
      env2 <- freshAll env1 [n | CBind n _ _ _ <- bs]
      CRow ps' <$> mapM (bind env2) bs <*> mapM (\(g, e) -> (,) <$> traverse (expr env2) g <*> expr env2 e) gs

    -- the names a pattern binds take env', what it compares with takes env
    pat env env' = \case
      CPVar x t -> pure (CPVar (ren env' x) t)
      CPAs x t q -> CPAs (ren env' x) t <$> pat env env' q
      CPCon k ts qs -> CPCon k ts <$> mapM (pat env env') qs
      CPForce q -> CPForce <$> pat env env' q
      CPEq f v -> CPEq <$> expr env f <*> expr env v
      q -> pure q

    stmts _ [] = pure []
    stmts env (st : rest) = case st of
      CSBind x t e -> do
        e' <- expr env e
        env' <- freshAll env [x | x /= "_"]
        (CSBind (ren env' x) t e' :) <$> stmts env' rest
      CSExpr t e -> do
        e' <- expr env e
        (CSExpr t e' :) <$> stmts env rest
      CSLet bs -> do
        env' <- freshAll env [n | CBind n _ _ _ <- bs]
        bs' <- mapM (bind env') bs
        (CSLet bs' :) <$> stmts env' rest

patBinders :: CPat -> [Name]
patBinders = \case
  CPVar x _ -> [x]
  CPAs x _ q -> x : patBinders q
  CPCon _ _ qs -> concatMap patBinders qs
  CPForce q -> patBinders q
  _ -> []

-- | Applies f to every outermost type, without looking inside the result.
outermostT :: forall a. Data a => (Type -> Type) -> a -> a
outermostT f = go
  where
    go :: forall b. Data b => b -> b
    go x = case eqT @b @Type of
      Just Refl -> f x
      Nothing -> gmapT go x
