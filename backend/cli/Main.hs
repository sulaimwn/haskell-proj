-- | Command-line tools for a local reckon database. Each command runs in one
-- transaction: it happens completely, or not at all.
--
-- Run through @scripts/reckon.sh COMMAND ...@ (or the Makefile shortcuts).
module Main (main) where

import Data.ByteString qualified as ByteString
import Data.Int (Int64)
import Data.Text (Text)
import Data.Char (toLower)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text
import Data.Time (Day, getCurrentTime, utctDay)
import Data.Time.Format.ISO8601 (iso8601ParseM)
import Database.Persist (Entity)
import Database.Persist.Sql (ConnectionPool, SqlPersistT, runSqlPool, toSqlKey)
import Reckon.Bank (Last4, mkLast4)
import Reckon.Anthropic (AnthropicConfig (..), anthropicExtractor, loadAnthropicConfig)
import Reckon.Config (Config (..), loadConfig)
import Reckon.Database (createDatabasePool)
import Reckon.Database.Schema (BankAccount)
import Reckon.Import (importRbcCsv, renderImportError, renderImportOutcome)
import Reckon.Import.RbcCsv (parseCents)
import Reckon.Money (Cents, renderCents)
import Reckon.Messages (describeCheckpointError, describeOpeningBalanceError, describePersonError, describePostingError, describeReleaseError, describeRuleError, describeSplitRowError)
import Reckon.People (addPerson, renderOwed, whoOwesWhat)
import Reckon.Posting (postPendingRows, postRowManually, recategorizeRow, renderPostingSummary)
import Reckon.Rules (StoredRule (..), addContainsRule, addRule, checkRule, deleteRule, loadStoredRules)
import Reckon.Rules.History (applyRule, loadHistory, previewRule, renderPreview, ApplyOutcome (..))
import Reckon.Rules.Language (renderProblem)
import Reckon.Reconcile
import Reckon.Report (renderSpending, spendingByAccount)
import Reckon.Screenshot.Eval (evaluateScreenshots)
import Reckon.Screenshot.Import (ScreenshotFile (..), importScreenshots, renderImportScreenshotsError, renderImportScreenshotsOutcome)
import Reckon.Screenshot.Store (openProvisionalRows, releaseProvisional, renderOpenProvisional)
import Reckon.Sharing (SplitSpec (..), splitRow)
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
    , "  add-rule 'RULE' [PRIORITY]             a rule in the rule language, e.g."
    , "                                         'when description contains \"UBER\" and amount < -50.00 then categorize expense:transport'"
    , "  rules                                  list the rules, in the order they run"
    , "  check-rule 'RULE'                      read a rule and preview which imported rows it would move"
    , "  apply-rule 'RULE'                      move the posted rows the rule would move (reverse and re-post)"
    , "  delete-rule RULE_ID                    remove a rule (posted rows keep their account)"
    , "  recategorize ROW_ID ACCOUNT            move a posted row to another account (not transfer legs)"
    , "  add-person NAME MATCH_TEXT             someone you share costs with, e.g. add-person alex \"ALEX SMITH\""
    , "  split-row ROW_ID ACCOUNT equal NAME... split a payment equally between you and these people"
    , "  split-row ROW_ID ACCOUNT NAME=AMOUNT.. split with exact shares; you keep the rest"
    , "  owed                                   what each person currently owes you"
    , "  spending FROM TO                       what you spent per category (your share only)"
    , "  import-screenshots LAST4 [--taken DATE] FILE...   read screenshots of the app (one scroll, top first)"
    , "  provisional                            rows read from screenshots that no bank export has confirmed yet"
    , "  release-provisional ID                 a pending hold that never posted: reverse it"
    , "  eval-screenshots DIR                   score the model's reading against hand-labelled screenshots"
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
          Left problem -> Left (describePostingError (Text.pack rowIdText) problem)
    ["recategorize", rowIdText, accountName] -> case readMaybe rowIdText of
      Nothing -> die ("ROW_ID must be the number shown by make post, got " <> show rowIdText)
      Just rowNumber -> withDatabase $ \pool -> runOrDie pool $ do
        result <- recategorizeRow (toSqlKey rowNumber) (Text.pack accountName)
        pure $ case result of
          Right () -> Right ("Row #" <> Text.pack rowIdText <> " is now posted against " <> Text.pack accountName <> ".")
          Left problem -> Left (describePostingError (Text.pack rowIdText) problem)
    ["add-person", name, matchText] -> withDatabase $ \pool -> runOrDie pool $ do
      result <- addPerson (Text.pack name) (Text.pack matchText)
      pure $ case result of
        Right _ ->
          Right
            ( "Added " <> Text.pack name <> ". Money in whose description contains \"" <> Text.toUpper (Text.pack matchText)
                <> "\" will be offered as their repayment (make post), and their share of split payments goes to receivable:" <> Text.pack name <> "."
            )
        Left problem -> Left (describePersonError problem)
    ("split-row" : rowIdText : accountName : shareArguments) -> case (readMaybe rowIdText, shareArguments) of
      (Nothing, _) -> die ("ROW_ID must be the number shown by make post, got " <> show rowIdText)
      (_, []) -> die "Say who to split with: `equal NAME...` or `NAME=AMOUNT...`."
      (Just rowNumber, "equal" : names) -> withDatabase (shareRow rowIdText rowNumber accountName (EqualWith (map Text.pack names)))
      (Just rowNumber, shares) -> case traverse parseShare shares of
        Left problem -> die problem
        Right exactShares -> withDatabase (shareRow rowIdText rowNumber accountName (ExactShares exactShares))
    ("import-screenshots" : last4Text : screenshotArguments) -> do
      last4 <- maybe (die ("LAST4 must be the last 4 digits of the account number, got " <> show last4Text)) pure (mkLast4 (Text.pack last4Text))
      (takenArgument, paths) <- either die pure (splitTakenOption screenshotArguments)
      today <- utctDay <$> getCurrentTime
      takenOn <- maybe (pure today) parseDay takenArgument
      files <- mapM (\path -> ScreenshotFile (Text.pack (takeFileName path)) <$> ByteString.readFile path) paths
      anthropic <- loadAnthropicConfig >>= either (die . Text.unpack) pure
      extract <- anthropicExtractor anthropic
      withDatabase $ \pool -> do
        result <- importScreenshots pool extract anthropic.model last4 takenOn files
        case result of
          Right outcome -> Text.putStr (renderImportScreenshotsOutcome outcome)
          Left problem -> Text.putStr (renderImportScreenshotsError problem <> "\n") >> exitFailure
    ["provisional"] -> withDatabase $ \pool -> do
      today <- utctDay <$> getCurrentTime
      rows <- runSqlPool openProvisionalRows pool
      Text.putStr (renderOpenProvisional today rows)
    ["release-provisional", rowIdText] -> case readMaybe rowIdText of
      Nothing -> die ("ID must be the number shown by scripts/reckon.sh provisional, got " <> show rowIdText)
      Just rowNumber -> withDatabase $ \pool -> runOrDie pool $ do
        result <- releaseProvisional (toSqlKey rowNumber)
        pure $ case result of
          Right () -> Right ("Released #" <> Text.pack rowIdText <> ": its provisional entry is reversed.")
          Left problem -> Left (describeReleaseError (Text.pack rowIdText) problem)
    ["eval-screenshots", directory] -> do
      anthropic <- loadAnthropicConfig >>= either (die . Text.unpack) pure
      extract <- anthropicExtractor anthropic
      evaluateScreenshots extract directory >>= Text.putStr
    ["owed"] -> withDatabase $ \pool -> do
      today <- utctDay <$> getCurrentTime
      people <- runSqlPool (whoOwesWhat today) pool
      Text.putStr (renderOwed today people)
    ["spending", fromText, toText] -> do
      from <- parseDay fromText
      to <- parseDay toText
      withDatabase $ \pool -> do
        accounts <- runSqlPool (spendingByAccount from to) pool
        Text.putStr (renderSpending from to accounts)
    -- One argument is a rule in the rule language; two or three are the
    -- original "TEXT ACCOUNT [PRIORITY]".
    ["add-rule", ruleText] -> withDatabase (addRuleText ruleText 100)
    ["add-rule", ruleText, priorityOrAccount] -> case readMaybe priorityOrAccount of
      Just priority | looksLikeRule ruleText -> withDatabase (addRuleText ruleText priority)
      _ -> withDatabase (addSimpleRule ruleText priorityOrAccount 100)
    ["add-rule", ruleText, accountName, priorityText] -> case readMaybe priorityText of
      Just priority -> withDatabase (addSimpleRule ruleText accountName priority)
      Nothing -> die ("PRIORITY must be a whole number, got " <> show priorityText)
    ["rules"] -> withDatabase $ \pool -> do
      stored <- runSqlPool loadStoredRules pool
      Text.putStr (renderStoredRules stored)
    ["delete-rule", numberText] -> case readMaybe numberText of
      Just number -> withDatabase $ \pool -> runOrDie pool $ do
        result <- deleteRule number
        pure (either (Left . describeRuleError) (const (Right "Deleted. Rows already posted keep the account they were given.")) result)
      Nothing -> die ("RULE_ID must be a whole number, got " <> show numberText)
    ["check-rule", ruleText] -> withDatabase $ \pool -> do
      checked <- runSqlPool (checkRule (Text.pack ruleText)) pool
      case checked of
        Left problem -> Text.putStrLn (renderProblem problem) >> exitFailure
        Right rule -> do
          history <- runSqlPool loadHistory pool
          Text.putStr (renderPreview (previewRule rule history))
    ["apply-rule", ruleText] -> withDatabase $ \pool -> do
      checked <- runSqlPool (checkRule (Text.pack ruleText)) pool
      case checked of
        Left problem -> Text.putStrLn (renderProblem problem) >> exitFailure
        Right rule -> do
          outcome <- runSqlPool (applyRule rule) pool
          putStrLn ("Moved " <> show outcome.moved <> " row(s).")
          mapM_ (\(date, description, why) -> Text.putStrLn ("  not moved: " <> showText date <> "  " <> description <> ": " <> why)) outcome.refused
    ["opening-balance", last4Text, dateText, amountText] -> do
      (last4, date, amount) <- parseAccountDateAmount last4Text dateText amountText
      withDatabase $ \pool -> runOrDie pool $ withBankAccount last4 $ \account -> do
        result <- recordOpeningBalance account date amount
        pure $ case result of
          Right _ -> Right ("Recorded an opening balance of " <> renderCents amount <> " at the end of " <> showText date <> ".")
          Left problem -> Left (describeOpeningBalanceError problem)
    ["checkpoint", last4Text, dateText, amountText] -> do
      (last4, date, amount) <- parseAccountDateAmount last4Text dateText amountText
      withDatabase $ \pool -> runOrDie pool $ withBankAccount last4 $ \account -> do
        result <- recordCheckpoint account date amount
        case result of
          Left problem ->
            pure (Left (describeCheckpointError problem <> " Run: scripts/reckon.sh reconcile"))
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

