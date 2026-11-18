{-# LANGUAGE DeriveDataTypeable #-}

-- | Surface syntax: what the parser produces, before type checking.
module Hago.Syntax where

import Data.Char (isAlphaNum, isUpper)
import Data.Data (Data)
import Data.List (intercalate)

type Name = String

-- | Tuples go up to fifteen elements, as Haskell 98 asks; past that a record
-- names its fields.
maxTuple :: Int
maxTuple = 15

-- | The constructor of an n-tuple: "(,)", "(,,)", ...
tupleCon :: Int -> Name
tupleCon n = "(" ++ replicate (n - 1) ',' ++ ")"

-- | How many elements a tuple constructor has, if it is one.
tupleArity :: Name -> Maybe Int
tupleArity c = case c of
  '(' : ',' : rest | all (== ',') (init rest), last rest == ')' -> Just (length rest + 1)
  _ -> Nothing

-- | Where something is in the source: file, line, column.
type Loc = (FilePath, Int, Int)

showLoc :: Loc -> String
showLoc (f, l, c) = f ++ ":" ++ show l ++ ":" ++ show c

data Lit = LInt Integer | LDouble Double | LChar Char | LStr String
  deriving (Eq, Show, Data)

-- | Types as the programmer writes them. Lists are @STCon "[]" [t]@, tuples
-- @STCon "(,)" [a, b]@, unit @STCon "()" []@ and suspended values
-- @STCon "Lazy" [t]@.
data SType
  = STVar Name
  | STCon Name [SType]
  | STFun SType SType
  | STApp SType [SType]   -- ^ a type variable applied to arguments, as in @m a@
  deriving (Eq, Show, Data)

data Pat
  = PVar Name
  | PWild
  | PLit Lit
  | PCon Name [Pat]
  | PAs Name Pat
  | PRec Name [(Name, Pat)]   -- ^ @C { x = p, y }@: the fields not named are ignored
  | PLoc Loc Pat
  deriving (Eq, Show, Data)

-- | A pattern without its location.
unLocP :: Pat -> Pat
unLocP (PLoc _ p) = unLocP p
unLocP p = p

data Expr
  = EVar Name
  | ECon Name
  | ELit Lit
  | EApp Expr Expr
  | ELam [Pat] Expr
  | ELet [Decl] Expr
  | EIf Expr Expr Expr
  | ECase Expr [Alt]
  | EDo [Stmt]
  | EAnn Expr SType               -- ^ @e :: t@
  | EField Expr Name [Name]       -- ^ @e.x@, and the record types whose fields are visible here
  | ERecCon Name [(Name, Expr)]   -- ^ @C { x = e, y }@: every field must be given
  | ERecUpd Expr [(Name, Expr)] [Name]   -- ^ @e { x = v }@, and the visible record types with those fields
  | ELoc Loc Expr
  | EOpSeq Expr [((Name, Loc), Expr)]   -- ^ unresolved operators, with where each is, removed by 'resolveFixity'
  deriving (Eq, Show, Data)

-- | An expression without its location.
unLoc :: Expr -> Expr
unLoc (ELoc _ e) = unLoc e
unLoc e = e

data Alt = Alt Pat Rhs
  deriving (Eq, Show, Data)

-- | Guarded or plain right-hand side, with its @where@ declarations.
data Rhs = Rhs [(Maybe Expr, Expr)] [Decl]
  deriving (Eq, Show, Data)

data Stmt
  = SBind Name Expr
  | SBindPat Pat Expr   -- ^ removed by the parser: @p <- e@ becomes a bind and a case
  | SLet [Decl]
  | SExpr Expr
  deriving (Eq, Show, Data)

data Clause = Clause [Pat] Rhs
  deriving (Eq, Show, Data)

-- | A constructor, its fields ('True' marks a lazy (@~@) field), and their
-- names if it is declared with record syntax.
data ConDecl = ConDecl Name [(Bool, SType)] [Name]
  deriving (Eq, Show, Data)

data Assoc = AssocL | AssocR | AssocN
  deriving (Eq, Show, Data)

data DataDecl = DataDecl
  { ddName :: Name
  , ddParams :: [Name]
  , ddCons :: [ConDecl]
  , ddDeriving :: [Name]
  , ddNewtype :: Bool
  , ddLoc :: Loc
  , ddForeign :: Maybe String
    -- ^ a Go type declared with @foreign import go type@: no constructors,
    -- and values only Go functions make
  }
  deriving (Eq, Show, Data)

-- | Class constraints, as in @(Eq a, MonadState Int m) =>@: each class with
-- its types.
type Context = [(Name, [SType])]

-- | A functional dependency, as in @| m -> s@.
type FunDep = ([Name], [Name])

data Decl
  = DData DataDecl
  | DType Name [Name] SType                -- ^ a type synonym
  | DSig [Name] Context SType
  | DClass Context Name [Name] [FunDep] [Decl]   -- ^ superclasses, class, variables, dependencies, signatures and defaults
  | DInstance (Maybe Loc) Context Name [SType] [Decl]   -- ^ where, context, class, instance types, methods
  | DBind Name [Clause]
  | DFixity Assoc Int [Name]
  | DForeign String Name SType   -- ^ Go symbol, Hago name, type
  deriving (Eq, Show, Data)

isConName :: Name -> Bool
isConName n = case unqual n of
  (c : _) -> c `elem` (':' : ['A' .. 'Z']) || c == '(' || c == '['
  [] -> False

-- | Splits a qualified name: "Data.Map.lookup" is (Just "Data.Map", "lookup"),
-- "Main.<+>" is (Just "Main", "<+>"), and "." is (Nothing, ".").
splitQual :: Name -> (Maybe Name, Name)
splitQual = go []
  where
    go acc s = case s of
      (c : _) | isUpper c, (seg, '.' : rest@(_ : _)) <- span idChar s -> go (acc ++ [seg]) rest
      _ -> (if null acc then Nothing else Just (intercalate "." acc), s)
    idChar x = isAlphaNum x || x == '_' || x == '\''

unqual :: Name -> Name
unqual = snd . splitQual

-- | What an import or export list names: a value, or a type or class with
-- none, all or some of its constructors or methods. An export list can also
-- name a whole module, to re-export what it imports from it.
data Item = IVar Name | IType Name Sub | IModule Name
  deriving (Eq, Show)

data Sub = SubNone | SubAll | SubSome [Name]
  deriving (Eq, Show)

data Import = Import
  { impModule :: Name
  , impQualified :: Bool
  , impAs :: Maybe Name
  , impOnly :: Maybe [Item]
  , impHiding :: [Item]
  , impLoc :: Loc
  }
  deriving (Eq, Show)

data Module = Module
  { modName :: Name
  , modExports :: Maybe [Item]
  , modImports :: [Import]
  , modDecls :: [Decl]
  , modLoc :: Loc                          -- ^ where the module header is
  }
  deriving (Show)
