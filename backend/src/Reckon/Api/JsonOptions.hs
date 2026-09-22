-- | Shared aeson options for every type the API sends or receives.
--
-- These live in their own module because Template Haskell splices can only
-- use definitions from other modules (GHC's "stage restriction"), and
-- "Reckon.Api.Types" uses them inside splices.
module Reckon.Api.JsonOptions
  ( recordOptions
  , enumOptions
  ) where

import Data.Aeson (Options (..), camelTo2, defaultOptions)
import Data.List (stripPrefix)
import Data.Maybe (fromMaybe)

-- | Records are encoded with their Haskell field names unchanged, so the
-- JSON (and the generated TypeScript) reads @databaseStatus@, not
-- @_databaseStatus@ or @health_database_status@.
recordOptions :: Options
recordOptions = defaultOptions

-- | Enums (sum types with no fields) are encoded as snake_case strings,
-- with a shared constructor prefix removed:
--
-- > enumOptions "Database"  -- DatabaseReachable  ~>  "reachable"
--
-- The prefix keeps constructor names unique across the codebase, while the
-- wire format stays short and matches the SQL enum values used later.
enumOptions :: String -> Options
enumOptions constructorPrefix =
  defaultOptions
    { constructorTagModifier = camelTo2 '_' . stripConstructorPrefix
    , allNullaryToStringTag = True
    }
  where
    stripConstructorPrefix constructorName =
      fromMaybe constructorName (stripPrefix constructorPrefix constructorName)
