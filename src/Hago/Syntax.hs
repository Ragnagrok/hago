-- | Surface syntax: what the parser produces, before type checking.
module Hago.Syntax where

type Name = String

data Lit = LInt Integer | LChar Char | LStr String
  deriving (Eq, Show)

-- | Types as the programmer writes them. Lists are @STCon "[]" [t]@, tuples
-- @STCon "(,)" [a, b]@, unit @STCon "()" []@ and suspended values
-- @STCon "Lazy" [t]@.
data SType
  = STVar Name
  | STCon Name [SType]
  | STFun SType SType
  deriving (Eq, Show)

data Pat
  = PVar Name
  | PWild
  | PLit Lit
  | PCon Name [Pat]
  | PAs Name Pat
  deriving (Eq, Show)

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
  | EOpSeq Expr [(Name, Expr)]   -- ^ unresolved operators, removed by 'resolveFixity'
  deriving (Eq, Show)

data Alt = Alt Pat Rhs
  deriving (Eq, Show)

-- | Guarded or plain right-hand side, with its @where@ declarations.
data Rhs = Rhs [(Maybe Expr, Expr)] [Decl]
  deriving (Eq, Show)

data Stmt
  = SBind Name Expr
  | SLet [Decl]
  | SExpr Expr
  deriving (Eq, Show)

data Clause = Clause [Pat] Rhs
  deriving (Eq, Show)

-- | A constructor and its fields; 'True' marks a lazy (@~@) field.
data ConDecl = ConDecl Name [(Bool, SType)]
  deriving (Eq, Show)

data Assoc = AssocL | AssocR | AssocN
  deriving (Eq, Show)

data Decl
  = DData Name [Name] [ConDecl]
  | DSig [Name] SType
  | DBind Name [Clause]
  | DFixity Assoc Int [Name]
  | DForeign String Name SType   -- ^ Go symbol, Hago name, type
  deriving (Eq, Show)

isConName :: Name -> Bool
isConName (c : _) = c `elem` (':' : ['A' .. 'Z']) || c == '(' || c == '['
isConName [] = False
