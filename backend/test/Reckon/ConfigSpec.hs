module Reckon.ConfigSpec (spec) where

import Reckon.Config
import Test.Hspec

spec :: Spec
spec = describe "configFromEnvironment" $ do
  let databaseUrlOnly = [("DATABASE_URL", "postgres://localhost/reckon")]

  it "requires DATABASE_URL" $
    configFromEnvironment [] `shouldBe` Left (MissingVariable "DATABASE_URL")

  it "treats an empty DATABASE_URL as missing" $
    configFromEnvironment [("DATABASE_URL", "")] `shouldBe` Left (MissingVariable "DATABASE_URL")

  it "defaults the port to 8080" $
    fmap (.port) (configFromEnvironment databaseUrlOnly) `shouldBe` Right 8080

  it "reads RECKON_PORT" $
    fmap (.port) (configFromEnvironment (("RECKON_PORT", "9000") : databaseUrlOnly)) `shouldBe` Right 9000

  it "rejects a RECKON_PORT that is not a number" $
    configFromEnvironment (("RECKON_PORT", "eighty") : databaseUrlOnly) `shouldBe` Left (InvalidPort "eighty")

  it "listens on the loopback address only, unless told otherwise" $ do
    fmap (.host) (configFromEnvironment databaseUrlOnly) `shouldBe` Right "127.0.0.1"
    fmap (.host) (configFromEnvironment (("RECKON_HOST", "0.0.0.0") : databaseUrlOnly)) `shouldBe` Right "0.0.0.0"

  it "only accepts requests addressed to localhost, unless told otherwise" $ do
    fmap (.allowedHosts) (configFromEnvironment databaseUrlOnly) `shouldBe` Right ["localhost", "127.0.0.1", "[::1]"]
    fmap (.allowedHosts) (configFromEnvironment (("RECKON_ALLOWED_HOSTS", "reckon.example.com, localhost,") : databaseUrlOnly))
      `shouldBe` Right ["reckon.example.com", "localhost"]

  it "rejects a RECKON_PORT outside the valid range" $
    configFromEnvironment (("RECKON_PORT", "70000") : databaseUrlOnly) `shouldBe` Left (InvalidPort "70000")
