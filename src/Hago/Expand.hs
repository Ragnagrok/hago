{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- | Type synonyms, expanded away after renaming: the rest of the compiler
-- never sees them. A synonym must be given all its parameters, and a
-- synonym that refers to itself, directly or not, is an error.
module Hago.Expand (Synonyms, expandSynonyms, synonymsOf) where

import Control.Monad
import Data.Data (Data, gmapM)
import Data.Graph (SCC (..), stronglyConnComp)
import Data.List (intercalate, nub)
import qualified Data.Map as M
import Data.Type.Equality ((:~:) (..))
import Data.Typeable (eqT)
import Hago.Syntax

type Synonyms = M.Map Name ([Name], SType)

-- | The synonyms a module declares.
synonymsOf :: [Decl] -> Synonyms
synonymsOf ds = M.fromList [(n, (ps, t)) | DType n ps t <- ds]

-- | Expands a module's synonyms, and those of the modules before it.
expandSynonyms :: Synonyms -> [Decl] -> Either String [Decl]
expandSynonyms before ds = do
  let syns = M.union (synonymsOf ds) before
  forM_ (stronglyConnComp [(n, n, conNames t) | (n, (_, t)) <- M.toList syns]) $ \case
    CyclicSCC ns -> Left ("type synonyms cannot refer to themselves: " ++ intercalate ", " (map unqual ns))
    AcyclicSCC _ -> pure ()
  forM [d | d <- ds, not (isSynonym d)] $ \d ->
    either (Left . ((where_ d ++ ": ") ++)) Right (onTypes (expand syns) d)
  where
    isSynonym = \case
      DType {} -> True
      _ -> False
    where_ = \case
      DData d -> showLoc (ddLoc d) ++ ": in type " ++ unqual (ddName d)
      DSig ns _ _ -> "in " ++ intercalate ", " (map unqual ns)
      DBind n _ -> "in " ++ unqual n
      DClass _ c _ _ _ -> "in class " ++ unqual c
      DInstance l _ c _ _ -> maybe "" ((++ ": ") . showLoc) l ++ "in instance " ++ unqual c
      DForeign _ n _ -> "in " ++ unqual n
      _ -> "in a declaration"

conNames :: SType -> [Name]
conNames = nub . go
  where
    go = \case
      STCon c ts -> c : concatMap go ts
      STFun a b -> go a ++ go b
      STApp h ts -> go h ++ concatMap go ts
      STVar _ -> []

-- | Rewrites every type inside a declaration, signatures in expressions included.
onTypes :: forall a. Data a => (SType -> Either String SType) -> a -> Either String a
onTypes f = go
  where
    go :: forall b. Data b => b -> Either String b
    go x = case eqT @b @SType of
      Just Refl -> f x
      Nothing -> gmapM go x

expand :: Synonyms -> SType -> Either String SType
expand syns = go
  where
    go = \case
      STVar v -> pure (STVar v)
      STFun a b -> STFun <$> go a <*> go b
      STApp h ts -> applyTo <$> go h <*> mapM go ts
      STCon c ts -> do
        ts' <- mapM go ts
        case M.lookup c syns of
          Nothing -> pure (STCon c ts')
          Just (ps, body)
            | length ts' < length ps ->
                Left ("the type synonym " ++ unqual c ++ " needs " ++ show (length ps) ++ " argument(s), and is given " ++ show (length ts'))
            | otherwise -> do
                let (now, extra) = splitAt (length ps) ts'
                b <- go (subst (M.fromList (zip ps now)) body)
                pure (applyTo b extra)

subst :: M.Map Name SType -> SType -> SType
subst s = \case
  STVar v -> M.findWithDefault (STVar v) v s
  STFun a b -> STFun (subst s a) (subst s b)
  STApp h ts -> applyTo (subst s h) (map (subst s) ts)
  STCon c ts -> STCon c (map (subst s) ts)

applyTo :: SType -> [SType] -> SType
applyTo h [] = h
applyTo (STCon c xs) ys = STCon c (xs ++ ys)
applyTo (STApp h xs) ys = STApp h (xs ++ ys)
applyTo h ys = STApp h ys
