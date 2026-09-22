-- | Runtime configuration, read from environment variables at startup.
--
-- Parsing is a pure function over a list of variables ('configFromEnvironment'),
-- so it can be tested without touching the real process environment. Only
-- 'loadConfig' does IO.
module Reckon.Config
  ( Config (..)
  , ConfigError (..)
  , configFromEnvironment
  , loadConfig
  , renderConfigError
  ) where

import Data.ByteString (ByteString)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import System.Environment (getEnvironment)
import System.Exit (die)
import Text.Read (readMaybe)

data Config = Config
  { databaseUrl :: ByteString
  -- ^ libpq connection string, e.g. @postgres://user:pass\@localhost:5433/reckon@.
  , port :: Int
  -- ^ Port the HTTP server listens on.
  }
  deriving stock (Show, Eq)

data ConfigError
  = MissingVariable String
  | InvalidPort String
  deriving stock (Show, Eq)

defaultPort :: Int
defaultPort = 8080

configFromEnvironment :: [(String, String)] -> Either ConfigError Config
configFromEnvironment environment = do
  databaseUrl <- maybe (Left (MissingVariable "DATABASE_URL")) Right (lookupNonEmpty "DATABASE_URL")
  port <- case lookupNonEmpty "RECKON_PORT" of
    Nothing -> Right defaultPort
    Just rawPort -> maybe (Left (InvalidPort rawPort)) Right (parsePort rawPort)
  pure Config {databaseUrl = Text.encodeUtf8 (Text.pack databaseUrl), port}
  where
    lookupNonEmpty name = case lookup name environment of
      Just value | not (null value) -> Just value
      _ -> Nothing

    parsePort rawPort = case readMaybe rawPort of
      Just parsedPort | parsedPort > 0 && parsedPort < 65536 -> Just parsedPort
      _ -> Nothing

renderConfigError :: ConfigError -> String
renderConfigError = \case
  MissingVariable name ->
    name <> " is not set. Copy .env.example to .env, or start the app with `make dev`, which loads .env for you."
  InvalidPort rawPort ->
    "RECKON_PORT must be a port number between 1 and 65535, got: " <> show rawPort

-- | Reads the configuration from the process environment, exiting with a
-- readable message if something is missing or malformed.
loadConfig :: IO Config
loadConfig = do
  environment <- getEnvironment
  either (die . renderConfigError) pure (configFromEnvironment environment)
