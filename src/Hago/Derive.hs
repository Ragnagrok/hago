{-# LANGUAGE LambdaCase #-}

-- | @deriving@, expanded into ordinary instance declarations after renaming
-- (so the Prelude's names are the internal, unqualified ones) and before type
-- checking.
module Hago.Derive (expandDeriving) where

import Data.Char (isAlpha)
import Data.List (intercalate, nub)
import Hago.Syntax

expandDeriving :: [Decl] -> Either String [Decl]
expandDeriving ds = (ds ++) . concat <$> mapM derive [d | DData d <- ds]
  where
    derive d = mapM (instanceFor d) (ddDeriving d)

instanceFor :: DataDecl -> Name -> Either String Decl
instanceFor d cls = either (Left . ((showLoc (ddLoc d) ++ ": cannot derive " ++ unqual cls ++ " for " ++ unqual n ++ ": ") ++)) Right $
  case cls of
    "Eq" -> plainInstance [DBind "==" (eqClauses cons)]
    "Ord" -> plainInstance [DBind "compare" (ordClauses cons)]
    "Show" -> plainInstance [DBind "showsPrec" (map showClause cons)]
    "Functor" -> overLast "fmap" functorClause
    "Foldable" -> overLast "foldr" foldableClause
    "Traversable" -> overLast "traverse" traversableClause
    "Read" -> plainInstance [DBind "readsPrec" [Clause [] (plain (EApp (EVar "readParens") (ELam [PVar "d", PVar "s"] (foldr1 (op "<|>") (map readAlt cons)))))]]
    "Enum"
      | (k : _) <- [conName c | c <- cons, not (null (conFields c))] ->
          Left ("its constructor " ++ unqual k ++ " has fields, and only types whose constructors have none can be counted")
      | otherwise -> Right (DInstance Nothing [] cls (STCon n (map STVar ps))
          [ DBind "fromEnum" [Clause [PCon (conName c) []] (plain (ELit (LInt i))) | (i, c) <- zip [0 ..] cons]
          , DBind "toEnum" ([Clause [PLit (LInt i)] (plain (EApp (ECon "Just") (ECon (conName c)))) | (i, c) <- zip [0 ..] cons]
              ++ [Clause [PWild] (plain (ECon "Nothing"))]) ])
    "Bounded" -> case cons of
      [] -> Left "it has no constructors"
      [c] -> plainInstance
        [ DBind "minBound" [Clause [] (plain (app (ECon (conName c)) [EVar "minBound" | _ <- conFields c]))]
        , DBind "maxBound" [Clause [] (plain (app (ECon (conName c)) [EVar "maxBound" | _ <- conFields c]))] ]
      _ | (k : _) <- [conName c | c <- cons, not (null (conFields c))] ->
            Left ("it has several constructors and " ++ unqual k ++ " has fields: the first and last constructors are its bounds only when none has fields")
      first : more -> Right (DInstance Nothing [] cls (STCon n (map STVar ps))
            [ DBind "minBound" [Clause [] (plain (ECon (conName first)))]
            , DBind "maxBound" [Clause [] (plain (ECon (conName (last (first : more)))))] ])
    _ -> Left "only Eq, Ord, Show, Read, Enum, Bounded, Functor, Foldable and Traversable can be derived"
  where
    n = ddName d
    ps = ddParams d
    cons = ddCons d
    plainInstance methods = Right (DInstance Nothing [(cls, p) | p <- ps] cls (STCon n (map STVar ps)) methods)
    -- Functor and friends map over the last parameter: Tree, Either e
    overLast method mk = case reverse ps of
      [] -> Left "it has no type parameter"
      a : rest -> do
        clauses <- mapM (mk a) cons
        let heads = nub [h | c <- cons, (_, t) <- conFields c, h <- functorHeads a t]
        pure (DInstance Nothing [(cls, h) | h <- heads] cls (STCon n (map STVar (reverse rest))) [DBind method clauses])

-- | Type variables applied to the mapped parameter, as f in @f a@: the
-- instance needs the class for them too.
functorHeads :: Name -> SType -> [Name]
functorHeads a = \case
  STApp (STVar h) ts | any (mentions a) ts -> h : concatMap (functorHeads a) ts
  STApp h ts -> functorHeads a h ++ concatMap (functorHeads a) ts
  STCon _ ts -> concatMap (functorHeads a) ts
  STFun x y -> functorHeads a x ++ functorHeads a y
  STVar _ -> []

mentions :: Name -> SType -> Bool
mentions a = \case
  STVar v -> v == a
  STCon _ ts -> any (mentions a) ts
  STFun x y -> mentions a x || mentions a y
  STApp h ts -> mentions a h || any (mentions a) ts

conFields :: ConDecl -> [(Bool, SType)]
conFields (ConDecl _ fs _) = fs

conName :: ConDecl -> Name
conName (ConDecl k _ _) = k

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

str :: String -> Expr
str = ELit . LStr

-- Eq, Ord, Show ------------------------------------------------------------------

eqClauses :: [ConDecl] -> [Clause]
eqClauses cons =
  [ Clause [conPat k as, conPat k bs] (plain (conj [op "==" (EVar a) (EVar b) | (a, b) <- zip as bs]))
  | ConDecl k fs _ <- cons, let as = vars "a" (length fs), let bs = vars "b" (length fs) ]
    ++ [Clause [PWild, PWild] (plain (ECon "False")) | length cons > 1]
  where
    conj [] = ECon "True"
    conj xs = foldr1 (op "&&") xs

-- | Same constructor: compare the fields left to right. Different ones:
-- compare their position in the declaration.
ordClauses :: [ConDecl] -> [Clause]
ordClauses cons =
  [ Clause [conPat k as, conPat k bs] (plain (lexi [op "compare" (EVar a) (EVar b) | (a, b) <- zip as bs]))
  | ConDecl k fs _ <- cons, let as = vars "a" (length fs), let bs = vars "b" (length fs) ]
    ++ [ Clause [PVar "x", PVar "y"] (Rhs [(Nothing, op "compare" (EApp (EVar "tag") (EVar "x")) (EApp (EVar "tag") (EVar "y")))]
           [DBind "tag" [Clause [PCon k (replicate (length fs) PWild)] (plain (ELit (LInt i))) | (i, ConDecl k fs _) <- zip [0 ..] cons]])
       | length cons > 1 ]
  where
    lexi [] = ECon "EQ"
    lexi xs = foldr1 (op "thenCmp") xs

-- | Like Haskell's: @Circle 1.0@, and @Person {name = "Ana", age = 30}@ for records.
showClause :: ConDecl -> Clause
showClause (ConDecl k fs labels) =
  let m = length fs
      as = vars "a" m
      name = case unqual k of
        k'@(ch : _) | isAlpha ch -> k'
        k' -> "(" ++ k' ++ ")"
      shown p a = app (EVar "showsPrec") [ELit (LInt p), EVar a]
      body
        | null labels = foldl (\acc a -> op "++" acc (op "++" (str " ") (shown 11 a))) (str name) as
        | otherwise =
            foldr (op "++") (str "}")
              (str (name ++ " {") : intercalate [str ", "] [[str (l ++ " = "), shown 0 a] | (l, a) <- zip labels as])
   in if m == 0
        then Clause [PWild, PCon k []] (plain (str name))
        else Clause [PVar "d", conPat k as] (plain (app (EVar "showParenString") [op ">" (EVar "d") (ELit (LInt 10)), body]))

-- | How one constructor reads, the way showClause prints it: K, K a b, or
-- K {x = a, y = b}.
readAlt :: ConDecl -> Expr
readAlt (ConDecl k fs labels)
  | null fs = app (EVar "readConstant") [str name, ECon k, s]
  | null labels = iterate (EApp (EVar "readArg")) (app (EVar "readApply") [str name, ECon k, d, s]) !! length fs
  | otherwise =
      EApp (EVar "readClose") $
        foldl (\acc (i, l) -> app (EVar "readField") [str l, ECon (if i == (0 :: Int) then "True" else "False"), acc])
          (app (EVar "readRecord") [str name, ECon k, d, s]) (zip [0 ..] labels)
  where
    name = case unqual k of
      k'@(ch : _) | isAlpha ch -> k'
      k' -> "(" ++ k' ++ ")"
    d = EVar "d"
    s = EVar "s"

-- Functor, Foldable, Traversable ---------------------------------------------------

-- | @fmap f (C x1 x2) = C (fmap f x1) x2@, field by field.
functorClause :: Name -> ConDecl -> Either String Clause
functorClause a c = do
  let xs = vars "x" (length (conFields c))
  args <- sequence [mapField a (0 :: Int) t (EVar x) | ((_, t), x) <- zip (conFields c) xs]
  pure (Clause [PVar "f", conPat (conName c) xs] (plain (app (ECon (conName c)) args)))
  where
    mapField v depth t x
      | not (mentions v t) = Right x
      | t == STVar v = Right (EApp (EVar "f") x)
      | otherwise = case t of
          STFun p r
            | mentions v p -> Left "a field is a function that takes the parameter"
            | otherwise -> do
                let y = "y" ++ show depth
                body <- mapField v (depth + 1) r (EApp x (EVar y))
                pure (ELam [PVar y] body)
          _ -> do
            inner <- lastArg v t
            fn <- under depth inner
            pure (app (EVar "fmap") [fn, x])
      where
        under d inner
          | inner == STVar v = Right (EVar "f")
          | otherwise = do
              let y = "y" ++ show d
              body <- mapField v (d + 1) inner (EVar y)
              pure (ELam [PVar y] body)

-- | @foldr f z (C x1 x2) = f x1 (foldr f z x2)@: the fields that hold the
-- parameter, right to left.
foldableClause :: Name -> ConDecl -> Either String Clause
foldableClause a c = do
  let xs = vars "x" (length (conFields c))
  body <- foldr (\(t, x) acc -> acc >>= step a (0 :: Int) t (EVar x)) (Right (EVar "z")) (zip (map snd (conFields c)) xs)
  pure (Clause [PVar "f", PVar "z", conPat (conName c) xs] (plain body))
  where
    step v depth t x acc
      | not (mentions v t) = Right acc
      | t == STVar v = Right (app (EVar "f") [x, acc])
      | otherwise = case t of
          STFun {} -> Left "a field is a function"
          _ -> do
            inner <- lastArg v t
            fn <- if inner == STVar v
              then Right (EVar "f")
              else do
                let y = "y" ++ show depth
                    r = "r" ++ show depth
                body <- step v (depth + 1) inner (EVar y) (EVar r)
                pure (ELam [PVar y, PVar r] body)
            pure (app (EVar "foldr") [fn, acc, x])

-- | @traverse f (C x1 x2) = pure (\y1 -> C y1 x2) <*> f x1@: the fields
-- that hold the parameter go through the applicative, the others stay.
traversableClause :: Name -> ConDecl -> Either String Clause
traversableClause a c = do
  let xs = vars "x" (length (conFields c))
  effects <- sequence [fmap ((,) x) <$> trav a (0 :: Int) t (EVar x) | ((_, t), x) <- zip (conFields c) xs]
  let moving = [(x, e) | Just (x, e) <- effects]
      ys = ["y_" ++ x | (x, _) <- moving]
      rebuilt = app (ECon (conName c)) [maybe (EVar x) EVar (lookup x (zip (map fst moving) ys)) | x <- xs]
      fn = if null ys then rebuilt else ELam (map PVar ys) rebuilt
      body = foldl (op "<*>") (EApp (EVar "pure") fn) (map snd moving)
  pure (Clause [PVar "f", conPat (conName c) xs] (plain body))
  where
    trav v depth t x
      | not (mentions v t) = Right Nothing
      | t == STVar v = Right (Just (EApp (EVar "f") x))
      | otherwise = case t of
          STFun {} -> Left "a field is a function"
          _ -> do
            inner <- lastArg v t
            fn <- if inner == STVar v
              then Right (EVar "f")
              else do
                let y = "y" ++ show depth
                r <- trav v (depth + 1) inner (EVar y)
                pure (ELam [PVar y] (maybe (EApp (EVar "pure") (EVar y)) id r))
            pure (Just (app (EVar "traverse") [fn, x]))

-- | In @T b a@, the a: the only argument allowed to mention the parameter.
lastArg :: Name -> SType -> Either String SType
lastArg v t = case t of
  STCon c ts@(_ : _) | not (any (mentions v) (init ts)), not (isTuple c) -> Right (last ts)
  STApp h ts@(_ : _) | not (mentions v h), not (any (mentions v) (init ts)) -> Right (last ts)
  _ -> Left "the parameter appears in a field other than as the last argument of a type"
  where
    isTuple c = take 2 c == "(,"
