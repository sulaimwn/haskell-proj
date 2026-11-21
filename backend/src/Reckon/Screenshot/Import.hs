-- | Importing screenshots: the whole path from image files to provisional
-- journal entries (Phase 5, DECISIONS D054-D059).
--
-- Order matters because the model is the expensive, slow, external step:
--
-- 1. Cheap checks first, with no network: the account exists, each file is
--    an image, and the same image hasn't been read before (by hash).
-- 2. Read each new image with the 'Extractor', and validate the reply
--    strictly. Any unusable reply stops the whole import before anything
--    is written.
-- 3. Join the screenshots and store everything in one database
--    transaction: all of it, or none of it.
module Reckon.Screenshot.Import
  ( ScreenshotFile (..)
  , ImportScreenshotsError (..)
  , ImportScreenshotsOutcome (..)
  , ImportedScreenshots (..)
  , importScreenshots
  , renderImportScreenshotsError
  , renderImportScreenshotsOutcome
  ) where

import Control.Monad (forM, unless)
import Control.Monad.Except (ExceptT (..), runExceptT, throwError)
import Control.Monad.IO.Class (liftIO)
import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (Day)
import Database.Persist (Entity (..), getBy)
import Database.Persist.Sql (ConnectionPool, runSqlPool)
import Reckon.Anthropic (ClientError, Extractor, ImageInput (..), detectMediaType, renderClientError)
import Reckon.Bank (BankAccountKind (..), Last4)
import Reckon.Database.Schema
import Reckon.Import (sha256Hex)
import Reckon.Posting (wellKnownAccounts)
import Reckon.Rules (loadRules)
import Reckon.Posting.Classify (EvidenceRow (..), WellKnownAccounts (..), matchingRule, ruleAccount)
import Reckon.Reconcile (findBankAccountByLast4)
import Reckon.Screenshot.Align (AlignWarning (..))
import Reckon.Screenshot.Extraction (ExtractedRow (..), ExtractionError, parseExtraction, renderExtractionError)
import Reckon.Screenshot.Store (ScreenshotUploadData (..), StoreSummary (..), storeScreenshots)

data ScreenshotFile = ScreenshotFile
  { fileName :: Text
  , content :: ByteString
  }
  deriving stock (Show, Eq)

data ImportScreenshotsError
  = NoFiles
  | -- | No imported bank account, or more than one, ends in these digits.
    AccountProblem Text
  | NotAnImage Text
  | -- | The API call for this file failed.
    CouldNotRead Text ClientError
  | -- | The model's reply for this file wasn't usable. Nothing was stored.
    UnusableReply Text [ExtractionError]
  deriving stock (Show, Eq)

data ImportScreenshotsOutcome
  = -- | Every file had been read before.
    NothingNew [Text]
  | Imported ImportedScreenshots
  deriving stock (Show, Eq)

data ImportedScreenshots = ImportedScreenshots
  { accountNickname :: Text
  , summary :: StoreSummary
  , skippedAsAlreadyRead :: [Text]
  }
  deriving stock (Show, Eq)

-- | @importScreenshots pool extractor modelId last4 takenOn files@. The files
-- are one scroll of the transaction list, top first.
importScreenshots ::
  ConnectionPool ->
  Extractor ->
  Text ->
  Last4 ->
  Day ->
  [ScreenshotFile] ->
  IO (Either ImportScreenshotsError ImportScreenshotsOutcome)
importScreenshots pool extract modelId last4 takenOn files = runExceptT $ do
  unless (not (null files)) (throwError NoFiles)
  account <- ExceptT (either (Left . AccountProblem) Right <$> runSqlPool (findBankAccountByLast4 last4) pool)

  -- No network yet: is each file an image, and have we read it before?
  checked <- forM files $ \file -> do
    mediaType <- maybe (throwError (NotAnImage file.fileName)) pure (detectMediaType file.content)
    let hash = sha256Hex file.content
    seen <- liftIO (runSqlPool (getBy (UniqueScreenshotUpload hash)) pool)
    pure (file, mediaType, hash, seen /= Nothing)
  let fresh = [(file, mediaType, hash) | (file, mediaType, hash, False) <- checked]
      skipped = [file.fileName | (file, _, _, True) <- checked]

  if null fresh
    then pure (NothingNew skipped)
    else do
      uploads <- forM fresh $ \(file, mediaType, hash) -> do
        reply <- ExceptT (either (Left . CouldNotRead file.fileName) Right <$> extract ImageInput {mediaType, bytes = file.content})
        screenshot <- either (throwError . UnusableReply file.fileName) pure (parseExtraction takenOn reply)
        pure ScreenshotUploadData {fileName = file.fileName, fileSha256 = hash, reply, screenshot}
      summary <- liftIO $ flip runSqlPool pool $ do
        rules <- loadRules
        wellKnown <- wellKnownAccounts
        let bankLedger = bankAccountLedgerAccountId (entityVal account)
            kind = bankAccountAccountKind (entityVal account)
            counterFor row =
              case matchingRule rules (asEvidence bankLedger kind row) of
                -- A split rule puts everything in its category for now: the
                -- screenshot row is provisional, and the bank's own row will be
                -- posted (and split) when it arrives.
                Just rule -> ruleAccount rule
                Nothing
                  | row.amount < mempty -> wellKnown.uncategorizedExpense
                  | otherwise -> wellKnown.uncategorizedIncome
        storeScreenshots account takenOn modelId counterFor uploads
      pure (Imported ImportedScreenshots {accountNickname = bankAccountNickname (entityVal account), summary, skippedAsAlreadyRead = skipped})

