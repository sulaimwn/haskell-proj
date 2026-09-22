-- | The environment every request handler can read, and the monad handlers
-- run in.
module Reckon.App
  ( AppEnv (..)
  , AppM
  , runAppM
  ) where

import Control.Monad.Reader (ReaderT, runReaderT)
import Database.Persist.Postgresql (ConnectionPool)
import Reckon.Config (Config)
import Servant (Handler)

-- | Built once at startup and shared by every request.
data AppEnv = AppEnv
  { config :: Config
  , databasePool :: ConnectionPool
  }

-- | The monad handlers run in: they can read 'AppEnv' (@ReaderT@), and can
-- fail with an HTTP error or do IO (servant's 'Handler').
--
-- This is the "ReaderT pattern": shared, read-only dependencies are passed
-- implicitly instead of threaded through every function as arguments.
type AppM = ReaderT AppEnv Handler

-- | Turns an 'AppM' action into a plain servant 'Handler' by supplying the
-- environment. Servant's @hoistServer@ applies this to every handler.
runAppM :: AppEnv -> AppM a -> Handler a
runAppM env action = runReaderT action env