addRuleText :: String -> Int -> ConnectionPool -> IO ()
addRuleText ruleText priority pool = runOrDie pool $ do
  result <- addRule (Text.pack ruleText) priority
  pure $ case result of
    Right saved -> Right ("Saved: " <> saved.ruleText <> "\nIt applies to rows posted from now on. To change rows already posted: scripts/reckon.sh check-rule '...' to preview, apply-rule to apply.")
    Left problem -> Left (describeRuleError problem)

-- | The original two-part form: @add-rule TEXT ACCOUNT [PRIORITY]@.
addSimpleRule :: String -> String -> Int -> ConnectionPool -> IO ()
addSimpleRule ruleText accountName priority pool = runOrDie pool $ do
  result <- addContainsRule (Text.pack ruleText) (Text.pack accountName) priority
  pure $ case result of
    Right saved -> Right ("Saved: " <> saved.ruleText <> "\nIt applies to rows posted from now on.")
    Left problem -> Left (describeRuleError problem)

-- | A single argument that starts like a rule is one; anything else is the
-- text of a simple rule whose account is missing.
looksLikeRule :: String -> Bool
looksLikeRule = (== ["when"]) . take 1 . words . map toLower

renderStoredRules :: [StoredRule] -> Text
renderStoredRules [] = "No rules yet. Add one: scripts/reckon.sh add-rule 'when description contains \"HYDRO\" then categorize expense:utilities'\n"
renderStoredRules stored =
  Text.unlines
    [ "  #" <> showText rule.ruleId <> "  (priority " <> showText rule.priority <> ")  " <> rule.ruleText <> either (\problem -> "   <- no longer reads as a rule: " <> renderProblem problem) (const "") rule.parsed
    | rule <- stored
    ]

