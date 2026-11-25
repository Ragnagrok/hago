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
module Hago.Inline (inlineSmall, renameBinders) where

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
import Hago.Typecheck (primSchemes)

-- | A function that can be copied: its type parameters, its parameters and
-- its body (simplified already).
data Candidate = Candidate [Name] [(Name, Type)] CExpr

-- | A recursive function with a parameter that is a function, passed as it
-- is to every call to itself: its binding, and that parameter's position.
data Static = Static TopBind Int

data S = S
  { sNext :: Int
  , sCands :: M.Map Name Candidate
  , sAliases :: M.Map Name CExpr
  , sStatics :: M.Map Name Static
  , sSpecs :: M.Map (Name, String) Name   -- ^ the copies made, by function and argument
  , sNew :: [TopBind]                     -- ^ the copies, to add to the program
  , sGlobals :: S.Set Name                -- ^ the names an argument may use and still be closed
  }

type M = State S

inlineSmall :: Program -> Program
inlineSmall prog = prog {progBinds = map (done M.!) (map tbName (progBinds prog)) ++ reverse new}
  where
    -- callees first: specialisation adds its copies after their callers
    order = flattenSCCs (stronglyConnComp [(tb, tbName tb, coreRefs (tbBody tb)) | tb <- progBinds prog])
    globals = S.unions [S.fromList (map tbName (progBinds prog)), M.keysSet (progForeign prog), M.keysSet primSchemes]
    (results, final) = runState (mapM top order) (S 0 M.empty M.empty M.empty M.empty [] globals)
    done = M.fromList [(tbName tb, tb) | tb <- results]
    new = sNew final
    top tb = do
      body <- simp 0 (tbBody tb)
      let tb' = tb {tbBody = body}
      case staticParam tb' of
        Just j -> modify (\s -> s {sStatics = M.insert (tbName tb) (Static tb' j) (sStatics s)})
        Nothing -> pure ()
      -- a value that only names another (Iter's empty is none) is that one
      when (null (tbParams tb) && tbArity tb == 0 && alias body) $
        modify (\s -> s {sAliases = M.insert (tbName tb) body (sAliases s)})
      when (candidate (progData prog) tb') $
        case body of
          CLam ps _ b -> modify (\s -> s {sCands = M.insert (tbName tb) (Candidate (tbParams tb) ps b) (sCands s)})
          _ -> pure ()
      pure tb'

alias :: CExpr -> Bool
alias = \case
  CVar _ (Inst [] []) _ -> True
  CVar _ (Inst _ []) _ -> True
  _ -> False

-- | Whether a top-level binding is copied where it is called: a function,
-- not recursive, small, and either an action or an expression that is not
-- a @case@, an @if@ or a @let@, which in the middle of an expression would
-- become a Go function called on the spot instead of a call. The Prelude's
-- @&&@ and @||@ are Go's operators already.
candidate :: M.Map Name DataInfo -> TopBind -> Bool
candidate datas tb = case tbBody tb of
  CLam ps r b ->
    -- a function, or a value that is one (StateT's get, once the newtype
    -- is gone, is \s -> pure (s, s))
    (tbArity tb == length ps && tbArity tb > 0 && not (tbShared tb) || tbArity tb == 0)
      && null (tbDicts tb)
      && tbName tb `notElem` ["&&", "||"]
      && tbName tb `notElem` coreRefs b
      && null [() | CVar _ SelfGroup _ <- everything b]
      && (size b <= 16 || isFold b && size b <= 64 || isLam b && size b <= 32)
      && (isIO r || foreignType r || not (branches b))
  _ -> False
  where
    -- a fold of a list (mapM_ at a monad), copied whatever its size so that
    -- it meets the list it folds, which code generation makes a loop of
    isFold = \case
      CApp (CVar f _ _) _ -> f `elem` ["listFoldr", "listFoldl"]
      _ -> False
    -- an action of a monad that is a function once newtypes are gone
    -- (StateT's modify is \s -> ...), which the caller usually applies at
    -- once
    isLam = \case
      CLam {} -> True
      _ -> False
    isIO = \case
      TCon "IO" _ -> True
      _ -> False
    -- a Go type, as Iter: an if that gives one is a choice of loops where
    -- the value is folded or made into an Iter (see Hago.CodeGen's Prod)
    foreignType = \case
      TCon c _ | Just di <- M.lookup c datas -> diForeign di /= Nothing
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
  e@(CVar x (Inst [] []) _) -> gets (maybe e id . M.lookup x . sAliases)
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
    statics <- gets sStatics
    globals <- gets sGlobals
    case M.lookup x cands of
      -- a recursive function given a known function where it takes one: a
      -- copy of it for that function
      Nothing | Just (Static tb j) <- M.lookup x statics, length as == tbArity tb, length ts == length (tbParams tb)
              , all concrete ts, known globals (as !! j) -> do
        g <- specialiseOn tb ts j (as !! j)
        case g of
          Just (name, t') -> pure (CApp (CVar name (Inst [] []) t') [a | (i, a) <- zip [0 :: Int ..] as, i /= j])
          Nothing -> pure (CApp f as)
      Just (Candidate tps ps0 b0) | length ts == length tps, length as >= length ps0 -> do
        let s = M.fromList (zip tps ts)
            -- the lambdas the body returns take the arguments left too
            (ps, b) = absorb ps0 b0
            absorb qs body = case body of
              CLam rs _ inner | length as >= length qs + length rs -> absorb (qs ++ rs) inner
              _ -> (qs, body)
        (ps', b') <- lamParts <$> freshen (outermostT (substTV s) (CLam ps tUnit b))
        let (now, later) = splitAt (length ps') as
        r <- bindArgs (zip ps' now) b'
        case r of
          Just b'' -> simp (d + 1) b'' >>= \e -> app d e later
          Nothing -> pure (CApp f as)
      _ -> pure (CApp f as)
  _ -> pure (CApp f as)

-- Copies of functions for the functions they are given -----------------------------

-- A recursive function that passes a function parameter as it is to every
-- call to itself, as insertWith passes its f, calls it through a closure on
-- every step: a curried one, which allocates a closure for each argument
-- but the last. Where it is called with a known function (a lambda that
-- uses no local variable, or a top-level function) at concrete types, a
-- copy of it without that parameter is made, with the function put in its
-- place, and its calls to itself call the copy: the function's calls are
-- then copied in like any other. Copies are kept by function and argument,
-- and made only of functions small enough, a few per function.

-- | The position of a function parameter that every call to itself passes
-- as it is, in a function that calls itself only so.
staticParam :: TopBind -> Maybe Int
staticParam tb = case tbBody tb of
  CLam ps _ inner
    | length ps == tbArity tb, tbArity tb > 0, size inner <= 300, not (null calls), saturatedOnly
    , tbName tb `notElem` fused ->
        case [j | (j, (_, t)) <- zip [0 ..] ps, isFun t, all (\args -> passed j (args !! j)) calls] of
          j : _ -> Just j
          [] -> Nothing
    where
      self = tbName tb
      calls = [args | CApp (CVar g _ _) args <- everything inner, g == self, length args == tbArity tb]
      saturatedOnly = length [() | CVar g _ _ <- everything inner, g == self] == length calls
      passed j = \case
        CVar a _ _ -> S.member a (aliasesOf (fst (ps !! j)) inner)
        _ -> False
  _ -> Nothing
  where
    isFun = \case
      TFun _ _ -> True
      _ -> False

-- | The Prelude's list functions that code generation makes loops of where
-- their lists are folded (see Hago.CodeGen's Prod), by their names: a copy
-- would hide them.
fused :: [Name]
fused =
  [ "map", "filter", "take", "takeWhile", "drop", "dropWhile", "repeat", "iterate", "append"
  , "zip", "zipWith", "zip3", "zipWith3", "listFoldr", "listFoldl", "intsTo", "intsFrom" ]

-- | The names a parameter goes by: itself, and the variables patterns bind
-- it to.
aliasesOf :: Name -> CExpr -> S.Set Name
aliasesOf p body = grow (S.singleton p)
  where
    grow as =
      let more = S.fromList [x | CMatch ss rows _ <- everything body, (CVar a _ _, j) <- zip ss [0 :: Int ..], S.member a as
                             , CRow pats _ _ <- rows, j < length pats, CPVar x _ <- [pats !! j]]
       in if more `S.isSubsetOf` as then as else grow (S.union as more)

concrete :: Type -> Bool
concrete = \case
  TVar _ -> False
  TMeta _ -> False
  TCon _ ts -> all concrete ts
  TFun a b -> concrete a && concrete b
  TApp a b -> concrete a && concrete b

-- | A function whose value is known: a lambda that uses no local variable,
-- or a top-level function.
known :: S.Set Name -> CExpr -> Bool
known globals = \case
  e@CLam {} -> freeVars e `S.isSubsetOf` globals && null [() | CVar _ SelfGroup _ <- everything e] && all concrete (everything @Type e)
  CVar g (Inst ts _) _ -> S.member g globals && all concrete ts
  _ -> False

-- | The copy of tb, at types ts, for the function a at position j: its name
-- and type, made if it is not yet.
specialiseOn :: TopBind -> [Type] -> Int -> CExpr -> M (Maybe (Name, Type))
specialiseOn tb ts j a = do
  specs <- gets sSpecs
  let key = (tbName tb, show a ++ show ts)
      sub = M.fromList (zip (tbParams tb) ts)
      t = substTV sub (tbType tb)
      (argTys, res) = splitFun (tbArity tb) t
      t' = foldr TFun res [x | (i, x) <- zip [0 :: Int ..] argTys, i /= j]
      made = length [() | ((f, _), _) <- M.toList specs, f == tbName tb]
  case M.lookup key specs of
    Just name -> pure (Just (name, t'))
    Nothing
      | made >= 4 -> pure Nothing
      | CLam ps r inner <- outermostT (substTV sub) (tbBody tb) -> do
          n <- gets sNext
          let name = tbName tb ++ "__f" ++ show n
              p = fst (ps !! j)
              as = aliasesOf p inner
              -- its calls to itself, which pass the parameter as it is, call
              -- the copy; this before the function is put in, whose own calls
              -- to the original are not these
              selfCalls = everywhere (\case
                CApp (CVar g _ _) args
                  | g == tbName tb, length args == tbArity tb, CVar x _ _ <- args !! j, S.member x as ->
                      CApp (CVar name (Inst [] []) t') [y | (i, y) <- zip [0 :: Int ..] args, i /= j]
                e -> e) inner
              -- the parameter, and the names patterns gave it, become the function
              body1 = substVars (M.fromList [(x, a) | x <- S.toList as]) (dropScrutinee p selfCalls)
          modify (\s -> s {sNext = n + 1, sSpecs = M.insert key name (sSpecs s)})
          body <- simp 0 (CLam [q | (i, q) <- zip [0 :: Int ..] ps, i /= j] r body1)
          let tb' = TopBind name [] [] t' (tbArity tb - 1) body False
          modify (\s -> s {sNew = tb' : sNew s, sGlobals = S.insert name (sGlobals s)})
          pure (Just (name, t'))
      | otherwise -> pure Nothing

-- | The body without the parameter among the scrutinees of its cases: where
-- a case looks at it, each row names it, or ignores it.
dropScrutinee :: Name -> CExpr -> CExpr
dropScrutinee p = everywhere $ \case
  CMatch ss rows t
    | Just j <- lookup p [(a, i) | (CVar a _ _, i) <- zip ss [0 :: Int ..]]
    , all (\(CRow pats _ _) -> j < length pats && plain (pats !! j)) rows ->
        CMatch (dropAt j ss) [CRow (dropAt j pats) bs gs | CRow pats bs gs <- rows] t
  e -> e
  where
    plain = \case
      CPVar _ _ -> True
      CPWild -> True
      _ -> False
    dropAt j xs = [x | (i, x) <- zip [0 :: Int ..] xs, i /= j]

-- | The variables an expression uses that it does not bind.
freeVars :: CExpr -> S.Set Name
freeVars = go S.empty
  where
    go bound = \case
      CVar x _ _ -> if S.member x bound then S.empty else S.singleton x
      CApp f as -> S.unions (go bound f : map (go bound) as)
      CLam ps _ b -> go (S.union bound (S.fromList (map fst ps))) b
      CLet bs b _ ->
        let bound' = S.union bound (S.fromList [n | CBind n _ _ _ <- bs])
         in S.unions (go bound' b : [go bound' x | CBind _ _ _ x <- bs])
      CMatch ss rows _ -> S.unions (map (go bound) ss ++ map (row bound) rows)
      CIf a b c _ -> S.unions (map (go bound) [a, b, c])
      CDelay _ x -> go bound x
      CForce x -> go bound x
      CDo _ _ _ ss -> stmts bound ss
      _ -> S.empty
    row bound (CRow pats bs gs) =
      let bound' = S.unions [bound, S.fromList (concatMap patBinders pats), S.fromList [n | CBind n _ _ _ <- bs]]
       in S.unions ([go bound' x | CBind _ _ _ x <- bs] ++ concat [maybe [] (pure . go bound') g ++ [go bound' e] | (g, e) <- gs]
                     ++ [go bound e | CPEq f v <- concatMap (everything @CPat) pats, e <- [f, v]])
    stmts _ [] = S.empty
    stmts bound (st : rest) = case st of
      CSBind x _ e -> S.union (go bound e) (stmts (S.insert x bound) rest)
      CSExpr _ e -> S.union (go bound e) (stmts bound rest)
      CSLet bs ->
        let bound' = S.union bound (S.fromList [n | CBind n _ _ _ <- bs])
         in S.unions ([go bound' x | CBind _ _ _ x <- bs] ++ [stmts bound' rest])

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
freshen = renameBinders fresh
  where
    fresh :: Name -> M Name
    fresh x = do
      n <- gets sNext
      modify (\s -> s {sNext = n + 1})
      pure (takeWhile (/= '#') x ++ "#" ++ show n)

-- | Every name the expression binds replaced by what fresh makes of it, in
-- its scope: parameters, local bindings, pattern variables, variables of
-- do blocks. Free variables stay.
renameBinders :: forall m. Monad m => (Name -> m Name) -> CExpr -> m CExpr
renameBinders fresh = expr M.empty
  where
    freshAll :: M.Map Name Name -> [Name] -> m (M.Map Name Name)
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
