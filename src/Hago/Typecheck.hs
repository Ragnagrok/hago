{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE LambdaCase #-}

-- | Hindley-Milner type inference with type classes, which also elaborates
-- the program into the typed core. Laziness is type-directed: an expression
-- checked against @Lazy t@ is suspended, and a variable of type @Lazy t@ used
-- where a @t@ is expected is forced. Constraints become dictionaries.
module Hago.Typecheck (Checked (..), typecheckModule, programOf, primSchemes, pretty) where

import Data.Bifunctor (first)
import Data.Data (Data, cast, gmapQ)
import Data.Maybe (catMaybes, listToMaybe)

import Control.Monad
import Control.Monad.State
import Data.Graph (SCC (..), flattenSCC, flattenSCCs, stronglyConnComp)
import qualified Data.IntMap as IM
import Data.List (intercalate, nub, sortOn, (\\))
import qualified Data.List as L
import qualified Data.Map as M
import qualified Data.Set as S
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
       -- runs an action as a pure value: only for Identity, which is
       -- trampolined IO without effects
       , ("primRunIO", Forall ["a"] [] (tIO a ~> a))
       , ("error", Forall ["a"] [] (tString ~> a))
       -- joins two Strings or two lists; anything else fails at run time, so
       -- only the Prelude's instances of Semigroup and deriving use it
       , ("primAppend", Forall ["a"] [] (a ~> tLazy a ~> a))
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
  [ ("Int", 0), ("Integer", 0), ("Double", 0), ("Bool", 0), ("Char", 0), ("String", 0), ("()", 0)
  , ("[]", 1), ("IO", 1), ("Lazy", 1), ("->", 2) ]
    `M.union` M.fromList [(tupleCon n, n) | n <- [2 .. maxTuple]]

builtinCons :: M.Map Name ConInfo
builtinCons = M.fromList
  [ ("[]", ConInfo "[]" ["a"] [] 0)
  , (":", ConInfo "[]" ["a"] [(False, TVar "a"), (True, tList (TVar "a"))] 1)
  , ("()", ConInfo "()" [] [] 0)
  , ("False", ConInfo "Bool" [] [] 0)
  , ("True", ConInfo "Bool" [] [] 1)
  ]
    `M.union` M.fromList [(k, ConInfo k vs [(False, TVar v) | v <- vs] 0) | n <- [2 .. maxTuple], let k = tupleCon n, let vs = ["t" ++ show i | i <- [1 .. n]]]

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
      Nothing -> throw (maybe ("unknown type: " ++ c) tooBig (tupleArity c))
      Just n
        | length ts > n -> throw ("type " ++ c ++ " expects " ++ show n ++ " arguments")
        | otherwise -> norm . TCon c <$> mapM go ts

rigid :: SType -> M.Map Name Type
rigid st = M.fromList [(v, TVar v) | v <- stypeVars st]

-- | The constraints of a context, over the given type variables. Each
-- constrains a type variable, as in Haskell 98; in a class with several
-- parameters, the one that chooses the instance (the others can be any
-- type, as in MonadState Int m).
contextPreds :: Env -> M.Map Name Type -> Context -> TC [Pred]
contextPreds env vars ctx = forM ctx $ \(c, sts) -> case M.lookup c (envClasses env) of
  Nothing -> throw ("unknown class: " ++ c)
  Just ci -> do
    unless (length sts == length (clsVars ci)) (throw (classArity c ci (length sts)))
    ts <- mapM (fromSType env vars) sts
    case ts !! clsKey ci of
      TVar _ -> pure (IsIn c ts)
      t -> throw ("a constraint is on a type variable, and this one is on " ++ prettyAtom t ++ ": " ++ showPred (IsIn c ts))

classArity :: Name -> ClassInfo -> Int -> String
classArity c ci n = "the class " ++ c ++ " takes " ++ show (length (clsVars ci)) ++ " type(s), and is given " ++ show n

-- | The type variables a context mentions.
contextVars :: Context -> [Name]
contextVars ctx = nub (concatMap stypeVars (concatMap snd ctx))

-- Constructors ---------------------------------------------------------------------

lookupCon :: Env -> Name -> TC ConInfo
lookupCon env k = maybe (throw (maybe ("unknown constructor: " ++ k) tooBig (tupleArity k))) pure (M.lookup k (envCons env))

tooBig :: Int -> String
tooBig n = "a tuple has at most " ++ show maxTuple ++ " elements, and this one has " ++ show n ++ ": use a record instead"

-- | Field types (lazy ones wrapped in Lazy) and result type, for given type arguments.
conSig :: ConInfo -> [Type] -> ([Type], Type)
conSig ci targs = (map field (ciFields ci), TCon (ciType ci) targs)
  where
    s = M.fromList (zip (ciParams ci) targs)
    field (lz, t) = (if lz then tLazy else id) (substT s t)

-- Records ---------------------------------------------------------------------------
--
-- Fields are not functions: they live in their type, so two types can have a
-- field of the same name and neither takes a name from the program. Reading
-- a field (p.name) or updating it is only allowed when every constructor of
-- the type has it, so neither can fail at run time; building a record
-- requires every field.

-- | The field names of a constructor, in order; empty if declared without them.
conLabels :: Env -> Name -> ConInfo -> [Name]
conLabels env k ci = case M.lookup (ciType ci) (envRecords env) of
  Nothing -> []
  Just r ->
    let ls = sortOn fst [(i, l) | (l, (_, _, at)) <- M.toList (recFields r), (k', i) <- at, k' == k]
     in if length ls == length (ciFields ci) then map snd ls else []

-- | The record type of an expression of type t that has these fields. The
-- candidates are the record types with those fields visible here; when t is
-- not known yet and only one candidate exists, it is that one.
recordOf :: Env -> [Name] -> [Name] -> Type -> TC (Name, [Type], Record)
recordOf env labels cands t =
  zonkT t >>= \case
    t'@(TCon c args) | Just r <- M.lookup c (envRecords env), length args == length (recParams r) ->
      case filter (`M.notMember` recFields r) labels of
        (l : _) -> throw ("the type " ++ pretty t' ++ " has no field " ++ l)
        []
          | c `elem` cands -> pure (c, args, r)
          | otherwise -> throw ("the fields of " ++ unqual c ++ " are not visible here: its module does not export its constructors")
    t'@(TMeta _) -> guess t'
    t'@(TApp _ _) -> guess t'
    t'@(TFun _ _) -> throw ("the type " ++ pretty t' ++ " has no field " ++ fields
                              ++ " (for composition, write f . g with spaces)")
    t' -> throw ("the type " ++ pretty t' ++ " has no field " ++ fields)
  where
    fields = intercalate ", " labels
    guess t' = case cands of
      [c] -> do
        let r = envRecords env M.! c
        args <- mapM (const fresh) (recParams r)
        unify t' (TCon c args)
        pure (c, args, r)
      [] -> throw ("no record type here has the field" ++ (if length labels > 1 then "s " else " ") ++ fields)
      cs -> throw ("the field " ++ fields ++ " belongs to " ++ intercalate " and " (map unqual cs)
                     ++ "; say which with a type annotation")

-- | A field that every constructor of the record has: its laziness, type
-- for these type arguments, and where it is in each constructor.
totalField :: Name -> [Type] -> Record -> Name -> TC (Bool, Type, [(Name, Int)])
totalField c args r l = do
  let (lz, ft, at) = recFields r M.! l
  case recCons r \\ map fst at of
    [] -> pure (lz, substT (M.fromList (zip (recParams r) args)) ft, at)
    (k : _) -> throw ("not every " ++ unqual c ++ " has the field " ++ l ++ ": " ++ unqual k
                        ++ " does not, so match on the constructor instead")

noRepeats :: String -> [Name] -> TC ()
noRepeats what ls = case [l | (i, l) <- zip [0 :: Int ..] ls, l `elem` take i ls] of
  (l : _) -> throw ("the field " ++ l ++ " is " ++ what ++ " twice")
  [] -> pure ()

-- | An expression whose value is needed now: a suspended one is forced.
inferStrict :: Env -> Expr -> TC (CExpr, Type)
inferStrict env x = do
  (c, t) <- infer env x
  zonkT t >>= \case
    TCon "Lazy" [i] -> pure (CForce c, i)
    t' -> pure (c, t')

