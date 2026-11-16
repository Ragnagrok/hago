-- | Surface syntax: what the parser produces, before type checking.
module Hago.Syntax where

type Name = String

-- | Where something is in the source: file, line, column.
type Loc = (FilePath, Int, Int)

showLoc :: Loc -> String
showLoc (f, l, c) = f ++ ":" ++ show l ++ ":" ++ show c

data Lit = LInt Integer | LDouble Double | LChar Char | LStr String
  deriving (Eq, Show)

-- | Types as the programmer writes them. Lists are @STCon "[]" [t]@, tuples
-- @STCon "(,)" [a, b]@, unit @STCon "()" []@ and suspended values
-- @STCon "Lazy" [t]@.
data SType
  = STVar Name
  | STCon Name [SType]
  | STFun SType SType
  | STApp SType [SType]   -- ^ a type variable applied to arguments, as in @m a@
  deriving (Eq, Show)

data Pat
  = PVar Name
  | PWild
  | PLit Lit
  | PCon Name [Pat]
  | PAs Name Pat
  | PLoc Loc Pat
  deriving (Eq, Show)

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
  | ELoc Loc Expr
  | EOpSeq Expr [(Name, Expr)]   -- ^ unresolved operators, removed by 'resolveFixity'
  deriving (Eq, Show)

data Alt = Alt Pat Rhs
  deriving (Eq, Show)

-- | Guarded or plain right-hand side, with its @where@ declarations.
data Rhs = Rhs [(Maybe Expr, Expr)] [Decl]
  deriving (Eq, Show)

data Stmt
  = SBind Name Expr
  | SBindPat Pat Expr   -- ^ removed by the parser: @p <- e@ becomes a bind and a case
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

-- | A class constraint on a type variable, as in @Eq a =>@.
type Context = [(Name, Name)]

data Decl
  = DData Name [Name] [ConDecl] [Name]   -- ^ with its deriving list
  | DSig [Name] Context SType
  | DClass Context Name Name [Decl]       -- ^ superclasses, class, variable, signatures and defaults
  | DInstance (Maybe Loc) Context Name SType [Decl]   -- ^ where, context, class, instance type, methods
  | DBind Name [Clause]
  | DFixity Assoc Int [Name]
  | DForeign String Name SType   -- ^ Go symbol, Hago name, type
  deriving (Eq, Show)

isConName :: Name -> Bool
isConName (c : _) = c `elem` (':' : ['A' .. 'Z']) || c == '(' || c == '['
isConName [] = False
