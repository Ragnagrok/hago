{-# LANGUAGE LambdaCase #-}

-- | Local bindings are computed where they are needed. A binding of a
-- @let@ or a @where@ that only some branches use moves into those branches,
-- and one that nothing uses is dropped. Hago is strict, so without this
--
-- > safeDiv a b
-- >   | b == 0 = Nothing
-- >   | otherwise = Just q
-- >   where q = a `div` b
--
-- would divide by zero before looking at the guards. Since the code is
-- pure, computing a binding on fewer paths can only stop a program from
-- failing or looping where it did not have to. What a guard, a condition or
-- a scrutinee uses is still computed before it.
module Hago.Sink (sinkLocals) where

import Data.Data (Data)
import qualified Data.Set as S
import Hago.Core
import Hago.Syntax (Name)

sinkLocals :: Program -> Program
sinkLocals = everywhere step
  where
    step = \case
      CLet bs body t -> letIn bs body t
      CMatch ss rows t -> CMatch ss (map (sinkRow t) rows) t
      e -> e

-- | The bindings placed as close as they can be to their uses in body.
letIn :: [CBind] -> CExpr -> Type -> CExpr
letIn [] body _ = body
letIn bs body t = case body of
  CIf c a b t' ->
    let keep = needed bs (refsIn c)
        rest = without keep bs
     in wrap keep (CIf c (letIn (needed rest (refsIn a)) a t') (letIn (needed rest (refsIn b)) b t') t') t
  CMatch ss rows t'
    | not (any (captures (without (needed bs (foldMap refsIn ss)) bs)) rows) ->
        let keep = needed bs (foldMap refsIn ss)
            rest = without keep bs
            into row@(CRow ps rbs gs) = sinkRow t' (CRow ps (needed rest (refsIn row) ++ rbs) gs)
         in wrap keep (CMatch ss (map into rows) t') t
  _ -> wrap (needed bs (refsIn body)) body t
  where
    -- a row that binds a name the bindings use, or define, would see its own
    captures moving row =
      let bound = S.fromList (coreBinders row ++ patternVars row)
          used = foldMap refsIn moving `S.union` S.fromList (map bindName moving)
       in not (S.null (S.intersection bound used))

-- | The row's bindings that no guard uses move into the bodies that use them.
sinkRow :: Type -> CRow -> CRow
sinkRow t (CRow ps bs gs) =
  let keep = needed bs (foldMap refsIn [g | (Just g, _) <- gs])
      rest = without keep bs
   in CRow ps keep [(g, letIn (needed rest (refsIn e)) e t) | (g, e) <- gs]

-- | Those of the bindings that the names need, directly or through each
-- other, in their order.
needed :: [CBind] -> S.Set Name -> [CBind]
needed bs names = [b | b <- bs, S.member (bindName b) (grow names)]
  where
    grow acc =
      let acc' = acc `S.union` foldMap (\(CBind n _ _ e) -> if S.member n acc then refsIn e else S.empty) bs
       in if acc' == acc then acc else grow acc'

without :: [CBind] -> [CBind] -> [CBind]
without gone = filter (\b -> bindName b `notElem` map bindName gone)

wrap :: [CBind] -> CExpr -> Type -> CExpr
wrap [] e _ = e
wrap bs e t = CLet bs e t

bindName :: CBind -> Name
bindName (CBind n _ _ _) = n

refsIn :: Data a => a -> S.Set Name
refsIn e = S.fromList [x | CVar x _ _ <- everything e]

patternVars :: CRow -> [Name]
patternVars row = [x | CPVar x _ <- everything row] ++ [x | CPAs x _ _ <- everything row]
