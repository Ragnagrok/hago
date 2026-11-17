{-# LANGUAGE LambdaCase #-}

-- | Whether the rows of a match cover every value, as in Maranget's
-- "Warnings for pattern matching" (2007), reduced to what an error needs:
-- a list of patterns that no row matches, if there is one. Literals are
-- never complete, and a row with guards only counts if one of its guards is
-- otherwise or True, since nothing else can be known to hold.
module Hago.Exhaustive (Witness (..), uncovered, showWitness) where

import Data.List (intercalate, nub)
import Hago.Core
import Hago.Syntax (Lit (..), Name, tupleArity, unqual)

-- | A value no row matches: anything, a constructor, or a literal none of
-- the rows has.
data Witness = WAny | WCon Name [Witness] | WLit String

-- | The first value, one pattern per scrutinee, that no row matches.
-- siblings gives a constructor's type's constructors, with their arities.
uncovered :: (Name -> [(Name, Int)]) -> Int -> [CRow] -> Maybe [Witness]
uncovered siblings n rows = go [map plain ps | CRow ps _ gs <- rows, any total gs] n
  where
    total = \case
      (Nothing, _) -> True
      (Just g, _) -> trivial g
    trivial = \case
      CVar "otherwise" _ _ -> True
      CCon "True" _ _ -> True
      _ -> False
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
