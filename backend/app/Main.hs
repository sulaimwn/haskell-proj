module Main (main) where

import Data.Function ((&))
import Network.Wai.Handler.Warp (defaultSettings, runSettings, setBeforeMainLoop, setPort)
import Network.Wai.Middleware.RequestLogger (logStdoutDev)
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
  let env = AppEnv {config, databasePool}
      settings =
        defaultSettings
          & setPort config.port
          & setBeforeMainLoop (putStrLn ("reckon-server listening on http://localhost:" <> show config.port))
  runSettings settings (logStdoutDev (application env))
