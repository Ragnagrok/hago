{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- | Typed core: the output of the type checker and the input of code
-- generation. Every node that Go needs a type for carries one; types may
-- still mention unification variables, which code generation resolves with
-- the final substitution. Class constraints are explicit dictionaries.
module Hago.Core where

import Data.Char (isAlphaNum)
import Data.Data (Data, gmapQ, gmapT)
import Data.Type.Equality ((:~:) (..))
import Data.Typeable (Typeable, eqT)
import qualified Data.IntMap as IM
import qualified Data.Map as M
import Hago.Syntax (Lit (..), Name, tupleArity)

data Type
  = TVar Name          -- ^ rigid (quantified) type variable
  | TMeta Int          -- ^ unification variable
  | TCon Name [Type]   -- ^ Int, Double, Bool, Char, String, (), [], (,), IO, Lazy, user types;
                       --   with fewer arguments than its arity it is partially applied (Either e)
  | TFun Type Type
  | TApp Type Type     -- ^ application whose head is not known yet, as in @f a@
  deriving (Eq, Show, Data)

-- | Puts a type in normal form: an application to a known constructor joins
-- its arguments, and a fully applied (->) is a function type.
tApp :: Type -> Type -> Type
tApp (TCon "->" [a]) b = TFun a b
tApp (TCon c ts) x = TCon c (ts ++ [x])
tApp f x = TApp f x

norm :: Type -> Type
norm = \case
  TCon "->" [a, b] -> TFun (norm a) (norm b)
  TCon c ts -> TCon c (map norm ts)
  TFun a b -> TFun (norm a) (norm b)
  TApp f x -> tApp (norm f) (norm x)
  t -> t

-- | A class constraint: the class and the types it applies to, one per
-- class parameter.
data Pred = IsIn Name [Type]
  deriving (Eq, Show, Data)

data Scheme = Forall [Name] [Pred] Type
  deriving (Show, Data)

type Subst = IM.IntMap Type

tInt, tDouble, tBool, tChar, tString, tUnit :: Type
tInt = TCon "Int" []
tDouble = TCon "Double" []
tBool = TCon "Bool" []
tChar = TCon "Char" []
tString = TCon "String" []
tUnit = TCon "()" []

tList, tIO, tLazy :: Type -> Type
tList t = TCon "[]" [t]
tIO t = TCon "IO" [t]
tLazy t = TCon "Lazy" [t]

-- | Applies a substitution all the way down, normalising as it goes.
zonk :: Subst -> Type -> Type
zonk s t = case t of
  TMeta m | Just t' <- IM.lookup m s -> zonk s t'
  TCon c ts -> TCon c (map (zonk s) ts)
  TFun a b -> TFun (zonk s a) (zonk s b)
  TApp f x -> tApp (zonk s f) (zonk s x)
  _ -> t

-- | Replaces rigid type variables.
substTV :: M.Map Name Type -> Type -> Type
substTV s = \case
  TVar v -> M.findWithDefault (TVar v) v s
  TCon c ts -> TCon c (map (substTV s) ts)
  TFun a b -> TFun (substTV s a) (substTV s b)
  TApp f x -> tApp (substTV s f) (substTV s x)
  t -> t

tyVarsOf :: Type -> [Name]
tyVarsOf = \case
  TVar v -> [v]
  TCon _ ts -> concatMap tyVarsOf ts
  TFun a b -> tyVarsOf a ++ tyVarsOf b
  TApp f x -> tyVarsOf f ++ tyVarsOf x
  TMeta _ -> []

-- | Type variables passed where a data type takes a type constructor, like
-- the m of StateT s m a: they are of a higher kind too.
dataHkVars :: M.Map Name DataInfo -> Type -> [Name]
dataHkVars datas = go
  where
    go = \case
      TCon c ts -> [v | (k, TVar v) <- zip (maybe [] diKinds (M.lookup c datas)) ts, k > 0] ++ concatMap go ts
      TFun a b -> go a ++ go b
      TApp f x -> go f ++ go x
      _ -> []

-- | Every type that appears in an expression, for passes that need to see them all.
exprTypes :: CExpr -> [Type]
exprTypes = \case
  CVar _ ref t -> t : refTypes ref
  CCon _ ts t -> t : ts
  CLit _ -> []
  CNum _ t _ -> [t]
  CFrac _ t _ -> [t]
  CApp f as -> exprTypes f ++ concatMap exprTypes as
  CLam ps r b -> r : map snd ps ++ exprTypes b
  CLet bs b t -> t : concatMap bindTypes bs ++ exprTypes b
  CMatch ss rows t -> t : concatMap exprTypes ss ++ concatMap rowTypes rows
  CIf a b c t -> t : concatMap exprTypes [a, b, c]
  CDelay t e -> t : exprTypes e
  CForce e -> exprTypes e
  CDo m _ r ss -> m : r : concatMap stmtTypes ss
  where
    refTypes (Inst ts _) = ts
    refTypes SelfGroup = []
    bindTypes (CBind _ t _ b) = t : exprTypes b
    rowTypes (CRow ps bs gs) = concatMap patTypes ps ++ concatMap bindTypes bs ++ concat [maybe [] exprTypes g ++ exprTypes e | (g, e) <- gs]
    stmtTypes (CSBind _ t e) = t : exprTypes e
    stmtTypes (CSExpr t e) = t : exprTypes e
    stmtTypes (CSLet bs) = concatMap bindTypes bs
    patTypes = \case
      CPVar _ t -> [t]
      CPNum _ t _ _ -> [t]
      CPCon _ ts ps -> ts ++ concatMap patTypes ps
      CPForce p -> patTypes p
      CPAs _ t p -> t : patTypes p
      CPEq f v -> exprTypes f ++ exprTypes v
      _ -> []

-- | Type variables used as the head of an application: those of a higher kind.
headVars :: Type -> [Name]
headVars = \case
  TApp (TVar v) x -> v : headVars x
  TApp f x -> headVars f ++ headVars x
  TCon _ ts -> concatMap headVars ts
  TFun a b -> headVars a ++ headVars b
  _ -> []

-- | Evidence that a constraint holds.
data Dict
  = DInst Name [Type] [Dict]   -- ^ an instance, its type arguments and the dictionaries of its context
  | DParam Name                -- ^ a dictionary parameter in scope
  | DSuper Dict Name           -- ^ the superclass dictionary of that name inside another one
  | DHole Int                  -- ^ not solved yet; see 'progSolved'
  deriving (Show, Data)

-- | How a variable occurrence refers to its binding.
data VRef
  = Inst [Type] [Dict]   -- ^ type arguments and dictionaries for the binding's scheme
  | SelfGroup            -- ^ a recursive call inside an unsigned binding group
  deriving (Show, Data)

data CExpr
  = CVar Name VRef Type
  | CCon Name [Type] Type           -- ^ constructor, its type arguments, its type
  | CLit Lit
  | CNum Integer Type Dict          -- ^ an integer literal at a Num type
  | CFrac Double Type Dict          -- ^ a decimal literal at a Fractional type
  | CApp CExpr [CExpr]
  | CLam [(Name, Type)] Type CExpr  -- ^ curried parameters, result type, body
  | CLet [CBind] CExpr Type
  | CMatch [CExpr] [CRow] Type      -- ^ scrutinees, rows tried in order, result type
  | CIf CExpr CExpr CExpr Type
  | CDelay Type CExpr               -- ^ suspend a computation of the given type
  | CForce CExpr
  | CDo Type Dict Type [CStmt]      -- ^ do block: the monad, its Monad dictionary, the result type
  deriving (Show, Data)

-- | A local or top-level binding. With arity n > 0 the body is a 'CLam'
-- with n parameters, compiled as an uncurried Go function.
data CBind = CBind Name Type Int CExpr
  deriving (Show, Data)

-- | Patterns (one per scrutinee), local bindings, then guarded bodies.
data CRow = CRow [CPat] [CBind] [(Maybe CExpr, CExpr)]
  deriving (Show, Data)

data CPat
  = CPVar Name Type
  | CPWild
  | CPLit Lit
  | CPNum Integer Type Dict Dict   -- ^ an integer literal at a type with Eq and Num dictionaries
  | CPCon Name [Type] [CPat]
  | CPForce CPat      -- ^ force a lazy field before matching on it
  | CPEq CExpr CExpr  -- ^ equal, by this (==), to this value: a literal at a type of your own
  | CPAs Name Type CPat
  deriving (Show, Data)

data CStmt
  = CSBind Name Type CExpr   -- ^ @x <- e@, where e :: m t
  | CSExpr Type CExpr        -- ^ @e@, where e :: m t
  | CSLet [CBind]
  deriving (Show, Data)

-- | What code generation needs to know about each constructor.
data ConInfo = ConInfo
  { ciType :: Name
  , ciParams :: [Name]
  , ciFields :: [(Bool, Type)]   -- ^ (lazy?, field type over ciParams)
  , ciTag :: Int
  }
  deriving (Show, Data)

-- | A data type: its parameters, how many arguments each takes (0 for a
-- plain type, 1 for the m of StateT s m a), and its constructors.
data DataInfo = DataInfo {diParams :: [Name], diKinds :: [Int], diCons :: [Name], diNewtype :: Bool}
  deriving (Show, Data)

data Foreign = Foreign {fSymbol :: String, fType :: Type, fArity :: Int}
  deriving (Show, Data)

data ClassInfo = ClassInfo
  { clsVars :: [Name]
  , clsKinds :: [Int]              -- ^ how many arguments each variable takes: 0 for Eq, 1 for Monad
  , clsKey :: Int                  -- ^ the parameter that chooses the instance and determines the others
  , clsSupers :: [Pred]            -- ^ over clsVars, each class at most once
  , clsMethods :: [(Name, Scheme)] -- ^ in declaration order: Forall (clsVars ++ own vars) (class : own constraints)
  , clsDefaults :: [Name]          -- ^ methods with a default definition
  }
  deriving (Show, Data)

data InstInfo = InstInfo
  { instId :: Name
  , instClass :: Name
  , instVars :: [Name]
  , instCtx :: [Pred]                     -- ^ constraints on instVars
  , instHead :: [Type]                    -- ^ one type per class parameter
  , instMethods :: [(Name, Maybe CExpr)]  -- ^ every method of the class, in order; Nothing if missing
  , instSupers :: [(Name, Dict)]
  }
  deriving (Show, Data)

data TopBind = TopBind
  { tbName :: Name
  , tbParams :: [Name]           -- ^ quantified type variables, in order
  , tbDicts :: [(Name, Pred)]    -- ^ one dictionary parameter per constraint
  , tbType :: Type
  , tbArity :: Int
  , tbBody :: CExpr
  , tbShared :: Bool             -- ^ a value computed once (a CAF), not a function
  }
  deriving (Show, Data)

data Program = Program
  { progData :: M.Map Name DataInfo
  , progCons :: M.Map Name ConInfo
  , progForeign :: M.Map Name Foreign
  , progClasses :: M.Map Name ClassInfo
  , progInsts :: [InstInfo]
  , progBinds :: [TopBind]   -- ^ in dependency order
  , progSubst :: Subst
  , progSolved :: IM.IntMap Dict
  }
  deriving (Show, Data)

-- | The name of the dictionary parameter for a constraint: dict_Eq_a,
-- dict_MonadState_Int_m.
dictName :: Pred -> Name
dictName (IsIn cls ts) = "dict_" ++ cls ++ concatMap (("_" ++) . tag) ts
  where
    tag = \case
      TVar v -> v
      TCon c as -> con c ++ concatMap (("_" ++) . tag) as
      TFun a b -> "Fn_" ++ tag a ++ "_" ++ tag b
      TApp f x -> tag f ++ "_" ++ tag x
      TMeta m -> "X" ++ show m
    con = \case
      "[]" -> "List"
      "()" -> "Unit"
      "->" -> "Fn"
      c | Just n <- tupleArity c -> "Tup" ++ show n
      c -> map (\x -> if isAlphaNum x then x else '_') c

-- | Splits a function type into its first n argument types and the rest.
splitFun :: Int -> Type -> ([Type], Type)
splitFun 0 t = ([], t)
splitFun n (TFun a b) = let (as, r) = splitFun (n - 1) b in (a : as, r)
splitFun _ t = ([], t)

arrows :: Type -> Int
arrows (TFun _ b) = 1 + arrows b
arrows _ = 0

-- Generic traversals ---------------------------------------------------------------

-- | Every t inside a value, outermost first, looking inside each one too.
everything :: forall t a. (Data a, Typeable t) => a -> [t]
everything = go
  where
    go :: forall b. Data b => b -> [t]
    go x = case eqT @b @t of
      Just Refl -> x : concat (gmapQ go x)
      Nothing -> concat (gmapQ go x)

-- | Applies f to every t, innermost first.
everywhere :: forall t a. (Data a, Typeable t) => (t -> t) -> a -> a
everywhere f = go
  where
    go :: forall b. Data b => b -> b
    go x = case eqT @b @t of
      Just Refl -> f (gmapT go x)
      Nothing -> gmapT go x

-- | Every name bound inside: parameters, pattern variables, local bindings.
coreBinders :: Data a => a -> [Name]
coreBinders x =
  [n | CLam ps _ _ <- everything x, (n, _) <- ps]
    ++ [n | CBind n _ _ _ <- everything x]
    ++ [n | CPVar n _ <- everything x]
    ++ [n | CPAs n _ _ <- everything x]
    ++ [n | CSBind n _ _ <- everything x]
