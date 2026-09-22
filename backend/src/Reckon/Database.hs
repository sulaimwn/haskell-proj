-- | Connecting to Postgres.
--
-- The schema is owned by the SQL migrations in @db/migrations@ (applied by
-- dbmate), not by persistent. Nothing in the backend runs persistent's
-- auto-migration.
module Reckon.Database
  ( createDatabasePool
  , pingDatabase
  ) where

import Control.Monad.Logger (LogLevel (..), filterLogger, runStdoutLoggingT)
import Data.ByteString (ByteString)
import Database.Persist.Postgresql (ConnectionPool, Single (..), createPostgresqlPool, rawSql, runSqlPool)
import Reckon.Api.Types (DatabaseStatus (..))
import UnliftIO.Exception (tryAny)
import UnliftIO.Timeout (timeout)

-- | Creates a pool of Postgres connections. Connections are opened lazily,
-- the first time a query needs one, so the server can start even while the
-- database is still booting.
--
-- persistent logs every SQL statement at debug level; only warnings and
-- errors are printed.
createDatabasePool :: ByteString -> Int -> IO ConnectionPool
createDatabasePool connectionString poolSize =
  runStdoutLoggingT . filterLogger (\_source level -> level >= LevelWarn) $
    createPostgresqlPool connectionString poolSize

-- | Runs @SELECT 1@. Any failure (refused connection, bad credentials,
-- timeout) counts as unreachable rather than crashing the request.
pingDatabase :: ConnectionPool -> IO DatabaseStatus
pingDatabase pool = do
  result <- timeout pingTimeoutMicroseconds (tryAny (runSqlPool selectOne pool))
  pure $ case result of
    Just (Right [Single (1 :: Int)]) -> DatabaseReachable
    _ -> DatabaseUnreachable
  where
    selectOne = rawSql "SELECT 1" []
    pingTimeoutMicroseconds = 2 * 1000 * 1000
