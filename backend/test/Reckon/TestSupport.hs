-- | Helpers shared by specs that need a database or a running application.
module Reckon.TestSupport
  ( makeTestEnv
  , makeEnvWithUnreachableDatabase
  ) where

import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as ByteString.Char8
import Reckon.App (AppEnv (..))
import Reckon.Config (Config (..))
import Reckon.Database (createDatabasePool)
import System.Environment (lookupEnv)

-- | An environment connected to the test database named by
-- @TEST_DATABASE_URL@. @make test@ creates and migrates that database.
--
-- If the variable is missing, the test fails loudly instead of being
-- skipped: a database test that silently doesn't run is worse than useless.
makeTestEnv :: IO AppEnv
makeTestEnv = do
  maybeUrl <- lookupEnv "TEST_DATABASE_URL"
  case maybeUrl of
    Just url | not (null url) -> makeEnvFor (ByteString.Char8.pack url)
    _ ->
      fail
        "TEST_DATABASE_URL is not set. Run the tests with `make test`, which starts \
        \and migrates the test database and sets this variable."

-- | An environment whose pool points at a port nothing listens on.
makeEnvWithUnreachableDatabase :: IO AppEnv
makeEnvWithUnreachableDatabase =
  makeEnvFor "postgresql://reckon:reckon@127.0.0.1:1/reckon?connect_timeout=1"

makeEnvFor :: ByteString -> IO AppEnv
makeEnvFor url = do
  databasePool <- createDatabasePool url 1
  pure AppEnv {config = Config {databaseUrl = url, port = 0}, databasePool}
