module Reckon.ServerSpec (spec) where

import Data.Aeson (eitherDecode)
import Reckon.Api.Types (DatabaseStatus (..), HealthResponse (..))
import Reckon.Server (application, reckonVersion)
import Reckon.TestSupport (makeEnvWithUnreachableDatabase, makeTestEnv)
import Test.Hspec
import Test.Hspec.Wai

spec :: Spec
spec = describe "GET /api/health" $ do
  describe "when the database is reachable" $
    with (application <$> makeTestEnv) $
      it "responds 200 and reports the database as reachable" $
        get "/api/health" `shouldRespondWith` healthResponse DatabaseReachable

  -- The health endpoint must answer even when Postgres is down; that is the
  -- whole point of it.
  describe "when the database is unreachable" $
    with (application <$> makeEnvWithUnreachableDatabase) $
      it "still responds 200 and reports the database as unreachable" $
        get "/api/health" `shouldRespondWith` healthResponse DatabaseUnreachable

  describe "unknown routes" $
    with (application <$> makeEnvWithUnreachableDatabase) $
      it "respond 404" $
        get "/api/does-not-exist" `shouldRespondWith` 404
  where
    healthResponse databaseStatus =
      ResponseMatcher
        { matchStatus = 200
        , matchHeaders = ["Content-Type" <:> "application/json;charset=utf-8"]
        , matchBody = jsonBodyIs HealthResponse {databaseStatus, serverVersion = reckonVersion}
        }

-- | Decodes the body and compares values, so the failure message shows the
-- two 'HealthResponse's rather than two byte strings.
jsonBodyIs :: HealthResponse -> MatchBody
jsonBodyIs expected = MatchBody $ \_headers body ->
  case eitherDecode body of
    Left decodeError -> Just ("body is not a HealthResponse: " <> decodeError)
    Right actual
      | actual == expected -> Nothing
      | otherwise -> Just ("expected " <> show expected <> "\n but got " <> show actual)
