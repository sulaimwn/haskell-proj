-- | Request handlers, and the WAI 'Application' that serves them.
--
-- Handlers are thin: they read the request, call the function in the
-- library that does the work ("Reckon.Views" for reads, the posting,
-- sharing and import modules for changes), and turn what comes back into the
-- API's types or an error. Every refusal is an 'ApiProblem' with a status:
--
-- * 400: the request itself is malformed (a bad date, bad base64)
-- * 404: there's no such row or account
-- * 422: understood, and refused for a reason of the ledger's (the message says why)
-- * 502: the Claude API failed
-- * 503: screenshots can't be read here (no API key)
module Reckon.Server
  ( application
  , server
  , reckonVersion
  ) where

import Control.Monad.Error.Class (throwError)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (asks)
import Data.Aeson (encode)
import Data.ByteString (ByteString)
import Data.ByteString.Base64 qualified as Base64
import Data.Int (Int64)
import Data.Maybe (fromMaybe)
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Time (Day, addDays, getCurrentTime, utctDay)
import Data.Time.Format.ISO8601 (iso8601ParseM)
import Data.Version (showVersion)
import Database.Persist.Sql (Entity, SqlPersistT, runSqlPool, toSqlKey)
import Network.Wai (Application)
import Paths_reckon qualified
import Reckon.Anthropic (ScreenshotReading (..))
import Reckon.Api (Api, Routes (..))
import Reckon.Api.Types
import Reckon.App (AppEnv (..), AppM, runAppM)
import Reckon.Bank (Last4, mkLast4)
import Reckon.Config (Config (..))
import Reckon.Database (pingDatabase)
import Reckon.Database.Schema (BankAccount, RawBankRowId)
import Reckon.Import (importRbcCsv, renderImportError, renderImportOutcome)
import Reckon.Messages
import Reckon.Money (Cents (..))
import Reckon.People qualified as People
import Reckon.Posting qualified as Posting
import Reckon.Reconcile qualified as Reconcile
import Reckon.Rules qualified as Rules
import Reckon.Rules (StoredRule (..))
import Reckon.Rules.History qualified as History
import Reckon.Rules.Language (RuleProblem (..), renderProblem, renderRule)
import Reckon.Screenshot.Import qualified as Screenshots
import Reckon.Screenshot.Store qualified as ScreenshotStore
import Reckon.Security (hostGuard, jsonOnlyWrites)
import Reckon.Sharing qualified as Sharing
import Reckon.Views (TransactionFilter (..))
import Reckon.Views qualified as Views
import Servant.Server (ServerError (..), err400, err404, err422, err502, err503, hoistServer, serve)
import Servant.Server.Generic (AsServerT)

-- | One handler per field of 'Routes'. A missing or mistyped handler is a
-- compile error.
server :: Routes (AsServerT AppM)
server =
  Routes
    { health = getHealth
    , accounts = \asOf -> asOfOrToday asOf >>= runDb . Views.accountSummaries
    , transactions = getTransactions
    , spending = getSpending
    , receivables = \asOf -> asOfOrToday asOf >>= runDb . Views.receivablesView
    , review = runDb Views.reviewQueue
    , ledgerAccounts = runDb Views.ledgerAccountViews
    , importCsv = postImportCsv
    , importScreenshots = postImportScreenshots
    , postRows = \_ -> postPostRows
    , settleRow = \rowNumber request -> settleOrRecategorize Posting.postRowManually "Posted" rowNumber request
    , recategorizeRow = \rowNumber request -> settleOrRecategorize Posting.recategorizeRow "Moved" rowNumber request
    , splitRow = postSplitRow
    , releaseProvisional = \rowNumber _ -> postRelease rowNumber
    , addPerson = postAddPerson
    , listRules = getRules
    , addRule = postAddRule
    , checkRule = postCheckRule
    , applyRule = postApplyRule
    , deleteRule = \ruleNumber _ -> postDeleteRule ruleNumber
    , setOpeningBalance = postOpeningBalance
    , addCheckpoint = postCheckpoint
    }

