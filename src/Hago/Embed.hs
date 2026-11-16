-- | Embeds a file's contents into the compiler at build time.
module Hago.Embed (embedFile) where

import Language.Haskell.TH (Exp, Q, runIO)
import Language.Haskell.TH.Syntax (addDependentFile, lift)

embedFile :: FilePath -> Q Exp
embedFile path = do
  addDependentFile path
  contents <- runIO (readFile path)
  lift contents
