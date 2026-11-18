{-# LANGUAGE LambdaCase #-}

-- | Whether the rows of a match cover every value, as in Maranget's
-- "Warnings for pattern matching" (2007), reduced to what an error needs:
-- a list of patterns that no row matches, if there is one. Literals are
-- never complete, and a row with guards only counts if its guards are known
-- to cover everything (see 'guardsTotal').
module Hago.Exhaustive (Witness (..), uncovered, guardsTotal, showWitness) where

import Data.List (intercalate, nub)
import qualified Data.Map as M
import qualified Data.Set as S
import Hago.Core
import Hago.Syntax (Lit (..), Name, tupleArity, unqual)

-- | A value no row matches: anything, a constructor, or a literal none of
-- the rows has.
data Witness = WAny | WCon Name [Witness] | WLit String

-- | The first value, one pattern per scrutinee, that no row matches.
-- siblings gives a constructor's type's constructors, with their arities;
-- each row comes with whether its guards cover everything.
uncovered :: (Name -> [(Name, Int)]) -> Int -> [([CPat], Bool)] -> Maybe [Witness]
uncovered siblings n rows = go [map plain ps | (ps, True) <- rows] n
  where
    plain = \case
      CPAs _ _ p -> plain p
      CPForce p -> plain p
      CPVar _ _ -> CPWild
      CPCon k ts ps -> CPCon k ts (map plain ps)
      p -> p
    go m 0 = if null m then Just [] else Nothing
    go m k =
      case nub [c | (CPCon c _ _ : _) <- m] of
        [] -> (literalNotIn [l | (l : _) <- m] :) <$> go (defaults m) (k - 1)
        heads@(c0 : _) ->
          let cons = siblings c0
           in if all ((`elem` heads) . fst) cons
                then firstJust
                  [ (\ws -> let (as, rest) = splitAt a ws in WCon c as : rest) <$> go (specialise c a m) (a + k - 1)
                  | (c, a) <- cons ]
                else
                  let absent = [WCon c (replicate a WAny) | (c, a) <- cons, c `notElem` heads]
                      w = case absent of
                        x : _ -> x
                        [] -> WAny
                   in (w :) <$> go (defaults m) (k - 1)
    -- a number, character or text that none of the patterns is
    literalNotIn ps =
      let nums = [i | CPNum i _ _ _ <- ps] ++ [i | CPLit (LInt i) <- ps]
          chars = [c | CPLit (LChar c) <- ps]
          strs = [t | CPLit (LStr t) <- ps]
          firstNotIn xs = map show . take 1 . filter (`notElem` xs)
          found
            | not (null nums) = firstNotIn nums [0 :: Integer ..]
            | not (null chars) = firstNotIn chars ['a' ..]
            | not (null strs) = firstNotIn strs ("" : map pure ['a' ..])
            | otherwise = []
       in case found of
            l : _ -> WLit l
            [] -> WAny
    -- the rows that match constructor c, with its fields in its place
    specialise c a m = concatMap (\case
      CPCon c' _ ps : rest | c' == c -> [ps ++ rest]
      CPWild : rest -> [replicate a CPWild ++ rest]
      _ -> []) m
    -- the rows that match anything in the first place, without it
    defaults m = [rest | CPWild : rest <- m]
    firstJust xs = case [x | Just x <- xs] of
      x : _ -> Just x
      [] -> Nothing

-- | As a pattern is written; an argument is in parentheses if it needs them.
showWitness :: Bool -> Witness -> String
showWitness = go
  where
    go _ WAny = "_"
    go _ (WLit l) = l
    go _ (WCon "[]" []) = "[]"
    go _ (WCon c ws) | Just _ <- tupleArity c = "(" ++ intercalate ", " (map (go False) ws) ++ ")"
    go nested (WCon ":" [x, xs]) = paren nested (go True x ++ " : " ++ go False xs)
    go _ (WCon c []) = unqual c
    go nested (WCon c ws) = paren nested (unwords (unqual c : map (go True) ws))
    paren True s = "(" ++ s ++ ")"
    paren False s = s

-- | Whether one of the guards always holds, or the guards together do.
-- Beyond otherwise and True, that is known for:
--
-- * a condition and its negation with not (@null xs@, @not (null xs)@),
--   and even and odd of the same number;
-- * comparisons of the same two values that between them cover less,
--   equal and greater (@n < 0@, @n >= 0@, or @n > 0@, @n < 0@, @n == 0@),
--   at Int, Integer, Char, String and Bool, whose instances are the
--   Prelude's. At Double they are not complementary (NaN), and an instance
--   someone wrote need not be lawful.
--
-- Two guards are about the same values when they are written the same way,
-- up to the names of the variables they mention, which in one row's guards
-- always mean the same thing. global says whether a name is the Prelude's,
-- not a local that hides it; the types must be zonked.
guardsTotal :: (Name -> Bool) -> [(Maybe CExpr, CExpr)] -> Bool
guardsTotal global gs = any (\(g, _) -> null g) gs || any covers (M.toList facts)
  where
    facts = M.fromListWith S.union [(k, o) | (Just g, _) <- gs, Just (k, o) <- [fact g]]
    covers (Left _, o) = o == S.fromList [LT, GT]
    covers (Right _, o) = o == S.fromList [LT, EQ, GT]
    -- a condition as what it is about and the outcomes it holds for: a
    -- Bool (Left, True as GT and False as LT) or a comparison (Right)
    fact :: CExpr -> Maybe (Either String (String, String), S.Set Ordering)
    fact e = case spine e of
      (CVar "otherwise" _ _, []) | global "otherwise" -> Just (Left "True", S.fromList [LT, GT])
      (CCon "True" _ _, []) -> Just (Left "True", S.fromList [LT, GT])
      (CVar "not" _ _, [c]) | global "not" -> fmap (S.map flipBool) <$> fact c
      (CVar "odd" _ _, [x]) | global "odd", global "even" -> (\k -> (Left ("(even " ++ k ++ ")"), S.singleton LT)) <$> key x
      (CVar op (Inst [t] _) _, [a, b])
        | Just o <- lookup op comparisons, global op, lawful t ->
            (\ka kb -> if ka <= kb then (Right (ka, kb), o) else (Right (kb, ka), S.map flipCmp o)) <$> key a <*> key b
      _ -> (\k -> (Left k, S.singleton GT)) <$> key e
    flipBool o = if o == GT then LT else GT
    flipCmp = \case
      LT -> GT
      GT -> LT
      EQ -> EQ
    comparisons =
      [ ("<", S.fromList [LT]), ("<=", S.fromList [LT, EQ]), ("==", S.fromList [EQ])
      , ("/=", S.fromList [LT, GT]), (">", S.fromList [GT]), (">=", S.fromList [EQ, GT]) ]
    lawful = \case
      TCon c [] -> c `elem` ["Int", "Integer", "Char", "String", "Bool"]
      _ -> False
    spine = \case
      CApp f as -> let (h, xs) = spine f in (h, xs ++ as)
      e -> (e, [])
    -- the same text for the same value
    key :: CExpr -> Maybe String
    key = \case
      CVar x _ _ -> Just x
      CCon k _ _ -> Just k
      CLit l -> Just (show l)
      CNum i _ _ -> Just (show i)
      CApp f as -> (\k ks -> "(" ++ unwords (k : ks) ++ ")") <$> key f <*> mapM key as
      _ -> Nothing