inferField :: Env -> Expr -> Name -> [Name] -> TC (CExpr, Type)
inferField env x l cands = do
  (cx, tx) <- inferStrict env x
  (c, args, r) <- recordOf env [l] cands tx
  (lz, t, at) <- totalField c args r l
  v <- uniq "field"
  let stored = if lz then tLazy t else t
  rows <- forM at $ \(k, i) -> do
    ci <- lookupCon env k
    let pats = [if j == i then CPVar v stored else CPWild | j <- [0 .. length (ciFields ci) - 1]]
    pure (CRow [CPCon k args pats] [] [(Nothing, CVar v (Inst [] []) stored)])
  let m = CMatch [cx] rows stored
  pure (if lz then (CForce m, t) else (m, t))

-- | @C { x = e, ... }@ is @C e ...@ with the fields in declaration order.
inferRecordCon :: Env -> Name -> [(Name, Expr)] -> TC (CExpr, Type)
inferRecordCon env k fs = do
  ci <- lookupCon env k
  let labels = conLabels env k ci
  noRepeats "given" (map fst fs)
  case [l | (l, _) <- fs, l `notElem` labels] of
    (l : _) -> throw ("the constructor " ++ unqual k ++ " has no field " ++ l)
    [] -> pure ()
  when (null labels && not (null (ciFields ci))) $
    throw ("the constructor " ++ unqual k ++ " has no field names; give its fields in order")
  case [l | l <- labels, l `notElem` map fst fs] of
    [] -> pure ()
    missing -> throw ("missing field" ++ (if length missing > 1 then "s " else " ") ++ intercalate ", " missing
                        ++ " in " ++ unqual k ++ ": every field must be given")
  infer env (foldl EApp (ECon k) [v | l <- labels, Just v <- [lookup l fs]])

