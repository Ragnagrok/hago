{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- | Newtypes cost nothing at run time. In a strict language a newtype means
-- what a data type with one constructor and one field means; the keyword
-- only promises that it is free. So after specialisation, when every
-- instance has been chosen by type, each newtype is replaced by the type it
-- wraps: wrapping and unwrapping disappear, and so does the Go struct.
--
-- A newtype stays a struct when it cannot be replaced: if it contains itself
-- (newtype Fix f = Fix (f (Fix f))), or if it is passed somewhere without all
-- its arguments, as the m of StateT s m a, where Go needs a type of its own.
module Hago.Newtype (eraseNewtypes) where

import Data.Data (Data, gmapQ, gmapT)
import Data.Graph (SCC (..), stronglyConnComp)
import qualified Data.IntMap as IM
import qualified Data.Map as M
import qualified Data.Set as S
import Data.Type.Equality ((:~:) (..))
import Data.Typeable (Typeable, eqT)
import Hago.Core
import Hago.Syntax (Name)

eraseNewtypes :: Program -> Program
eraseNewtypes prog0 = finish (loop (S.fromList acyclic))
  where
    -- every type is resolved now, so the substitution is no longer needed
    prog = (outermost (zonk (progSubst prog0)) prog0) {progSubst = IM.empty}
    newtypes = M.filter diNewtype (progData prog)
    field n = case diCons (newtypes M.! n) of
      [k] | [(_, t)] <- ciFields (progCons prog M.! k) -> (k, t)
      _ -> error "eraseNewtypes: not a newtype"
    acyclic = [n | AcyclicSCC n <- stronglyConnComp [(n, n, conNames (snd (field n))) | n <- M.keys newtypes]]
    arity n = length (diParams (newtypes M.! n))

    -- erase what can be; those still partially applied afterwards cannot be
    loop e =
      let p = eraseCons e (outermost (eraseT e) prog)
          bad = S.fromList [n | t <- goTypes p, n <- partial t, S.member n e]
       in if S.null bad then (e, p) else loop (e `S.difference` bad)

    partial = \case
      TCon c ts -> [c | M.member c newtypes, length ts < arity c] ++ concatMap partial ts
      TFun a b -> partial a ++ partial b
      TApp f x -> partial f ++ partial x
      _ -> []

    eraseT e = go
      where
        go = \case
          TCon c ts
            | S.member c e, length ts == arity c ->
                go (norm (substTV (M.fromList (zip (diParams (newtypes M.! c)) ts)) (snd (field c))))
          TCon c ts -> TCon c (map go ts)
          TFun a b -> TFun (go a) (go b)
          TApp f x -> tApp (go f) (go x)
          t -> t

    consOf e = S.fromList [fst (field n) | n <- S.toList e]

    eraseCons e p =
      let ks = consOf e
          expr = \case
            CApp (CCon k _ _) [a] | S.member k ks -> expr a
            CApp (CCon k _ _) (a : more) | S.member k ks -> CApp (expr a) more
            CCon k _ (TFun a r) | S.member k ks -> CLam [("_nt", a)] r (CVar "_nt" (Inst [] []) a)
            x -> x
          pat = \case
            CPCon k _ [q] | S.member k ks -> pat q
            q -> q
       in topDown pat (topDown expr p)

    finish (e, p) = p {progData = M.withoutKeys (progData p) e, progCons = M.withoutKeys (progCons p) (consOf e)}

conNames :: Type -> [Name]
conNames = \case
  TCon c ts -> c : concatMap conNames ts
  TFun a b -> conNames a ++ conNames b
  TApp f x -> conNames f ++ conNames x
  _ -> []

-- Generic traversals -------------------------------------------------------------

-- | Applies f to every outermost t, without looking inside the result.
outermost :: forall t a. (Data a, Typeable t) => (t -> t) -> a -> a
outermost f = go
  where
    go :: forall b. Data b => b -> b
    go x = case eqT @b @t of
      Just Refl -> f x
      Nothing -> gmapT go x

-- | Applies f to every t, from the outside in.
topDown :: forall t a. (Data a, Typeable t) => (t -> t) -> a -> a
topDown f = go
  where
    go :: forall b. Data b => b -> b
    go x = case eqT @b @t of
      Just Refl -> gmapT go (f x)
      Nothing -> gmapT go x

-- | Every outermost type that Go will see: those inside dictionaries, which
-- specialisation has already resolved, do not count.
goTypes :: forall a. Data a => a -> [Type]
goTypes = go
  where
    go :: forall b. Data b => b -> [Type]
    go x = case (eqT @b @Type, eqT @b @Dict) of
      (Just Refl, _) -> [x]
      (_, Just Refl) -> []
      _ -> concat (gmapQ go x)
