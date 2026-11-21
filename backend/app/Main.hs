module Main (main) where

import Data.Function ((&))
import Data.String (fromString)
import Data.Text qualified as Text
import Network.Wai.Handler.Warp (defaultSettings, runSettings, setBeforeMainLoop, setHost, setPort)
import Network.Wai.Middleware.RequestLogger (logStdout)
import Reckon.Anthropic (AnthropicConfig (..), ScreenshotReading (..), anthropicExtractor, loadAnthropicConfig)
import Reckon.App (AppEnv (..))
import Reckon.Config (Config (..), loadConfig)
import Reckon.Database (createDatabasePool)
import Reckon.Server (application)

-- | Enough for one user; raise it if concurrent imports ever queue up.
databasePoolSize :: Int
databasePoolSize = 5

main :: IO ()
main = do
  config <- loadConfig
  databasePool <- createDatabasePool config.databaseUrl databasePoolSize
  -- Screenshots can only be read when ANTHROPIC_API_KEY is set. The server
  -- starts either way; the import endpoint says why when it can't.
  screenshotReading <-
    loadAnthropicConfig >>= \case
      Left why -> pure (ReadingUnavailable why)
      Right anthropic -> ReadingAvailable anthropic.model <$> anthropicExtractor anthropic
  let env = AppEnv {config, databasePool, screenshotReading}
      settings =
        defaultSettings
          & setHost (fromString config.host)
          & setPort config.port
          & setBeforeMainLoop (putStrLn ("reckon-server listening on http://" <> config.host <> ":" <> show config.port))
  case screenshotReading of
    ReadingAvailable model _ -> putStrLn ("Screenshots will be read by " <> Text.unpack model)
    ReadingUnavailable _ -> putStrLn "ANTHROPIC_API_KEY is not set: screenshots can't be read (everything else works)."
  -- Apache-style: method, path, status. Not logStdoutDev, which prints small
  -- request bodies, i.e. a small CSV upload would end up in the terminal.
  runSettings settings (logStdout (application env))