getHealth :: AppM HealthResponse
getHealth = do
  pool <- asks (.databasePool)
  databaseStatus <- liftIO (pingDatabase pool)
  pure HealthResponse {databaseStatus, serverVersion = reckonVersion}

-- * Helpers

runDb :: SqlPersistT IO a -> AppM a
runDb action = do
  pool <- asks (.databasePool)
  liftIO (runSqlPool action pool)

today :: AppM Day
today = liftIO (utctDay <$> getCurrentTime)

-- | Stops the request with this status and an 'ApiProblem' body.
refuse :: ServerError -> Text -> AppM a
refuse status message =
  throwError
    status
      { errBody = encode ApiProblem {problem = message}
      , errHeaders = [("Content-Type", "application/json;charset=utf-8")]
      }

-- | The day a balance is as of: the one asked for, or today.
asOfOrToday :: Maybe Text -> AppM Day
asOfOrToday = maybe today parseDay

parseDay :: Text -> AppM Day
parseDay text = maybe (refuse err400 ("\"" <> text <> "\" isn't a date. Use YYYY-MM-DD.")) pure (iso8601ParseM (Text.unpack text))

decodeFile :: UploadedFile -> AppM ByteString
decodeFile file = either (\_ -> refuse err400 (file.fileName <> " isn't valid base64.")) pure (Base64.decode (Text.encodeUtf8 file.contentBase64))

bankAccountByLast4 :: Text -> AppM (Entity BankAccount, Last4)
bankAccountByLast4 last4Text = do
  last4 <- maybe (refuse err400 ("\"" <> last4Text <> "\" isn't the last 4 digits of an account number.")) pure (mkLast4 last4Text)
  found <- runDb (Reconcile.findBankAccountByLast4 last4)
  either (refuse err404) (\account -> pure (account, last4)) found

-- | Turns text whose first line is the headline into an 'ActionResult'.
resultFrom :: Text -> ActionResult
resultFrom text = case filter (not . Text.null . Text.strip) (Text.lines text) of
  headline : rest -> ActionResult {message = Text.strip headline, details = rest}
  [] -> ActionResult {message = "Done.", details = []}

rowKey :: Int64 -> RawBankRowId
rowKey = toSqlKey

-- * Reads

getTransactions :: Text -> Maybe Text -> Maybe Text -> Maybe Text -> Maybe Int -> AppM [TransactionView]
getTransactions last4Text fromText toText query limit = do
  (account, _) <- bankAccountByLast4 last4Text
  from <- traverse parseDay fromText
  to <- traverse parseDay toText
  let search = case fmap Text.strip query of
        Just text | not (Text.null text) -> Just text
        _ -> Nothing
  runDb (Views.transactionsFor account TransactionFilter {from, to, search, limit = max 1 (min 1000 (fromMaybe 200 limit))})

getSpending :: Maybe Text -> Maybe Text -> AppM [SpendingMonth]
getSpending fromText toText = do
  now <- today
  from <- maybe (pure (addDays (-365) now)) parseDay fromText
  to <- maybe (pure now) parseDay toText
  runDb (Views.spendingByMonth from to)

-- * Changes

postImportCsv :: ImportCsvRequest -> AppM ActionResult
postImportCsv request = do
  bytes <- decodeFile request.file
  result <- runDb (importRbcCsv request.file.fileName bytes)
  case result of
    Left problem -> refuse err422 (renderImportError problem)
    Right outcome -> pure (resultFrom (renderImportOutcome outcome))

