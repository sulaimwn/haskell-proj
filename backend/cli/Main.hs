-- | Command-line tools for a local reckon database. Each command runs in one
-- transaction: it happens completely, or not at all.
--
-- Run through @scripts/reckon.sh COMMAND ...@ (or the Makefile shortcuts).
module Main (main) where

import Data.ByteString qualified as ByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text
import Data.Time (Day)
import Data.Time.Format.ISO8601 (iso8601ParseM)
import Database.Persist (Entity)
import Database.Persist.Sql (ConnectionPool, SqlPersistT, runSqlPool, toSqlKey)
import Reckon.Bank (Last4, mkLast4)
import Reckon.Config (Config (..), loadConfig)
import Reckon.Database (createDatabasePool)
import Reckon.Database.Schema (BankAccount)
import Reckon.Import (importRbcCsv, renderImportError, renderImportOutcome)
import Reckon.Import.RbcCsv (parseCents)
import Reckon.Money (Cents, renderCents)
import Reckon.Posting (ManualPostingError (..), RuleError (..), addCategorizationRule, postPendingRows, postRowManually, renderPostingSummary)
import Reckon.Reconcile
import System.Environment (getArgs)
import System.Exit (die, exitFailure)
import System.FilePath (takeFileName)
import Text.Read (readMaybe)

usage :: String
usage =
  unlines
    [ "Usage: scripts/reckon.sh COMMAND"
    , ""
    , "  import-rbc-csv FILE                    import an RBC CSV export (make import file=...)"
    , "  post                                   post imported rows to the journal (make post)"
    , "  post-row ROW_ID ACCOUNT                settle a row left for review, e.g. post-row 42 asset:clearing"
    , "  add-rule TEXT ACCOUNT [PRIORITY]       e.g. add-rule \"TIM HORTONS\" expense:coffee"
    , "  opening-balance LAST4 DATE AMOUNT      balance before your first import, e.g. 1234 2025-12-31 1520.35"
    , "  checkpoint LAST4 DATE AMOUNT           a statement's closing balance; prints the reconciliation"
    , "  reconcile                              reconcile every recorded checkpoint (make reconcile)"
    , ""
    , "Dates are YYYY-MM-DD. Amounts are as the statement shows them (money in the"
    , "account, or owed on a card), e.g. 1520.35 or -12.00."
    ]

main :: IO ()
main = do
  arguments <- getArgs
  case arguments of
    ["import-rbc-csv", path] -> withDatabase (importFile path)
    ["post"] -> withDatabase (\pool -> runSqlPool postPendingRows pool >>= Text.putStr . renderPostingSummary)
    ["post-row", rowIdText, accountName] -> case readMaybe rowIdText of
      Nothing -> die ("ROW_ID must be the number shown by make post, got " <> show rowIdText)
      Just rowNumber -> withDatabase $ \pool -> runOrDie pool $ do
        result <- postRowManually (toSqlKey rowNumber) (Text.pack accountName)
        pure $ case result of
          Right () -> Right ("Posted row #" <> Text.pack rowIdText <> " against " <> Text.pack accountName <> ".")
          Left RowNotFound -> Left ("There's no imported row #" <> Text.pack rowIdText <> ".")
          Left RowAlreadyPosted -> Left ("Row #" <> Text.pack rowIdText <> " is already posted.")
          Left ZeroAmountRow -> Left "A zero-amount row can't be posted."
          Left (UnknownAccount name) ->
            Left ("\"" <> name <> "\" must start with expense:, income:, asset:, liability:, receivable: or equity:")
    ["add-rule", ruleText, accountName] -> withDatabase (addRule ruleText accountName 100)
    ["add-rule", ruleText, accountName, priorityText] -> case readMaybe priorityText of
      Just priority -> withDatabase (addRule ruleText accountName priority)
      Nothing -> die ("PRIORITY must be a whole number, got " <> show priorityText)
    ["opening-balance", last4Text, dateText, amountText] -> do
      (last4, date, amount) <- parseAccountDateAmount last4Text dateText amountText
      withDatabase $ \pool -> runOrDie pool $ withBankAccount last4 $ \account -> do
        result <- recordOpeningBalance account date amount
        pure $ case result of
          Right _ -> Right ("Recorded an opening balance of " <> renderCents amount <> " at the end of " <> showText date <> ".")
          Left (OpeningBalanceNotBeforeFirstTransaction firstDate) ->
            Left
              ( "The opening balance must be from before your first imported transaction ("
                  <> showText firstDate
                  <> "), or that transaction would be counted twice. Use a statement balance from an earlier date."
              )
          Left ZeroOpeningBalance -> Left "A zero opening balance doesn't need recording."
    ["checkpoint", last4Text, dateText, amountText] -> do
      (last4, date, amount) <- parseAccountDateAmount last4Text dateText amountText
      withDatabase $ \pool -> runOrDie pool $ withBankAccount last4 $ \account -> do
        result <- recordCheckpoint account date amount
        case result of
          Left (CheckpointAlreadyRecorded existingDate) ->
            pure (Left ("A checkpoint for " <> showText existingDate <> " is already recorded. Run: scripts/reckon.sh reconcile"))
          Right _ -> Right . renderReconciliationReport <$> reconcileAccount account date amount
    ["reconcile"] -> withDatabase $ \pool -> do
      reports <- runSqlPool reconcileAllCheckpoints pool
      case reports of
        [] -> putStrLn "No statement checkpoints recorded yet. Add one with: scripts/reckon.sh checkpoint LAST4 DATE AMOUNT"
        _ -> mapM_ (Text.putStrLn . renderReconciliationReport) reports
    _ -> die usage

