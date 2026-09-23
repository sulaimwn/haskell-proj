-- | Command-line tools for working with a local reckon database.
--
-- Usage:
--   reckon-cli import-rbc-csv FILE    (or: make import file=private/export.csv)
module Main (main) where

import Data.ByteString qualified as ByteString
import Data.Text qualified as Text
import Data.Text.IO qualified as Text
import Database.Persist.Sql (runSqlPool)
import Reckon.Config (Config (..), loadConfig)
import Reckon.Database (createDatabasePool)
import Reckon.Import (importRbcCsv, renderImportError, renderImportOutcome)
import System.Environment (getArgs)
import System.Exit (die, exitFailure)
import System.FilePath (takeFileName)

main :: IO ()
main = do
  arguments <- getArgs
  case arguments of
    ["import-rbc-csv", path] -> importFile path
    _ -> die "Usage: reckon-cli import-rbc-csv FILE"

importFile :: FilePath -> IO ()
importFile path = do
  config <- loadConfig
  pool <- createDatabasePool config.databaseUrl 1
  fileBytes <- ByteString.readFile path
  -- One transaction: the whole file is imported, or nothing is.
  result <- runSqlPool (importRbcCsv (Text.pack (takeFileName path)) fileBytes) pool
  case result of
    Right outcome -> Text.putStr (renderImportOutcome outcome)
    Left importError -> Text.putStr (renderImportError importError) >> exitFailure
