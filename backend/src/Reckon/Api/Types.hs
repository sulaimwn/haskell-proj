{-# LANGUAGE TemplateHaskell #-}

-- | Every type that crosses the HTTP boundary.
--
-- Each type gets its JSON instances and its TypeScript declaration from the
-- same Template Haskell splice ('deriveJSONAndTypeScript'), using the same
-- options. That is what keeps the frontend's types and the backend's JSON
-- from drifting apart: the TypeScript is generated from this module by
-- @reckon-codegen@, never written by hand.
--
-- To add an API type: define it here, add a splice for it, and add it to
-- 'typeScriptDeclarations'. Then run @make codegen@.
module Reckon.Api.Types
  ( HealthResponse (..)
  , DatabaseStatus (..)
  , typeScriptDeclarations
  ) where

import Data.Aeson.TypeScript.TH (TSDeclaration, deriveJSONAndTypeScript, getTypeScriptDeclarations)
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import Reckon.Api.JsonOptions (enumOptions, recordOptions)

-- | Whether the server could run a trivial query against Postgres.
data DatabaseStatus
  = DatabaseReachable
  | DatabaseUnreachable
  deriving stock (Show, Eq)

-- | Response of @GET /api/health@.
data HealthResponse = HealthResponse
  { databaseStatus :: DatabaseStatus
  , serverVersion :: Text
  }
  deriving stock (Show, Eq)

$(deriveJSONAndTypeScript (enumOptions "Database") ''DatabaseStatus)
$(deriveJSONAndTypeScript recordOptions ''HealthResponse)

-- | The TypeScript declarations for every API type, in the order they are
-- written to @frontend/src/api/generated.ts@.
typeScriptDeclarations :: [TSDeclaration]
typeScriptDeclarations =
  mconcat
    [ getTypeScriptDeclarations (Proxy @HealthResponse)
    , getTypeScriptDeclarations (Proxy @DatabaseStatus)
    ]