withDatabase :: (ConnectionPool -> IO ()) -> IO ()
withDatabase action = do
  config <- loadConfig
  pool <- createDatabasePool config.databaseUrl 1
  action pool

-- | Runs a transaction that either succeeds with a message to print, or
-- fails with one (and exits non-zero).
runOrDie :: ConnectionPool -> SqlPersistT IO (Either Text Text) -> IO ()
runOrDie pool action = do
  result <- runSqlPool action pool
  case result of
    Right message -> Text.putStrLn message
    Left problem -> Text.putStrLn ("error: " <> problem) >> exitFailure

withBankAccount :: Last4 -> (Entity BankAccount -> SqlPersistT IO (Either Text Text)) -> SqlPersistT IO (Either Text Text)
withBankAccount last4 continue = do
  found <- findBankAccountByLast4 last4
  either (pure . Left) continue found

importFile :: FilePath -> ConnectionPool -> IO ()
importFile path pool = do
  fileBytes <- ByteString.readFile path
  result <- runSqlPool (importRbcCsv (Text.pack (takeFileName path)) fileBytes) pool
  case result of
    Right outcome -> Text.putStr (renderImportOutcome outcome) >> putStrLn "Next: make post"
    Left importError -> Text.putStr (renderImportError importError) >> exitFailure

addRule :: String -> String -> Int -> ConnectionPool -> IO ()
addRule ruleText accountName priority pool = runOrDie pool $ do
  result <- addCategorizationRule (Text.pack ruleText) (Text.pack accountName) priority
  pure $ case result of
    Right _ ->
      Right
        ( "Added: descriptions containing \"" <> Text.toUpper (Text.pack ruleText) <> "\" go to " <> Text.pack accountName
            <> ". It applies to rows posted from now on."
        )
    Left EmptyRuleText -> Left "The rule text is empty."
    Left (RuleAlreadyExists existing) -> Left ("A rule for \"" <> existing <> "\" already exists.")
    Left (UnknownAccountPrefix name) ->
      Left ("\"" <> name <> "\" must start with expense:, income:, asset:, liability:, receivable: or equity:")

parseAccountDateAmount :: String -> String -> String -> IO (Last4, Day, Cents)
parseAccountDateAmount last4Text dateText amountText = do
  last4 <- maybe (die ("LAST4 must be the last 4 digits of the account number, got " <> show last4Text)) pure (mkLast4 (Text.pack last4Text))
  date <- maybe (die ("DATE must look like 2026-01-31, got " <> show dateText)) pure (iso8601ParseM dateText)
  amount <- either (\problem -> die ("AMOUNT " <> Text.unpack problem)) pure (parseCents (Text.pack amountText))
  pure (last4, date, amount)

showText :: (Show a) => a -> Text
showText = Text.pack . show