-- | @r { x = v }@: one row per constructor, each rebuilding it with the new
-- values, which are computed once, before.
-- | r { f = v, ... }. As in Haskell 98, a type parameter that appears only in
-- the fields being replaced, in every constructor, can change: updating the
-- item of a Box Int with a string gives a Box String.
inferRecordUpd :: Env -> Expr -> [(Name, Expr)] -> [Name] -> TC (CExpr, Type)
inferRecordUpd env x fs cands = do
  noRepeats "changed" (map fst fs)
  (cx, tx) <- inferStrict env x
  (c, args, r) <- recordOf env (map fst fs) cands tx
  places <- forM fs $ \(l, _) -> (\(_, _, at) -> at) <$> totalField c args r l
  infos <- mapM (\k -> (,) k <$> lookupCon env k) (recCons r)
  let replacedAt = S.fromList (concat places)
      kept = S.fromList
        [ v | (k, ci) <- infos, (i, (_, ft)) <- zip [0 ..] (ciFields ci)
            , not (S.member (k, i) replacedAt), v <- tyVarsOf ft ]
  args' <- forM (zip (recParams r) args) $ \(p, a) -> if S.member p kept then pure a else fresh
  let ty' = TCon c args'
  news <- forM (zip fs places) $ \((l, v), at) -> do
    (lz, t, _) <- totalField c args' r l
    let stored = if lz then tLazy t else t
    cv <- check env v stored
    n <- uniq "new"
    pure (n, stored, cv, at)
  rows <- forM infos $ \(k, ci) -> do
    let (fts, _) = conSig ci args
        (fts', _) = conSig ci args'
        replaced = M.fromList [(i, CVar n (Inst [] []) t) | (n, t, _, at) <- news, (k', i) <- at, k' == k]
    olds <- forM (zip [0 :: Int ..] fts) $ \(i, ft) ->
      if M.member i replaced then pure (CPWild, Nothing) else do
        o <- uniq "old"
        pure (CPVar o ft, Just (CVar o (Inst [] []) ft))
    let argsE = [maybe (replaced M.! i) id old | (i, (_, old)) <- zip [0 ..] olds]
    pure (CRow [CPCon k args (map fst olds)] [] [(Nothing, CApp (CCon k args' (foldr TFun ty' fts')) argsE)])
  pure (CLet [CBind n t 0 cv | (n, t, cv, _) <- news] (CMatch [cx] rows ty') ty', ty')

-- Expressions ---------------------------------------------------------------------

extend :: Env -> [(Name, Type)] -> Env
extend env bs = env
  { envVars = foldr (\(n, t) -> M.insert n (Forall [] [] t, False)) (envVars env) bs
  , envLocal = foldr (S.insert . fst) (envLocal env) bs
  , envMono = map snd bs ++ envMono env
  , envCalls = foldr (M.delete . fst) (envCalls env) bs }

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
    case M.lookup x (envCalls env) of
      -- a local function moved to the top, called with the variables it uses
      Just (lifted, passed) ->
        let ft = foldr (TFun . snd) t passed
            f = CVar lifted (Inst targs ds) ft
         in pure (if null passed then f else CApp f [CVar a (Inst [] []) at | (a, at) <- passed], t)
      Nothing -> pure (CVar x (if self then SelfGroup else Inst targs ds) t, t)

infer :: Env -> Expr -> TC (CExpr, Type)
infer env e = case e of
  ELoc l x -> withLoc l (infer env x)
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
    d <- newHole (IsIn "Num" [t])
    pure (CNum n t d, t)
  ELit (LDouble x) -> do
    t <- fresh
    d <- newHole (IsIn "Fractional" [t])
    pure (CFrac x t d, t)
  ELit l -> pure (CLit l, litType l)
  EApp {} -> inferApp env Nothing e
  EDo ss -> do
    m <- fresh
    d <- newHole (IsIn "Monad" [m])
    (r, cs) <- doStmts env m ss
    pure (CDo m d r cs, tApp m r)
  EAnn x st -> do
    vs <- mapM (\v -> (,) v <$> fresh) (stypeVars st)
    t <- fromSType env (M.fromList vs) st
    c <- check env x t
    pure (c, t)
  EField x l cands -> inferField env x l cands
  ERecCon k fs -> inferRecordCon env k fs
  ERecUpd x fs cands -> inferRecordUpd env x fs cands
  _ -> do
    t <- fresh
    c <- check env e t
    pure (c, t)

-- | An application, and the type expected of it when it is known: the
-- result is unified with it before the lambda arguments are checked, so
-- they see what it fixes.
inferApp :: Env -> Maybe Type -> Expr -> TC (CExpr, Type)
inferApp env expected e = do
  let (f, args) = spine e
  case (unLoc f, args) of
    -- f $ x is f x: a Lazy parameter of f stays lazy
    (EVar "$", g : x : rest) | not (S.member "$" (envLocal env)) -> inferApp env expected (foldl EApp (EApp g x) rest)
    _ -> do
      (cf, tf) <- infer env f
      (slots, tr) <- walk tf args
      when (any isLeftSlot slots) $ do
        forM_ expected $ \ex -> do
          tr' <- zonkT tr
          ex' <- zonkT ex
          unless (lazyMismatch tr' ex' || isLazy tr' || isLazy ex') (unify tr' ex')
        improve env
      cargs <- mapM (either (uncurry (check env)) pure) slots
      pure (CApp cf cargs, tr)
  where
    spine (EApp g a) = let (h, as) = spine g in (h, as ++ [a])
    spine x = (x, [])
    -- A lambda argument is checked after the other arguments, so in
    -- map (.name) people the type of people says which name is meant, and
    -- after the result type, so in get >>= \n -> ... the state's type is
    -- known.
    walk t [] = pure ([], t)
    walk t (a : as) = do
      (p, r) <- splitArrow t
      slot <- if isLam a then pure (Left (a, p)) else Right <$> check env a p
      (rest, tr) <- walk r as
      pure (slot : rest, tr)
    isLeftSlot = either (const True) (const False)
    isLam = \case
      ELoc _ x -> isLam x
      ELam _ _ -> True
      _ -> False

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
    (ELoc l x, _) -> withLoc l (check env x expected)
    (_, TCon "Lazy" [inner]) -> case e of
      EVar x -> do
        (c, t) <- inferVarRaw env x
        zonkT t >>= \case
          t'@(TCon "Lazy" _) -> unify t' ex >> pure c
          t' -> unify t' inner >> pure (CDelay inner c)
      _ -> CDelay inner <$> check env e inner
    (ELam ps body, _) -> checkLam env ps body ex
    (EApp {}, _) -> do
      (c, t) <- inferApp env (Just ex) e
      adapt c t ex
    -- the monad is known before the statements are checked
    (EDo ss, _) | Just m <- monadOf ex -> do
      d <- newHole (IsIn "Monad" [m])
      (r, cs) <- doStmts env m ss
      unify (tApp m r) ex
      pure (CDo m d r cs)
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

-- | The monad of a known type m a.
monadOf :: Type -> Maybe Type
monadOf = \case
  TCon k ts@(_ : _) | k /= "Lazy" -> Just (TCon k (init ts))
  TApp f _ -> Just f
  TFun a _ -> Just (TCon "->" [a])
  _ -> Nothing

-- | Unifies the inferred type with the expected one. When both are function
-- types that differ only in which parameters are Lazy, wraps the function
-- instead, forcing or suspending those arguments: this is what lets a strict
-- function such as @insert@ be passed to @foldr@. A parameter whose type is
-- still unknown, on either side, is taken strict, so a type variable never
-- stands for @Lazy t@ just because a function was passed: in @liftA2 (:)@ the
-- list is a plain list, and in @foldr (+) 0@ the sum is a number.
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
    go i a0 x0 = do
      a <- zonkT a0
      x <- zonkT x0
      case (a, x) of
        (TFun aq ar, TFun xp xr) -> do
          let n = "_adapt" ++ show i
              var = CVar n (Inst [] []) xp
          arg <- case (aq, xp) of
            (TCon "Lazy" _, TCon "Lazy" _) -> unify aq xp >> pure var
            (_, TCon "Lazy" [inner]) -> unify aq inner >> pure (CForce var)
            (TCon "Lazy" [inner], _) -> unify inner xp >> pure (CDelay xp var)
            _ -> unify aq xp >> pure var
          ar' <- zonkT ar
          xr' <- zonkT xr
          if resultMismatch ar' xr'
            then do
              (ps, as, r) <- go (i + 1) ar' xr'
              pure ((n, xp) : ps, arg : as, r)
            else unify ar' xr' >> pure ([(n, xp)], [arg], xr')
        (TFun _ _, TMeta _) -> do
          p <- fresh
          r <- fresh
          unify x (TFun p r)
          go i a (TFun p r)
        (TMeta _, TFun _ _) -> do
          p <- fresh
          r <- fresh
          unify a (TFun p r)
          go i (TFun p r) x
        _ -> error "adapt: not a function"

-- | Whether a function must be wrapped to be used at the expected type.
lazyMismatch :: Type -> Type -> Bool
lazyMismatch (TFun a r1) (TFun x r2) = isLazy a /= isLazy x || resultMismatch r1 r2
lazyMismatch _ _ = False

-- | The same, for what is left after some parameters, where an unknown type
-- will be a function with strict parameters.
resultMismatch :: Type -> Type -> Bool
resultMismatch f@(TFun _ _) (TMeta _) = lazyParams f
resultMismatch (TMeta _) f@(TFun _ _) = lazyParams f
resultMismatch a x = lazyMismatch a x

lazyParams :: Type -> Bool
lazyParams (TFun p r) = isLazy p || lazyParams r
lazyParams _ = False

isLazy :: Type -> Bool
isLazy (TCon "Lazy" _) = True
isLazy _ = False

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
      case unLocP p of
        PVar x -> pure ((x, pt) : params, toMatch, (x, pt) : bs, r)
        _ -> do
          let n = "_lam" ++ show i
          (cp, pbs) <- checkPat env p pt
          pure ((n, pt) : params, (n, pt, cp) : toMatch, pbs ++ bs, r)

checkPat :: Env -> Pat -> Type -> TC (CPat, [(Name, Type)])
checkPat env p t = do
  t' <- zonkT t
  case (p, t') of
    (PLoc l q, _) -> withLoc l (checkPat env q t')
    (PVar x, _) -> pure (CPVar x t', [(x, t')])
    (PWild, _) -> pure (CPWild, [])
    (_, TCon "Lazy" [i]) -> do
      (cp, bs) <- checkPat env p i
      pure (CPForce cp, bs)
    (PAs x q, _) -> do
      (cq, bs) <- checkPat env q t'
      pure (CPAs x t' cq, (x, t') : bs)
    (PLit (LInt n), _) -> do
      dEq <- newHole (IsIn "Eq" [t'])
      dNum <- newHole (IsIn "Num" [t'])
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
    -- C { x = p }: the other fields are not looked at; C {} is any C
    (PRec k fps, _) -> do
      ci <- lookupCon env k
      let labels = conLabels env k ci
      noRepeats "matched" (map fst fps)
      case [l | (l, _) <- fps, l `notElem` labels] of
        (l : _) -> throw ("the constructor " ++ unqual k ++ " has no field " ++ l)
        [] -> pure ()
      let ps = if null fps then map (const PWild) (ciFields ci) else [maybe PWild id (lookup l fps) | l <- labels]
      checkPat env (PCon k ps) t'

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
  SBindPat _ _ : _ -> throw "internal: pattern bind not desugared"
  SExpr e : rest -> do
    a <- fresh
    c <- check env e (tApp m a)
    (r, cs) <- doStmts env m rest
    pure (r, CSExpr a c : cs)
  SBind x e : rest -> do
    a <- fresh
    c <- check env e (tApp m a)
    improve env
    let env' = if x == "_" then env else extend env [(x, a)]
    (r, cs) <- doStmts env' m rest
    pure (r, CSBind x a c : cs)
  SLet ds : rest -> do
    (env', bs) <- localBinds env ds
    (r, cs) <- doStmts env' m rest
    pure (r, CSLet bs : cs)

-- | let and where, a group of mutually recursive definitions at a time.
--
-- A group of functions whose types have variables nothing else fixes is
-- generalised and moved to the top (Go function literals cannot be
-- generic): the local variables it uses become its first parameters, and
-- each use passes them. Constraints on its own type variables become its
-- constraints. It stays local and monomorphic when it is a value, when it
-- has constraints on the types of the function around it (their
-- dictionaries belong to that function), or when it binds its own name
-- again inside.
localBinds :: Env -> [Decl] -> TC (Env, [CBind])
localBinds env0 ds = do
  let sigs = M.fromList [(n, t) | DSig ns _ t <- ds, n <- ns]
      binds = [(n, cs) | DBind n cs <- ds]
      names = map fst binds
      sccs = stronglyConnComp [(b, n, filter (`elem` names) (clausesRefs cs)) | b@(n, cs) <- binds]
  foldM (group sigs) (env0, []) sccs
  where
    group sigs (env, acc) scc = do
      let members = flattenSCC scc
          ns = map fst members
      tys <- forM members $ \(n, _) -> case M.lookup n sigs of
        -- local signatures are checked monomorphically: their variables are
        -- unification variables, not rigid ones
        Just st -> do
          vs <- mapM (\v -> (,) v <$> fresh) (stypeVars st)
          fromSType env (M.fromList vs) st
        Nothing -> fresh
      let envG = extend env (zip ns tys)
      before <- gets (S.fromList . map (\(h, _, _) -> h) . stWanted)
      results <- forM (zip members tys) $ \((n, cs), t) -> withCtx n (tcClauses envG cs t)
      (wantedNew, wantedOld) <- gets (L.partition (\(h, _, _) -> not (S.member h before)) . stWanted)
      let wanted = [p | (_, p, _) <- wantedNew]
      zts <- mapM zonkT tys
      envTs <- mapM zonkT (envMono env)
      newPreds <- mapM (\(IsIn c ts) -> IsIn c <$> mapM zonkT ts) wanted
      let bodies = map snd results
          envMetas = S.fromList (concatMap metas envTs)
          gen = nub [m | t <- zts, m <- metas t, not (S.member m envMetas)]
          ownOnly (IsIn _ ts) = all (\t -> all (`elem` gen) (metas t) && null (tyVarsOf t)) ts
          liftable = not (null gen) && all ((> 0) . fst) results && all ownOnly newPreds
            && not (any (`elem` ns) (coreBinders bodies))
          local = (envG, acc ++ [CBind n t ar body | ((n, t), (ar, body)) <- zip (zip ns tys) results])
      if not liftable then pure local else do
        -- the local variables the group uses, in a fixed order
        let used = nub [x | CVar x _ _ <- everything bodies, S.member x (envLocal env), x `notElem` ns]
        passed <- forM used $ \x -> case M.lookup x (envVars env) of
          Just (Forall [] [] t, _) -> (,) x <$> zonkT t
          _ -> throw ("internal: " ++ x ++ " is not a local variable")
        vs0 <- mapM (const (uniq "l")) gen
        -- the group's own constraints, solved apart from those of the
        -- function around it
        modify (\st -> st {stWanted = wantedNew})
        (preds, extra) <- withCtx (unwords ns) (solveGen env (M.fromList (zip gen vs0)))
        modify (\st -> st {stWanted = wantedOld ++ stWanted st})
        let vs = vs0 ++ map snd extra
        zipWithM_ (\m v -> bindMeta m (TVar v)) (gen ++ map fst extra) vs
        let dicts = map (DParam . dictName) preds
        zts' <- mapM zonkT tys
        modName' <- gets stModule
        let inModule n = if modName' == "Prelude" then n else modName' ++ "." ++ n
        lifted <- mapM (\n -> ((inModule n ++ "'") ++) . drop 1 <$> uniq "") ns
        -- inside, the group calls itself with its own type variables and the
        -- variables as they are, now parameters
        let selfCall n t = case lookup n (zip ns (zip lifted zts')) of
              Just (ln, _) ->
                let f = CVar ln (Inst (map TVar vs) dicts) (foldr (TFun . snd) t passed)
                 in if null passed then f else CApp f [CVar x (Inst [] []) xt | (x, xt) <- passed]
              Nothing -> CVar n (Inst [] []) t
            rewrite = everywhere $ \case
              CVar n (Inst [] []) t | n `elem` ns -> selfCall n t
              e -> e
        forM_ (zip3 lifted zts' results) $ \(ln, t, (ar, body)) -> do
          let ft = foldr (TFun . snd) t passed
              body' = case rewrite body of
                CLam ps r inner -> CLam (passed ++ ps) r inner
                other -> other
          modify (\st -> st {stLifted = (TopBind ln vs [(dictName p, p) | p <- preds] ft (length passed + ar) body' False, vs) : stLifted st})
        -- outside, the variables are passed through names nothing can shadow
        aliases <- forM passed $ \(x, xt) -> do
          a <- uniq "cap"
          pure ((a, xt), CBind a xt 0 (CVar x (Inst [] []) xt))
        let withAliases = extend env (map fst aliases)
            env' = withAliases
              { envVars = foldr (\(n, t) -> M.insert n (Forall vs preds t, False)) (envVars withAliases) (zip ns zts')
              , envCalls = foldr (\(n, ln) -> M.insert n (ln, map fst aliases)) (envCalls env) (zip ns lifted)
              , envMono = zts' ++ map (snd . fst) aliases ++ envMono env }
        pure (env', acc ++ map snd aliases)

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

-- | Errors without a location of their own are reported against the file.
-- | What checking a module gives the modules after it, and the program:
-- every type in it is resolved and every dictionary filled in, so it can be
-- kept and reused while the module does not change.
data Checked = Checked
  { ckVars :: M.Map Name Scheme           -- ^ top-level values, methods and foreign imports
  , ckCons :: M.Map Name ConInfo
  , ckTypes :: M.Map Name Int
  , ckClasses :: M.Map Name ClassInfo
  , ckInsts :: M.Map (Name, Name) InstHead
  , ckRecords :: M.Map Name Record
  , ckData :: M.Map Name DataInfo
  , ckForeign :: M.Map Name Foreign
  , ckInstInfos :: [InstInfo]
  , ckBinds :: [TopBind]
  }
  deriving (Show, Data)

instance Semigroup Checked where
  a <> b = Checked
    { ckVars = M.union (ckVars a) (ckVars b)
    , ckCons = M.union (ckCons a) (ckCons b)
    , ckTypes = M.union (ckTypes a) (ckTypes b)
    , ckClasses = M.union (ckClasses a) (ckClasses b)
    , ckInsts = M.union (ckInsts a) (ckInsts b)
    , ckRecords = M.union (ckRecords a) (ckRecords b)
    , ckData = M.union (ckData a) (ckData b)
    , ckForeign = M.union (ckForeign a) (ckForeign b)
    , ckInstInfos = ckInstInfos a ++ ckInstInfos b
    , ckBinds = ckBinds a ++ ckBinds b
    }

instance Monoid Checked where
  mempty = Checked M.empty M.empty M.empty M.empty M.empty M.empty M.empty M.empty [] []

-- | Checks one module against what the modules before it give (its imports
-- among them). Errors without a location of their own are reported against
-- the module's file.
typecheckModule :: FilePath -> Name -> Checked -> [Decl] -> Either String Checked
typecheckModule file m before ds =
  first (formatErr file) (evalStateT (tcModule (file == "<interactive>") m before ds) (St 0 IM.empty [] IM.empty Nothing [] m))

-- | The whole program, from what every module gives.
programOf :: Checked -> Program
programOf ck = Program
  { progData = M.union builtinData (ckData ck)
  , progCons = M.union builtinCons (ckCons ck)
  , progForeign = ckForeign ck
  , progClasses = ckClasses ck
  , progInsts = ckInstInfos ck
  , progBinds = ckBinds ck
  , progSubst = IM.empty
  , progSolved = IM.empty
  }

builtinData :: M.Map Name DataInfo
builtinData = M.fromList [("[]", DataInfo ["a"] [0] ["[]", ":"] False), ("Bool", DataInfo [] [] ["False", "True"] False)]

-- | Resolves every unification variable and fills in every dictionary.
closeUp :: Subst -> IM.IntMap Dict -> Checked -> Checked
closeUp sub solved = everywhere (zonk sub) . everywhere fill
  where
    fill = \case
      DHole h | Just d <- IM.lookup h solved -> fillAll d
      d -> d
    fillAll = \case
      DHole h | Just d <- IM.lookup h solved -> fillAll d
      DInst i ts ds -> DInst i ts (map fillAll ds)
      DSuper d s -> DSuper (fillAll d) s
      d -> d

tyconId :: Name -> String
tyconId = \case
  "[]" -> "List"
  "()" -> "Unit"
  "->" -> "Fn"
  k | Just n <- tupleArity k -> "Tup" ++ show n
  k -> k

-- | At hago repl's prompt (the first argument) the expression typed, it, is
-- generalised even when it is a plain value, so that :type shows its
-- constraints; printing it defaults them.
tcModule :: Bool -> Name -> Checked -> [Decl] -> TC Checked
tcModule interactive modName' before ds = do
  let datas = [d | DData d <- ds]
      ownTypes = M.fromList [(ddName d, length (ddParams d)) | d <- datas]
      types = M.unions [builtinTypes, ckTypes before, ownTypes]
      envD = Env M.empty (M.union builtinCons (ckCons before)) types M.empty M.empty [] (ckRecords before) S.empty [] M.empty
  -- data types
  checked <- forM datas $ \d -> atLoc (Just (ddLoc d)) $ withCtx (ddName d) $ do
    let n = ddName d
        ps = ddParams d
    when (ddNewtype d) $ case ddCons d of
      [ConDecl _ [(False, _)] _] -> pure ()
      [ConDecl _ [(True, _)] _] -> throw "the field of a newtype cannot be lazy"
      _ -> throw "a newtype has one constructor with one field"
    cs <- forM (zip [0 ..] (ddCons d)) $ \(i, ConDecl k fields labels) -> do
      noRepeats ("declared in " ++ unqual k) labels
      fts <- mapM (\(lz, st) -> (,) lz <$> fromSType envD (M.fromList [(p, TVar p) | p <- ps]) st) fields
      pure (k, ConInfo n ps fts i, labels)
    -- a field in several constructors must be the same in all of them
    let uses = M.fromListWith (flip (++)) [(l, [(k, j, f)]) | (k, ci, ls) <- cs, (j, l, f) <- zip3 [0 ..] ls (ciFields ci)]
    fields <- forM (M.toList uses) $ \(l, us) -> case nub [f | (_, _, f) <- us] of
      [(lz, t)] -> pure (l, (lz, t, [(k, j) | (k, j, _) <- us]))
      _ -> throw ("the field " ++ l ++ " has different types in different constructors")
    let record = [(n, Record ps [k | (k, _, _) <- cs] (M.fromList fields)) | not (null fields)]
    pure ([(k, ci) | (k, ci, _) <- cs], record)
  let userCons = concatMap fst checked
      ownRecords = M.fromList (concatMap snd checked)
      cons = M.unions [builtinCons, ckCons before, M.fromList userCons]
      dataInfos = M.fromList
          [ (ddName d, DataInfo (ddParams d) [M.findWithDefault 0 p ar | p <- ddParams d] [k | ConDecl k _ _ <- ddCons d] (ddNewtype d))
             | d <- datas
             , let ar = M.unionsWith max [stypeArities st | ConDecl _ fs _ <- ddCons d, (_, st) <- fs] ]
      envC = envD {envCons = cons, envRecords = M.union (ckRecords before) ownRecords}
  -- classes
  let classDecls = [(sup, c, vs, deps, body) | DClass sup c vs deps body <- ds]
      kindOf body v = maximum (0 : [M.findWithDefault 0 v (stypeArities st) | DSig _ _ st <- body])
  keys <- fmap M.fromList . forM classDecls $ \(_, c, vs, deps, _) -> withCtx c $ do
    forM_ (take 1 (vs \\ nub vs)) $ \v -> throw ("the class parameter " ++ v ++ " appears twice")
    k <- case (vs, deps) of
      ([_], []) -> pure 0
      (_, [([d], rest)]) | d `elem` vs, L.sort (d : rest) == L.sort vs -> pure (length (takeWhile (/= d) vs))
      _ -> throw "a class with several parameters needs one functional dependency, from one of them to all the others, as in | m -> s"
    pure (c, k)
  let envK = envC {envClasses = M.union (ckClasses before) (M.fromList [(c, ClassInfo vs (map (kindOf body) vs) (keys M.! c) [] [] []) | (_, c, vs, _, body) <- classDecls])}
  classes <- fmap M.fromList . forM classDecls $ \(sup, c, vs, _, body) -> withCtx c $ do
    let kinds = map (kindOf body) vs
        key = keys M.! c
        vmap = M.fromList [(v, TVar v) | v <- vs]
    supers <- contextPreds envK vmap sup
    forM_ supers $ \(IsIn s sts) ->
      forM_ (zip sts (clsKinds (envClasses envK M.! s))) $ \case
        (TVar v, k) | lookup v (zip vs kinds) == Just k -> pure ()
        (TVar _, _) -> throw ("superclass " ++ s ++ " is over a different kind")
        _ -> throw "a superclass must constrain the class variables"
    let supNames = [s | IsIn s _ <- supers]
    forM_ (take 1 (supNames \\ nub supNames)) $ \n -> throw ("the superclass " ++ n ++ " appears twice")
    methods <- fmap concat . forM [(ns, ctx, st) | DSig ns ctx st <- body] $ \(ns, ctx, st) -> do
      let own = filter (`notElem` vs) (stypeVars st)
      -- a dictionary of a class over plain types is a Go struct at run time,
      -- and struct fields cannot be generic
      when (kinds !! key == 0 && (not (null own) || not (null ctx))) $
        throw "methods of a class over plain types may only mention the class variable"
      t <- fromSType envK (rigid st) st
      mpreds <- contextPreds envK (rigid st) ctx
      when (any (\(IsIn _ pts) -> any (`elem` map TVar vs) pts) mpreds) (throw "a method cannot constrain the class variable again")
      pure [(n, Forall (vs ++ own) (IsIn c (map TVar vs) : mpreds) t) | n <- ns]
    let defaults = [n | DBind n _ <- body]
    forM_ defaults $ \n -> unless (n `elem` map fst methods) (throw (n ++ " is not a method of " ++ c))
    pure (c, ClassInfo vs kinds key supers methods defaults)
  let envCl = envK {envClasses = M.union (ckClasses before) classes}
  -- instance heads
  instDecls <- forM [(l, ctx, c, sts, body) | DInstance l ctx c sts body <- ds] $ \(l, ctx, c, sts, body) -> atLoc l $ withCtx ("instance " ++ unqual c) $ do
    ci <- maybe (throw ("unknown class: " ++ c)) pure (M.lookup c (envClasses envCl))
    unless (length sts == length (clsVars ci)) (throw (classArity c ci (length sts)))
    let vars = M.fromList [(v, TVar v) | st <- sts, v <- stypeVars st]
    ts <- mapM (fromSType envCl vars) sts
    let keyT = ts !! clsKey ci
    (k, vs) <- case keyT of
      TCon k args | all isTVar args, length (nub args) == length args -> pure (k, [v | TVar v <- args])
      TFun (TVar a) (TVar b) | a /= b -> pure ("->", [a, b])
      _ -> throw "an instance type must be a type constructor applied to distinct variables"
    let kind = clsKinds ci !! clsKey ci
        arity = M.findWithDefault 0 k (envTypes envCl)
    unless (length vs + kind == arity) $
      throw ("the instance type must take " ++ show kind ++ " more argument(s) to match the class")
    preds <- contextPreds envCl vars ctx
    -- the other types may only use what the chosen type, or the context, fixes
    let rest = nub (concat [tyVarsOf t | (i, t) <- zip [0 ..] ts, i /= clsKey ci]) \\ vs
    forM_ rest $ \v -> unless (any (\(IsIn _ pts) -> v `elem` concatMap tyVarsOf pts) preds) $
      throw ("the type variable " ++ v ++ " is not fixed by " ++ prettyAtom keyT ++ ", which chooses the instance")
    pure ((c, k), InstHead ("inst_" ++ c ++ "_" ++ tyconId k) (vs ++ rest) preds ts, ts, (l, body))
  case [key | (key, n) <- M.toList (M.fromListWith (+) ([(key, 1 :: Int) | (key, _, _, _) <- instDecls] ++ [(key, 1) | key <- M.keys (ckInsts before)])), n > 1] of
    ((c, k) : _) -> throw ("duplicate instance " ++ c ++ " " ++ k)
    [] -> pure ()
  let ownInsts = M.fromList [(key, ih) | (key, ih, _, _) <- instDecls]
      env0 = envCl {envInsts = M.union (ckInsts before) ownInsts}
  -- foreign imports, signatures and bindings
  foreigns <- forM [(s, n, st) | DForeign s n st <- ds] $ \(s, n, st) -> withCtx n $ do
    t <- fromSType env0 (rigid st) st
    pure (n, (Forall (stypeVars st) [] t, Foreign s t (arrows t)))
  let sigs = M.fromList [(n, (ctx, st)) | DSig ns ctx st <- ds, n <- ns]
      binds = [(n, cs) | DBind n cs <- ds]
      names = map fst binds
      methodSchemes = [(m, sc) | ci <- M.elems classes, (m, sc) <- clsMethods ci]
      beforeVars = [(n, (sc, False)) | (n, sc) <- M.toList (ckVars before)]
  case [n | (n, k) <- M.toList (M.fromListWith (+) [(n, 1 :: Int) | n <- names ++ map fst methodSchemes]), k > 1] of
    (n : _) -> throw ("in " ++ n ++ ": defined more than once")
    [] -> pure ()
  sigSchemes <- forM (M.toList sigs) $ \(n, (ctx, st)) -> withCtx n $ do
    -- a variable only in the context is fixed by a dependency, as s in
    -- MonadState s m => m ()
    let vs = nub (stypeVars st ++ contextVars ctx)
        vars = M.fromList [(v, TVar v) | v <- vs]
    t <- fromSType env0 vars st
    preds <- contextPreds env0 vars ctx
    pure (n, Forall vs preds t)
  let env1 = env0
        { envVars = M.fromList ([(n, (sc, False)) | (n, sc) <- M.toList primSchemes]
            ++ beforeVars
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
  defaultBinds <- fmap concat . forM classDecls $ \(_, c, _, _, body) -> do
    let ci = classes M.! c
    forM [(m, cs) | DBind m cs <- body] $ \(m, cs) -> withCtx (c ++ "." ++ m) $ do
      let Forall vs preds t = M.fromList (clsMethods ci) M.! m
          envG = withGivens env2 preds
      body' <- tcClauses envG cs t >>= etaTo t
      _ <- solve envG M.empty
      pure ((topBind (defaultName c m) vs preds t (arrows t) body') {tbShared = False})
  -- instance bodies
  insts <- forM instDecls $ \((c, _), ih, heads, (l, body)) -> atLoc l $ withCtx ("instance " ++ showPred (IsIn c heads)) $ do
    let ci = envClasses envCl M.! c
        headMap = M.fromList (zip (clsVars ci) heads)
        defined = M.fromListWith (flip (++)) [(m, cs) | DBind m cs <- body]
        self = DInst (ihId ih) (map TVar (ihVars ih)) (map (DParam . dictName) (ihCtx ih))
    forM_ (M.keys defined) $ \m -> unless (m `elem` map fst (clsMethods ci)) (throw (m ++ " is not a method of " ++ c))
    methods <- forM (clsMethods ci) $ \(m, Forall mvs mps mt) -> withCtx m $ do
      let own = drop (length (clsVars ci)) mvs
          mpreds = drop 1 mps
          t = norm (substT headMap mt)
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
                  dm = CVar (defaultName c m) (Inst (heads ++ map TVar own) (self : map (DParam . dictName) mpreds)) t
              pure (m, Just (if n == 0 then dm else CLam (zip argNames ps) r (CApp dm [CVar a (Inst [] []) p | (a, p) <- zip argNames ps])))
          | otherwise -> pure (m, Nothing)
    supers <- forM (clsSupers ci) $ \(IsIn s sts) -> do
      let envG = withGivens env2 (ihCtx ih)
      d <- newHole (IsIn s (map (substT headMap) sts))
      _ <- solve envG M.empty
      pure (s, d)
    pure (InstInfo (ihId ih) c (ihVars ih) (ihCtx ih) heads methods supers)
  -- main must be an IO action
  let mainLoc = case [l | DBind "main" (Clause _ (Rhs ((_, ELoc l _) : _) _) : _) <- ds] of
        (l : _) -> Just l
        [] -> Nothing
  when (modName' == "Main") $ case M.lookup "main" (envVars env2) of
    Nothing -> throw "no main defined"
    Just (sc, _) -> atLoc mainLoc $ withCtx "main" $ do
      (t, _, _) <- instantiate sc
      unify t (tIO tUnit)
      modify (\s -> s {stWanted = []})
  let allBinds = groupBinds ++ signedBinds ++ defaultBinds
      byName = M.fromList [(tbName b, b) | b <- allBinds]
      order = flattenSCCs (stronglyConnComp
        [(n, n, filter (`M.member` byName) (clausesRefs cs)) | (n, cs) <- binds])
      defaults = [tbName b | b <- defaultBinds]
  st <- get
  -- Values are computed in order when the program starts, so values whose
  -- computations need each other cannot be. A function-typed value is
  -- exempt: it starts as a function that computes it on its first call.
  let sub = stSub st
      allData = M.unions [dataInfos, ckData before, builtinData]
      funLike :: Int -> Type -> Bool
      funLike depth t = depth < 20 && case zonk sub t of
        TFun _ _ -> True
        TCon "IO" _ -> True
        TCon c ts
          | Just di <- M.lookup c allData, diNewtype di, [k] <- diCons di
          , Just ci <- M.lookup k cons, [(_, ft)] <- ciFields ci ->
              funLike (depth + 1) (substT (M.fromList (zip (ciParams ci) ts)) ft)
        _ -> False
      isValue b = tbArity b == 0 && null (tbDicts b)
      edges b
        | isValue b && funLike 0 (tbType b) = []
        | isValue b = strictRefs (tbBody b)
        | otherwise = coreRefs (tbBody b)
      cycles = [ns | CyclicSCC ns <- stronglyConnComp
                 [(n, n, filter (`M.member` byName) (edges b)) | (n, b) <- M.toList byName]]
      sourceOrder = map fst binds
  forM_ cycles $ \ns -> do
    let vals = [n | n <- sourceOrder, n `elem` ns, isValue (byName M.! n)]
        bindLoc n = listToMaybe [l | (m, cs) <- binds, m == n, Just l <- [firstLoc cs]]
    case vals of
      v : _ -> atLoc (bindLoc v) $ throw $
        (case vals of
          [_] -> unqual v ++ " is defined in terms of itself, so computing it never ends"
          _ -> intercalate ", " (map unqual (init vals)) ++ " and " ++ unqual (last vals)
                 ++ " are defined in terms of each other, so computing them never ends")
          ++ "; a value can only refer to itself under a lambda, in a lazy field or argument, \
             \or if it is a function"
      [] -> pure ()
  let prog = withLifted (stSub st) (reverse (stLifted st)) Program
        { progData = dataInfos
        , progCons = M.fromList userCons
        , progForeign = M.fromList [(n, f) | (n, (_, f)) <- foreigns]
        , progClasses = classes
        , progInsts = insts
        , progBinds = map (byName M.!) (order ++ defaults)
        , progSubst = stSub st
        , progSolved = stSolved st
        }
      own n = not (M.member n (ckVars before) || M.member n primSchemes)
  pure $ closeUp (stSub st) (stSolved st) Checked
    { ckVars = M.map fst (M.filterWithKey (\n _ -> own n) (envVars env2))
    , ckCons = progCons prog
    , ckTypes = ownTypes
    , ckClasses = classes
    , ckInsts = ownInsts
    , ckRecords = ownRecords
    , ckData = progData prog
    , ckForeign = progForeign prog
    , ckInstInfos = progInsts prog
    , ckBinds = progBinds prog
    }
  where
    isTVar (TVar _) = True
    isTVar _ = False
    tcGroup (env, acc) (gi, scc) = do
      let members = flattenSCC scc
      tys <- mapM (const fresh) members
      let envG = env {envVars = foldr (\((n, _), t) -> M.insert n (Forall [] [] t, True)) (envVars env) (zip members tys), envMono = tys ++ envMono env}
      results <- forM (zip members tys) $ \((n, cs), t) -> withCtx n (tcClauses envG cs t)
      -- the monomorphism restriction: a group of plain values is not
      -- generalised over its constraints, which are defaulted instead
      let restricted = all ((== 0) . fst) results && not (interactive && map (unqual . fst) members == ["it"])
      when restricted (void (solve env M.empty))
      zts <- mapM zonkT tys
      let ms = nub (concatMap metas zts)
          vs = ["t" ++ show gi ++ "_" ++ show i | i <- [1 .. length ms]]
          gen = M.fromList (zip ms vs)
      (preds, extra) <- if restricted then pure ([], []) else withCtx (unwords (map fst members)) (solveGen env gen)
      let vs' = vs ++ map snd extra
      zipWithM_ (\m v -> bindMeta m (TVar v)) (ms ++ map fst extra) vs'
      zts' <- mapM zonkT tys
      let env' = env {envVars = foldr (\((n, _), t) -> M.insert n (Forall vs' preds t, False)) (envVars env) (zip members zts')}
      pure (env', acc ++ [topBind n vs' preds t ar body | (((n, _), t), (ar, body)) <- zip (zip members zts') results])

-- | Adds the local functions moved to the top. Each also takes the type
-- variables of the functions around it that it mentions, or that the lifted
-- functions it calls need; every call passes them as they are.
withLifted :: Subst -> [(TopBind, [Name])] -> Program -> Program
withLifted sub lifted prog = everywhere passExtras prog {progBinds = progBinds prog ++ map complete lifted}
  where
    own = M.fromList [(tbName b, vs) | (b, vs) <- lifted]
    direct = M.fromList
      [ (tbName b, nub (tyVarsOf (zonk sub (tbType b)) ++ concatMap (tyVarsOf . zonk sub) (everything (tbBody b) :: [Type])))
      | (b, _) <- lifted ]
    calls = M.fromList [(tbName b, nub [x | CVar x _ _ <- everything (tbBody b), M.member x own]) | (b, _) <- lifted]
    extras = fixpoint (M.map (const []) own)
    fixpoint cur =
      let next' = M.mapWithKey (\n _ -> nub (direct M.! n ++ concat [cur M.! g | g <- calls M.! n]) \\ (own M.! n)) cur
       in if next' == cur then cur else fixpoint next'
    complete (b, vs) = b {tbParams = vs ++ extras M.! tbName b}
    passExtras = \case
      CVar x (Inst ts ds) t | Just ex <- M.lookup x extras -> CVar x (Inst (ts ++ map TVar ex) ds) t
      e -> e

topBind :: Name -> [Name] -> [Pred] -> Type -> Int -> CExpr -> TopBind
topBind n vs preds t ar body =
  TopBind n vs [(dictName p, p) | p <- preds] t ar body (ar == 0 && null vs && null preds)

defaultName :: Name -> Name -> Name
defaultName c m = "_dm_" ++ c ++ "_" ++ m

-- | The first source location inside.
firstLoc :: Data a => a -> Maybe Loc
firstLoc x = case cast x of
  Just (ELoc l _) -> Just l
  _ -> listToMaybe (catMaybes (gmapQ firstLoc x))

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
  EOpSeq e0 rest -> exprRefs e0 ++ concat [op : exprRefs x | ((op, _), x) <- rest]
  EAnn x _ -> exprRefs x
  EField x _ _ -> exprRefs x
  ERecCon _ fs -> concatMap (exprRefs . snd) fs
  ERecUpd x fs _ -> exprRefs x ++ concatMap (exprRefs . snd) fs
  ELoc _ x -> exprRefs x
  _ -> []
  where
    stmtRefs (SBind _ e) = exprRefs e
    stmtRefs (SBindPat _ e) = exprRefs e
    stmtRefs (SLet ds) = declsRefs ds
    stmtRefs (SExpr e) = exprRefs e
