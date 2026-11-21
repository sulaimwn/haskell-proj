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
import Data.Maybe (fromMaybe)
import Data.Text (Text)
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
  , host :: String
  -- ^ Address the server binds. Loopback by default: the API serves your
  -- financial data and has no login, so it must not be reachable from the
  -- network (DECISIONS D061).
  , allowedHosts :: [Text]
  -- ^ Host names a request may be addressed to (the @Host@ header). A page
  -- on another site can make your browser send requests to localhost, but
  -- can't make them carry a host name you didn't list (D061).
  }
  deriving stock (Show, Eq)

data ConfigError
  = MissingVariable String
  | InvalidPort String
  deriving stock (Show, Eq)

defaultPort :: Int
defaultPort = 8080

defaultHost :: String
defaultHost = "127.0.0.1"

defaultAllowedHosts :: [Text]
defaultAllowedHosts = ["localhost", "127.0.0.1", "[::1]"]

configFromEnvironment :: [(String, String)] -> Either ConfigError Config
configFromEnvironment environment = do
  databaseUrl <- maybe (Left (MissingVariable "DATABASE_URL")) Right (lookupNonEmpty "DATABASE_URL")
  port <- case lookupNonEmpty "RECKON_PORT" of
    Nothing -> Right defaultPort
    Just rawPort -> maybe (Left (InvalidPort rawPort)) Right (parsePort rawPort)
  let host = fromMaybe defaultHost (lookupNonEmpty "RECKON_HOST")
      allowedHosts = maybe defaultAllowedHosts (filter (not . Text.null) . map Text.strip . Text.splitOn "," . Text.pack) (lookupNonEmpty "RECKON_ALLOWED_HOSTS")
  pure Config {databaseUrl = Text.encodeUtf8 (Text.pack databaseUrl), port, host, allowedHosts}
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
