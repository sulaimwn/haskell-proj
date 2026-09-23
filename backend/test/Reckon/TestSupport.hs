-- | Helpers shared by specs that need a database or a running application.
module Reckon.TestSupport
  ( makeTestEnv
  , makeEnvWithUnreachableDatabase
  , runTestDatabase
  , uniqueSuffix
  , shouldFailMentioning
  ) where

import Control.Exception (SomeException, try)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as ByteString.Char8
import Data.Text (Text)
import Database.Persist.Sql (Single (..), SqlPersistT, rawSql, runSqlPool)
import Reckon.App (AppEnv (..))
import Reckon.Config (Config (..))
import Reckon.Database (createDatabasePool)
import System.Environment (lookupEnv)
import Test.Hspec (Expectation, expectationFailure, shouldContain)

-- | Runs a database action in its own transaction, committed at the end,
-- the same way the application does.
runTestDatabase :: AppEnv -> SqlPersistT IO a -> IO a
runTestDatabase env action = runSqlPool action env.databasePool

-- | A string no other test has used. The journal is append-only, so tests
-- can't clean up after themselves. Instead, every test names its accounts
-- with a fresh suffix and only looks at those accounts.
uniqueSuffix :: SqlPersistT IO Text
uniqueSuffix = do
  [Single suffix] <- rawSql "SELECT replace(gen_random_uuid()::text, '-', '')" []
  pure suffix

-- | Expects the action to throw, with the given text in the error. Used to
-- check that the database rejects something, and for the right reason.
shouldFailMentioning :: IO a -> String -> Expectation
shouldFailMentioning action expectedFragment = do
  result <- try @SomeException action
  case result of
    Left exception -> show exception `shouldContain` expectedFragment
    Right _ -> expectationFailure ("expected an error mentioning " <> show expectedFragment <> ", but it succeeded")

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