-- | A screenshot row dressed as the planner's input, so the categorization
-- rules apply to it exactly as they do to a CSV row.
asEvidence :: LedgerAccountId -> BankAccountKind -> ExtractedRow -> EvidenceRow () LedgerAccountId
asEvidence bankLedger kind row =
  EvidenceRow
    { rowId = ()
    , bankAccount = bankLedger
    , bankAccountKind = kind
    , transactionDate = row.transactionDate
    , description1 = row.description
    , description2 = ""
    , amount = row.amount
    , alreadyPosted = False
    }

renderImportScreenshotsError :: ImportScreenshotsError -> Text
renderImportScreenshotsError = \case
  NoFiles -> "No screenshot files were given."
  AccountProblem problem -> problem
  NotAnImage name -> name <> " isn't a PNG, JPEG, GIF or WebP image."
  CouldNotRead name problem -> "Reading " <> name <> " failed. " <> renderClientError problem <> " Nothing was stored."
  UnusableReply name problems ->
    Text.unlines $
      ("The reading of " <> name <> " wasn't usable, so nothing was stored:")
        : ["  " <> renderExtractionError problem | problem <- problems]
        <> ["Retake the screenshot, or run the command again (the model's reading can vary)."]

renderImportScreenshotsOutcome :: ImportScreenshotsOutcome -> Text
renderImportScreenshotsOutcome = \case
  NothingNew skipped -> "Nothing new: " <> Text.intercalate ", " skipped <> " " <> (if length skipped == 1 then "has" else "have") <> " already been read.\n"
  Imported ImportedScreenshots {accountNickname, summary, skippedAsAlreadyRead} ->
    Text.unlines $
      [ accountNickname <> ": read " <> count summary.uploadsStored <> " screenshot(s)."
      , "  " <> count summary.rowsAdded <> " transaction(s) added, " <> count summary.rowsAlreadyStored <> " already known from earlier screenshots"
      , "  " <> count summary.provisionalPosted <> " posted provisionally (they show in the ledger until the bank's CSV confirms them)"
      ]
        <> ["  " <> count summary.alreadyInCsv <> " already in an imported CSV, so nothing was posted for them" | summary.alreadyInCsv > 0]
        <> ["  " <> count summary.supersededHolds <> " earlier pending hold(s) replaced by their posted version" | summary.supersededHolds > 0]
        <> ["  " <> count summary.uncertainNotPosted <> " row(s) the model wasn't sure of, kept but NOT posted" | summary.uncertainNotPosted > 0]
        <> ["  " <> count summary.partialRowsDropped <> " row(s) cut off at a screen edge, skipped (they appear whole in the next screenshot)" | summary.partialRowsDropped > 0]
        <> ["  skipped (already read): " <> Text.intercalate ", " skippedAsAlreadyRead | not (null skippedAsAlreadyRead)]
        <> map renderWarning summary.warnings
        <> ["Next: scripts/reckon.sh provisional   (and import the bank's CSV, then make post, to confirm)"]
  where
    count = Text.pack . show
    renderWarning = \case
      NoOverlap position -> "  WARNING: screenshots " <> count position <> " and " <> count (position + 1) <> " share no rows, so transactions between them may be missing. Take screenshots that overlap."
      AmbiguousOverlap position lengths -> "  WARNING: screenshots " <> count position <> " and " <> count (position + 1) <> " overlap in more than one way (" <> Text.intercalate " or " (map count lengths) <> " rows) because of identical transactions. The longest was used."
      OutOfOrder position -> "  WARNING: screenshots " <> count position <> " and " <> count (position + 1) <> " were in the wrong order. Joined correctly anyway. Give them top of the list first."
