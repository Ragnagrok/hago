{-# LANGUAGE LambdaCase #-}

-- | Typed core: the output of the type checker and the input of code
-- generation. Every node that Go needs a type for carries one; types may
-- still mention unification variables, which code generation resolves with
-- the final substitution. Class constraints are explicit dictionaries.
module Hago.Core where

import qualified Data.IntMap as IM
import qualified Data.Map as M
import Hago.Syntax (Lit (..), Name)

data Type
  = TVar Name          -- ^ rigid (quantified) type variable
  | TMeta Int          -- ^ unification variable
  | TCon Name [Type]   -- ^ Int, Double, Bool, Char, String, (), [], (,), IO, Lazy, user types;
                       --   with fewer arguments than its arity it is partially applied (Either e)
  | TFun Type Type
  | TApp Type Type     -- ^ application whose head is not known yet, as in @f a@
  deriving (Eq, Show)

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

-- | A class constraint: the class and the type it applies to.
data Pred = IsIn Name Type
  deriving (Eq, Show)

data Scheme = Forall [Name] [Pred] Type
  deriving (Show)

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
  deriving (Show)

-- | How a variable occurrence refers to its binding.
data VRef
  = Inst [Type] [Dict]   -- ^ type arguments and dictionaries for the binding's scheme
  | SelfGroup            -- ^ a recursive call inside an unsigned binding group
  deriving (Show)

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
  deriving (Show)

-- | A local or top-level binding. With arity n > 0 the body is a 'CLam'
-- with n parameters, compiled as an uncurried Go function.
data CBind = CBind Name Type Int CExpr
  deriving (Show)

-- | Patterns (one per scrutinee), local bindings, then guarded bodies.
data CRow = CRow [CPat] [CBind] [(Maybe CExpr, CExpr)]
  deriving (Show)

data CPat
  = CPVar Name Type
  | CPWild
  | CPLit Lit
  | CPNum Integer Type Dict Dict   -- ^ an integer literal at a type with Eq and Num dictionaries
  | CPCon Name [Type] [CPat]
  | CPForce CPat      -- ^ force a lazy field before matching on it
  | CPEq CExpr CExpr  -- ^ equal, by this (==), to this value: a literal at a type of your own
  | CPAs Name Type CPat
  deriving (Show)

data CStmt
  = CSBind Name Type CExpr   -- ^ @x <- e@, where e :: m t
  | CSExpr Type CExpr        -- ^ @e@, where e :: m t
  | CSLet [CBind]
  deriving (Show)

-- | What code generation needs to know about each constructor.
data ConInfo = ConInfo
  { ciType :: Name
  , ciParams :: [Name]
  , ciFields :: [(Bool, Type)]   -- ^ (lazy?, field type over ciParams)
  , ciTag :: Int
  }
  deriving (Show)

data DataInfo = DataInfo {diParams :: [Name], diCons :: [Name]}
  deriving (Show)

data Foreign = Foreign {fSymbol :: String, fType :: Type, fArity :: Int}
  deriving (Show)

data ClassInfo = ClassInfo
  { clsVar :: Name
  , clsKind :: Int                 -- ^ how many arguments the class variable takes: 0 for Eq, 1 for Monad
  , clsSupers :: [Name]
  , clsMethods :: [(Name, Scheme)] -- ^ in declaration order: Forall (clsVar : own vars) (class : own constraints)
  , clsDefaults :: [Name]          -- ^ methods with a default definition
  }
  deriving (Show)

data InstInfo = InstInfo
  { instId :: Name
  , instClass :: Name
  , instVars :: [Name]
  , instCtx :: [Pred]                     -- ^ constraints on instVars
  , instHead :: Type
  , instMethods :: [(Name, Maybe CExpr)]  -- ^ every method of the class, in order; Nothing if missing
  , instSupers :: [(Name, Dict)]
  }
  deriving (Show)

data TopBind = TopBind
  { tbName :: Name
  , tbParams :: [Name]           -- ^ quantified type variables, in order
  , tbDicts :: [(Name, Pred)]    -- ^ one dictionary parameter per constraint
  , tbType :: Type
  , tbArity :: Int
  , tbBody :: CExpr
  , tbShared :: Bool             -- ^ a value computed once (a CAF), not a function
  }
  deriving (Show)

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

-- | The name of the dictionary parameter for a constraint on a type variable.
dictName :: Name -> Name -> Name
dictName cls v = "dict_" ++ cls ++ "_" ++ v

-- | Splits a function type into its first n argument types and the rest.
splitFun :: Int -> Type -> ([Type], Type)
splitFun 0 t = ([], t)
splitFun n (TFun a b) = let (as, r) = splitFun (n - 1) b in (a : as, r)
splitFun _ t = ([], t)

arrows :: Type -> Int
arrows (TFun _ b) = 1 + arrows b
arrows _ = 0
