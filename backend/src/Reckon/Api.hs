-- | The HTTP API, described as a type.
--
-- Servant reads this type to route requests, decode inputs and encode
-- outputs, so a handler that returns the wrong type does not compile. Routes
-- are grouped in a record ('Routes') rather than chained with @:<|>@, so each
-- endpoint has a name and handlers are matched to routes by field name.
module Reckon.Api
  ( Api
  , Routes (..)
  ) where

import GHC.Generics (Generic)
import Reckon.Api.Types (HealthResponse)
import Servant.API

-- | Everything lives under @/api@, so the frontend dev server only has to
-- proxy one path prefix to the backend.
type Api = "api" :> NamedRoutes Routes

data Routes mode = Routes
  { health :: mode :- "health" :> Get '[JSON] HealthResponse
  -- ^ Liveness plus a database round trip. Used by the frontend status badge.
  }
  deriving stock (Generic)
