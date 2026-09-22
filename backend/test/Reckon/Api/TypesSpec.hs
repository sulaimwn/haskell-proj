module Reckon.Api.TypesSpec (spec) where

import Data.Aeson (decode, encode, object, toJSON, (.=))
import Data.Text (Text)
import Data.Text qualified as Text
import Reckon.Api.TypeScript (renderTypeScriptModule)
import Reckon.Api.Types
import Test.Hspec

spec :: Spec
spec = do
  describe "HealthResponse JSON" $ do
    -- This is the wire contract the frontend depends on. If this test has
    -- to change, the generated TypeScript changes too.
    it "uses the Haskell field names and snake_case enum strings" $
      toJSON (HealthResponse DatabaseReachable "1.2.3")
        `shouldBe` object
          [ "databaseStatus" .= ("reachable" :: Text)
          , "serverVersion" .= ("1.2.3" :: Text)
          ]

    it "round-trips through JSON for every database status" $
      mapM_
        (\response -> decode (encode response) `shouldBe` Just response)
        [ HealthResponse DatabaseReachable "1.2.3"
        , HealthResponse DatabaseUnreachable "1.2.3"
        ]

  describe "generated TypeScript" $ do
    it "declares enums as unions of the same strings the JSON uses" $
      renderTypeScriptModule `shouldSatisfy` Text.isInfixOf "export type DatabaseStatus = \"reachable\" | \"unreachable\";"

    -- aeson-typescript always emits a record as `interface I<Name>` plus
    -- `type <Name> = I<Name>`. Frontend code uses the plain <Name>.
    it "declares records as interfaces with the same field names the JSON uses" $ do
      renderTypeScriptModule `shouldSatisfy` Text.isInfixOf "export type HealthResponse = IHealthResponse;"
      renderTypeScriptModule `shouldSatisfy` Text.isInfixOf "export interface IHealthResponse {"
      renderTypeScriptModule `shouldSatisfy` Text.isInfixOf "databaseStatus: DatabaseStatus;"
      renderTypeScriptModule `shouldSatisfy` Text.isInfixOf "serverVersion: string;"