parseAccountDateAmount :: String -> String -> String -> IO (Last4, Day, Cents)
parseAccountDateAmount last4Text dateText amountText = do
  last4 <- maybe (die ("LAST4 must be the last 4 digits of the account number, got " <> show last4Text)) pure (mkLast4 (Text.pack last4Text))
  date <- maybe (die ("DATE must look like 2026-01-31, got " <> show dateText)) pure (iso8601ParseM dateText)
  amount <- either (\problem -> die ("AMOUNT " <> Text.unpack problem)) pure (parseCents (Text.pack amountText))
  pure (last4, date, amount)

showText :: (Show a) => a -> Text
showText = Text.pack . show

parseDay :: String -> IO Day
parseDay dateText = maybe (die ("A date must look like 2026-01-31, got " <> show dateText)) pure (iso8601ParseM dateText)

-- | @--taken YYYY-MM-DD@ may appear anywhere among the files.
splitTakenOption :: [String] -> Either String (Maybe String, [FilePath])
splitTakenOption = go Nothing []
  where
    go taken files = \case
      [] | null files -> Left "Give at least one screenshot file."
         | otherwise -> Right (taken, reverse files)
      "--taken" : date : rest -> go (Just date) files rest
      ["--taken"] -> Left "--taken needs a date, e.g. --taken 2026-02-20"
      path : rest -> go taken (path : files) rest

-- | @alex=30.00@
parseShare :: String -> Either String (Text, Cents)
parseShare argument = case break (== '=') argument of
  (name, '=' : amountText) -> case parseCents (Text.pack amountText) of
    Right amount -> Right (Text.pack name, amount)
    Left problem -> Left ("The amount in " <> show argument <> " " <> Text.unpack problem)
  _ -> Left ("Expected NAME=AMOUNT (like alex=30.00) or the word `equal`, got " <> show argument)

shareRow :: String -> Int64 -> String -> SplitSpec -> ConnectionPool -> IO ()
shareRow rowIdText rowNumber accountName spec pool = runOrDie pool $ do
  result <- splitRow (toSqlKey rowNumber) (Text.pack accountName) spec
  pure $ case result of
    Right () -> Right ("Row #" <> Text.pack rowIdText <> " is split. See who owes what with: scripts/reckon.sh owed")
    Left problem -> Left (describeSplitRowError (Text.pack rowIdText) problem)
