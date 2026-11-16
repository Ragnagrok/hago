-- | @deriving (Eq, Ord, Show)@, expanded into ordinary instance declarations
-- before type checking.
module Hago.Derive (expandDeriving) where

import Data.Char (isAlpha)
import Hago.Syntax

expandDeriving :: [Decl] -> Either String [Decl]
expandDeriving ds = (ds ++) . concat <$> mapM derive [d | d@(DData _ _ _ (_ : _)) <- ds]
  where
    derive (DData n ps cons classes) = mapM (instanceFor n ps cons) classes
    derive _ = Right []

instanceFor :: Name -> [Name] -> [ConDecl] -> Name -> Either String Decl
instanceFor n ps cons cls = do
  methods <- case cls of
    "Eq" -> Right [DBind "==" (eqClauses cons)]
    "Ord" -> Right [DBind "compare" (ordClauses cons)]
    "Show" -> Right [DBind "showsPrec" (map showClause cons)]
    _ -> Left ("cannot derive " ++ cls ++ " for " ++ n ++ " (only Eq, Ord and Show)")
  pure (DInstance [(cls, p) | p <- ps] cls (STCon n (map STVar ps)) methods)

-- | Two patterns for the same constructor, with fields named a1.. and b1..
fieldsOf :: ConDecl -> (Name, Int)
fieldsOf (ConDecl k fs) = (k, length fs)

vars :: String -> Int -> [Name]
vars prefix k = [prefix ++ show i | i <- [1 .. k]]

conPat :: Name -> [Name] -> Pat
conPat k vs = PCon k (map PVar vs)

plain :: Expr -> Rhs
plain e = Rhs [(Nothing, e)] []

app :: Expr -> [Expr] -> Expr
app = foldl EApp

op :: Name -> Expr -> Expr -> Expr
op o a b = app (EVar o) [a, b]

eqClauses :: [ConDecl] -> [Clause]
eqClauses cons =
  [ Clause [conPat k as, conPat k bs] (plain (conj [op "==" (EVar a) (EVar b) | (a, b) <- zip as bs]))
  | c <- cons, let (k, m) = fieldsOf c, let as = vars "a" m, let bs = vars "b" m ]
    ++ [Clause [PWild, PWild] (plain (ECon "False")) | length cons > 1]
  where
    conj [] = ECon "True"
    conj xs = foldr1 (op "&&") xs

-- | Same constructor: compare the fields left to right. Different ones:
-- compare their position in the declaration.
ordClauses :: [ConDecl] -> [Clause]
ordClauses cons =
  [ Clause [conPat k as, conPat k bs] (plain (lexi [op "compare" (EVar a) (EVar b) | (a, b) <- zip as bs]))
  | c <- cons, let (k, m) = fieldsOf c, let as = vars "a" m, let bs = vars "b" m ]
    ++ [ Clause [PVar "x", PVar "y"] (Rhs [(Nothing, op "compare" (EApp (EVar "tag") (EVar "x")) (EApp (EVar "tag") (EVar "y")))]
           [DBind "tag" [Clause [PCon k (replicate m PWild)] (plain (ELit (LInt i))) | (i, c) <- zip [0 ..] cons, let (k, m) = fieldsOf c]])
       | length cons > 1 ]
  where
    lexi [] = ECon "EQ"
    lexi xs = foldr1 (op "thenCmp") xs

showClause :: ConDecl -> Clause
showClause c =
  let (k, m) = fieldsOf c
      as = vars "a" m
      name = case k of
        (ch : _) | isAlpha ch -> k
        _ -> "(" ++ k ++ ")"
      body = foldl (\acc a -> op "++" acc (op "++" (ELit (LStr " ")) (app (EVar "showsPrec") [ELit (LInt 11), EVar a])))
                   (ELit (LStr name)) as
   in if m == 0
        then Clause [PWild, PCon k []] (plain (ELit (LStr name)))
        else Clause [PVar "d", conPat k as] (plain (app (EVar "showParenString") [op ">" (EVar "d") (ELit (LInt 10)), body]))