postImportScreenshots :: ImportScreenshotsRequest -> AppM ActionResult
postImportScreenshots request = do
  reading <- asks (.screenshotReading)
  (modelId, extractor) <- case reading of
    ReadingUnavailable why -> refuse err503 ("Screenshots can't be read here: " <> why)
    ReadingAvailable modelId extractor -> pure (modelId, extractor)
  (_, last4) <- bankAccountByLast4 request.last4
  now <- today
  takenOn <- maybe (pure now) parseDay request.takenOn
  files <- traverse (\file -> (\bytes -> Screenshots.ScreenshotFile file.fileName bytes) <$> decodeFile file) request.files
  pool <- asks (.databasePool)
  result <- liftIO (Screenshots.importScreenshots pool extractor modelId last4 takenOn files)
  case result of
    Right outcome -> pure (resultFrom (Screenshots.renderImportScreenshotsOutcome outcome))
    Left problem@(Screenshots.CouldNotRead _ _) -> refuse err502 (Screenshots.renderImportScreenshotsError problem)
    Left problem -> refuse err422 (Screenshots.renderImportScreenshotsError problem)

postPostRows :: AppM ActionResult
postPostRows = do
  summary <- runDb Posting.postPendingRows
  pure (resultFrom (Posting.renderPostingSummary summary))

-- | Settle (post) or recategorize (move) one row against an account.
settleOrRecategorize ::
  (RawBankRowId -> Text -> SqlPersistT IO (Either Posting.ManualPostingError ())) ->
  Text ->
  Int64 ->
  SettleRequest ->
  AppM ActionResult
settleOrRecategorize action verb rowNumber request = do
  result <- runDb (action (rowKey rowNumber) request.account)
  case result of
    Right () -> pure ActionResult {message = verb <> " row #" <> Text.pack (show rowNumber) <> " against " <> request.account <> ".", details = []}
    Left Posting.RowNotFound -> refuse err404 (describePostingError (Text.pack (show rowNumber)) Posting.RowNotFound)
    Left problem -> refuse err422 (describePostingError (Text.pack (show rowNumber)) problem)

postSplitRow :: Int64 -> SplitRequest -> AppM ActionResult
postSplitRow rowNumber request = do
  spec <- case (request.equalWith, request.shares) of
    (Just names, Nothing) -> pure (Sharing.EqualWith names)
    (Nothing, Just shares) -> pure (Sharing.ExactShares [(share.person, Cents (fromIntegral share.cents)) | share <- shares])
    _ -> refuse err400 "Give exactly one of equalWith and shares."
  result <- runDb (Sharing.splitRow (rowKey rowNumber) request.category spec)
  case result of
    Right () -> pure ActionResult {message = "Row #" <> Text.pack (show rowNumber) <> " is split.", details = []}
    Left problem@(Sharing.CouldNotPost Posting.RowNotFound) -> refuse err404 (describeSplitRowError (Text.pack (show rowNumber)) problem)
    Left problem -> refuse err422 (describeSplitRowError (Text.pack (show rowNumber)) problem)

postRelease :: Int64 -> AppM ActionResult
postRelease rowNumber = do
  result <- runDb (ScreenshotStore.releaseProvisional (toSqlKey rowNumber))
  case result of
    Right () -> pure ActionResult {message = "Released #" <> Text.pack (show rowNumber) <> ": its provisional entry is reversed.", details = []}
    Left problem@ScreenshotStore.NoSuchScreenshotRow -> refuse err404 (describeReleaseError (Text.pack (show rowNumber)) problem)
    Left problem -> refuse err422 (describeReleaseError (Text.pack (show rowNumber)) problem)

postAddPerson :: AddPersonRequest -> AppM ActionResult
postAddPerson request = do
  result <- runDb (People.addPerson request.name request.matchText)
  case result of
    Right _ -> pure ActionResult {message = "Added " <> request.name <> ".", details = ["Their share of split payments goes to receivable:" <> request.name <> "."]}
    Left problem -> refuse err422 (describePersonError problem)

