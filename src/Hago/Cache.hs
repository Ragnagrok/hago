{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# OPTIONS_GHC -Wno-orphans #-}

-- | Separate compilation: what compiling a module gives the modules after
-- it, kept on disk under a key made of the compiler, the module's source and
-- the keys of its imports. A module whose key has not changed is not renamed
-- or type checked again; specialisation and code generation still see the
-- whole program, as monomorphisation does in Rust.
module Hago.Cache (Iface (..), moduleKey, readIface, writeIface, cacheDirectory, compilerStamp) where

import Control.Exception (IOException, try)
import Data.Binary (Binary, decodeFileOrFail, encodeFile)
import Data.Binary.Get (ByteOffset)
import Data.Bits (xor)
import Data.Char (ord)
import qualified Data.Map as M
import Data.Word (Word64)
import GHC.Generics (Generic)
import Hago.Core
import Hago.Rename (Renamed (..), Table (..))
import Hago.Syntax
import Hago.TcMonad (InstHead (..), Record (..))
import Hago.Typecheck (Checked (..))
import Numeric (showHex)
import System.Directory (XdgDirectory (..), createDirectoryIfMissing, getFileSize, getModificationTime, getXdgDirectory, renameFile)
import System.Environment (getExecutablePath, lookupEnv)
import System.FilePath ((<.>), (</>))

-- | What compiling a module gives the modules after it: its names, type
-- synonyms and fixities, and its checked declarations.
data Iface = Iface
  { ifRenamed :: Renamed
  , ifSynonyms :: M.Map Name ([Name], SType)
  , ifFixities :: [(Name, (Assoc, Int))]
  , ifChecked :: Checked
  }
  deriving (Generic)

instance Semigroup Iface where
  a <> b = Iface (ifRenamed a <> ifRenamed b) (M.union (ifSynonyms a) (ifSynonyms b)) (ifFixities a ++ ifFixities b) (ifChecked a <> ifChecked b)

instance Monoid Iface where
  mempty = Iface mempty M.empty [] mempty

-- | A key for a module: FNV-1a over the compiler's stamp, the module's
-- source, and its imports' keys.
moduleKey :: String -> String -> [String] -> String
moduleKey stamp src deps = showHex (fnv (concat (stamp : "\0" : src : "\0" : deps))) ""
  where
    fnv :: String -> Word64
    fnv = foldl' (\h c -> (h `xor` fromIntegral (ord c)) * 1099511628211) 14695981039346656037

-- | Identifies the compiler binary, so a new compiler does not reuse what
-- an old one kept.
compilerStamp :: IO String
compilerStamp = do
  exe <- getExecutablePath
  r <- try (do
    t <- getModificationTime exe
    n <- getFileSize exe
    pure (show t ++ " " ++ show n)) :: IO (Either IOException String)
  pure (either (const "unknown") id r)

-- | $HAGO_CACHE, or the user's cache directory; Nothing turns caching off
-- (HAGO_CACHE=off).
cacheDirectory :: IO (Maybe FilePath)
cacheDirectory = lookupEnv "HAGO_CACHE" >>= \case
  Just "off" -> pure Nothing
  Just dir | not (null dir) -> pure (Just dir)
  _ -> Just <$> getXdgDirectory XdgCache "hago"

ifacePath :: FilePath -> Name -> String -> FilePath
ifacePath dir m key = dir </> (m ++ "-" ++ key) <.> "hgi"

readIface :: FilePath -> Name -> String -> IO (Maybe Iface)
readIface dir m key = do
  r <- try (decodeFileOrFail (ifacePath dir m key)) :: IO (Either IOException (Either (ByteOffset, String) Iface))
  pure $ case r of
    Right (Right iface) -> Just iface
    _ -> Nothing

-- | Writes through a temporary file, so a reader never sees half of one.
writeIface :: FilePath -> Name -> String -> Iface -> IO ()
writeIface dir m key iface = do
  -- a cache that cannot be written only makes the next compilation slower
  _ <- try (do
    createDirectoryIfMissing True dir
    let path = ifacePath dir m key
        tmp = path ++ ".tmp"
    encodeFile tmp iface
    renameFile tmp path) :: IO (Either IOException ())
  pure ()

-- Serialisation, derived ------------------------------------------------------------

deriving instance Generic Type
deriving instance Generic Pred
deriving instance Generic Scheme
deriving instance Generic Dict
deriving instance Generic VRef
deriving instance Generic CExpr
deriving instance Generic CBind
deriving instance Generic CRow
deriving instance Generic CPat
deriving instance Generic CStmt
deriving instance Generic ConInfo
deriving instance Generic DataInfo
deriving instance Generic Foreign
deriving instance Generic ClassInfo
deriving instance Generic InstInfo
deriving instance Generic TopBind
deriving instance Generic Lit
deriving instance Generic SType
deriving instance Generic Assoc
deriving instance Generic InstHead
deriving instance Generic Record
deriving instance Generic Checked
deriving instance Generic Table
deriving instance Generic Renamed

instance Binary Type
instance Binary Pred
instance Binary Scheme
instance Binary Dict
instance Binary VRef
instance Binary CExpr
instance Binary CBind
instance Binary CRow
instance Binary CPat
instance Binary CStmt
instance Binary ConInfo
instance Binary DataInfo
instance Binary Foreign
instance Binary ClassInfo
instance Binary InstInfo
instance Binary TopBind
instance Binary Lit
instance Binary SType
instance Binary Assoc
instance Binary InstHead
instance Binary Record
instance Binary Checked
instance Binary Table
instance Binary Renamed
instance Binary Iface
