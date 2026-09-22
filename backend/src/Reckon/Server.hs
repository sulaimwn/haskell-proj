-- | Request handlers, and the WAI 'Application' that serves them.
module Reckon.Server
  ( application
  , server
  , reckonVersion
  ) where

import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (asks)
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Version (showVersion)
import Network.Wai (Application)
import Paths_reckon qualified
import Reckon.Api (Api, Routes (..))
import Reckon.Api.Types (HealthResponse (..))
import Reckon.App (AppEnv (..), AppM, runAppM)
import Reckon.Database (pingDatabase)
import Servant.Server (hoistServer, serve)
import Servant.Server.Generic (AsServerT)

-- | One handler per field of 'Routes'. A missing or mistyped handler is a
-- compile error.
server :: Routes (AsServerT AppM)
server =
  Routes
    { health = getHealth
    }

getHealth :: AppM HealthResponse
getHealth = do
  pool <- asks (.databasePool)
  databaseStatus <- liftIO (pingDatabase pool)
  pure HealthResponse {databaseStatus, serverVersion = reckonVersion}

-- | The version from @reckon.cabal@.
reckonVersion :: Text
reckonVersion = Text.pack (showVersion Paths_reckon.version)

application :: AppEnv -> Application
application env = serve api (hoistServer api (runAppM env) server)
  where
    api = Proxy @Api