getRules :: AppM [RuleView]
getRules = do
  stored <- runDb Rules.loadStoredRules
  pure
    [ RuleView
        { ruleId = fromIntegral rule.ruleId
        , ruleText = rule.ruleText
        , priority = rule.priority
        , problem = either (Just . renderProblem) (const Nothing) rule.parsed
        }
    | rule <- stored
    ]

postAddRule :: AddRuleRequest -> AppM ActionResult
postAddRule request = do
  result <- runDb (Rules.addRule request.ruleText (fromMaybe 100 request.priority))
  case result of
    Right saved ->
      pure
        ActionResult
          { message = "Saved the rule."
          , details = [saved.ruleText, "It applies to rows posted from now on. To change rows already posted, preview it and apply it."]
          }
    Left problem -> refuse err422 (describeRuleError problem)

-- | A rule that isn't one is a normal answer here, with the problem and where
-- it is: this is called as the text is typed.
postCheckRule :: CheckRuleRequest -> AppM RuleCheck
postCheckRule request = do
  checked <- runDb (Rules.checkRule request.ruleText)
  case checked of
    Left problem ->
      pure RuleCheck {problem = Just RuleProblemView {line = problem.line, column = problem.column, message = problem.message}, canonicalText = Nothing, preview = Nothing}
    Right rule -> do
      history <- runDb History.loadHistory
      pure RuleCheck {problem = Nothing, canonicalText = Just (renderRule rule), preview = Just (Views.rulePreviewView (History.previewRule rule history))}

postApplyRule :: ApplyRuleRequest -> AppM ActionResult
postApplyRule request = do
  checked <- runDb (Rules.checkRule request.ruleText)
  case checked of
    Left problem -> refuse err422 ("That isn't a rule. " <> renderProblem problem)
    Right rule -> do
      outcome <- runDb (History.applyRule rule)
      pure
        ActionResult
          { message = "Moved " <> Text.pack (show outcome.moved) <> (if outcome.moved == 1 then " row." else " rows.")
          , details = [renderDay date <> "  " <> description <> ": " <> why | (date, description, why) <- outcome.refused]
          }
  where
    renderDay = Text.pack . show

postDeleteRule :: Int64 -> AppM ActionResult
postDeleteRule ruleNumber = do
  result <- runDb (Rules.deleteRule ruleNumber)
  case result of
    Right () -> pure ActionResult {message = "Deleted the rule.", details = ["Rows already posted keep the account they were given."]}
    Left problem -> refuse err404 (describeRuleError problem)

postOpeningBalance :: Text -> BalanceRequest -> AppM ActionResult
postOpeningBalance last4Text request = do
  (account, _) <- bankAccountByLast4 last4Text
  date <- parseDay request.date
  result <- runDb (Reconcile.recordOpeningBalance account date (Cents (fromIntegral request.balanceCents)))
  case result of
    Right _ -> pure ActionResult {message = "Recorded the opening balance.", details = []}
    Left problem -> refuse err422 (describeOpeningBalanceError problem)

postCheckpoint :: Text -> BalanceRequest -> AppM ActionResult
postCheckpoint last4Text request = do
  (account, _) <- bankAccountByLast4 last4Text
  date <- parseDay request.date
  let balance = Cents (fromIntegral request.balanceCents)
  recorded <- runDb (Reconcile.recordCheckpoint account date balance)
  case recorded of
    Left problem -> refuse err422 (describeCheckpointError problem)
    Right _ -> do
      report <- runDb (Reconcile.reconcileAccount account date balance)
      pure (resultFrom (Reconcile.renderReconciliationReport report))

-- | The version from @reckon.cabal@.
reckonVersion :: Text
reckonVersion = Text.pack (showVersion Paths_reckon.version)

-- | The whole application: the routes, behind the checks that keep the API
-- private ("Reckon.Security").
application :: AppEnv -> Application
application env =
  hostGuard env.config.allowedHosts (jsonOnlyWrites (serve api (hoistServer api (runAppM env) server)))
  where
    api = Proxy @Api
