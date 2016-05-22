{-# LANGUAGE OverloadedStrings, DeriveGeneric, DeriveAnyClass #-}

module ProjectInfo
    ( ProjectInfo(..)
    , emptyProjectInfo
    , prettyConfig
    ) where

import GHC.Generics
import qualified Data.Aeson as A
import qualified Data.Aeson.Encode.Pretty as AP

import Data.Text (Text)

data ProjectInfo = ProjectInfo {
      name              :: Text -- ^ Name of the haskell package
    , version           :: Text -- ^ Its version
    , synopsis          :: Text
    , description       :: Text
    , pkgconfigDepends  :: Text
    , giDepends         :: [Text] -- ^ dependencies on other
                                  -- haskell-gi generated modules.
    , baseVersion       :: Text -- ^ Constraint on base for this module.

    , girName           :: Text         -- ^ GIR file (without version)
    , girVersion        :: Text         -- ^ Its version
    , girOverrides      :: Maybe Text   -- ^ Possibly an overrides file
    } deriving (Show, Generic, A.ToJSON, A.FromJSON)

emptyProjectInfo :: ProjectInfo
emptyProjectInfo = ProjectInfo {
                     name = error "name missing"
                   , version = error "version missing"
                   , synopsis = error "synopsis missing"
                   , description = error "description missing"
                   , pkgconfigDepends = error "pkgconfigDepends missing"
                   , giDepends = []
                   , baseVersion = error "baseVersion missing"
                   , girName = error "girName missing"
                   , girVersion = error "girVersion missing"
                   , girOverrides = error "girOverrides missing"
                   }

prettyConfig :: AP.Config
prettyConfig = AP.Config { AP.confIndent = 4
                         , AP.confCompare = AP.keyOrder
                           ["name", "version", "description", "synopsis",
                            "girName", "girVersion",
                            "girOverrides", "pkgConfig", "depends",
                            "baseVersion"]}
