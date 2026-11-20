-- | Storing what was read from screenshots, posting it as provisional
-- entries, and resolving those when better evidence arrives (Phase 5,
-- DECISIONS D054-D059).
--
-- A screenshot row is evidence of lower quality than a CSV row, so it never
-- stands alone for long:
--
-- * When it's read, it's checked against rows the bank's CSV already has
--   (@already_in_csv@: nothing is posted) and against older pending rows it
--   supersedes (a hold that posted).
-- * Otherwise it is posted as a /provisional/ entry, so the ledger already
--   shows it.
-- * When a CSV row for the same transaction arrives, the provisional entry
--   is reversed, dated like the original (@confirmed_by_csv@), and the CSV
--   row is posted the normal way.
-- * A hold that never posts is reversed by hand (@released@).
--
-- Nothing is edited or deleted: every step is a reversal plus a new row.
module Reckon.Screenshot.Store
  ( ScreenshotUploadData (..)
  , StoreSummary (..)
  , storeScreenshots
  , confirmProvisionalRows
  , OpenProvisional (..)
  , openProvisionalRows
  , openProvisionalEntriesFor
  , releaseProvisional
  , ReleaseError (..)
  , renderOpenProvisional
  ) where

import Control.Monad (forM, forM_)
import Control.Monad.IO.Class (MonadIO)
import Data.ByteString (ByteString)
import Data.Foldable (for_)
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Text.Encoding.Error qualified as Text
import Data.Time (Day, addDays, diffDays)
import Database.Persist (Entity (..), getBy, insert, insert_)
import Database.Persist.Sql (PersistValue (..), Single (..), SqlPersistT, fromSqlKey, rawSql)
import Reckon.Database.Schema
import Reckon.Import.Dedupe (Fingerprint, IncomingRow (..), RowKey (..), assignOccurrences, fingerprintOf)
import Reckon.Ledger (postEntry, postReversal)
import Reckon.Ledger.Entry (EntryLine (..), mkBalancedLines, mkNewJournalEntry)
import Reckon.Money (Cents (..), negateCents, renderCents)
import Reckon.Screenshot.Align (AlignWarning, Alignment (..), alignScreenshots)
import Reckon.Screenshot.Extraction (ExtractedRow (..), ExtractedScreenshot (..), Section (..), rowIdentity)
import Reckon.Screenshot.Match (Later (..), Match (..), Provisional (..), pendingWindowDays, planMatches, sameAmountWindowDays)
import Reckon.Screenshot.Resolution (ResolutionKind (..))

-- | A screenshot that has been read and validated, ready to store.
data ScreenshotUploadData = ScreenshotUploadData
  { fileName :: Text
  , fileSha256 :: Text
  , reply :: ByteString
  -- ^ The model's reply, as received (it validated, so it holds no account
  -- number).
  , screenshot :: ExtractedScreenshot
  }
  deriving stock (Show, Eq)

data StoreSummary = StoreSummary
  { uploadsStored :: Int
  , rowsAdded :: Int
  , rowsAlreadyStored :: Int
  -- ^ Seen in an earlier import of the same account.
  , provisionalPosted :: Int
  , alreadyInCsv :: Int
  -- ^ The bank's CSV already has these, so nothing was posted for them.
  , supersededHolds :: Int
  -- ^ Earlier pending rows that these posted rows replace.
  , uncertainNotPosted :: Int
  , partialRowsDropped :: Int
  , warnings :: [AlignWarning]
  }
  deriving stock (Show, Eq)

-- | Stores the screenshots of one scroll, in scroll order, for one bank
-- account. @counterFor@ chooses the account on the other side of a
-- provisional entry (a categorization rule, else an uncategorized account).
storeScreenshots ::
  (MonadIO m) =>
  Entity BankAccount ->
  Day ->
  Text ->
  (ExtractedRow -> LedgerAccountId) ->
  [ScreenshotUploadData] ->
  SqlPersistT m StoreSummary
storeScreenshots (Entity bankAccountId bankAccount) takenOn modelId counterFor uploads = do
  uploadIds <-
    forM uploads $ \upload ->
      insert
        ScreenshotUpload
          { screenshotUploadFileSha256 = upload.fileSha256
          , screenshotUploadFileName = upload.fileName
          , screenshotUploadBankAccountId = bankAccountId
          , screenshotUploadTakenOn = takenOn
          , screenshotUploadModelId = modelId
          , screenshotUploadAccountLabel = upload.screenshot.accountLabel
          , screenshotUploadExtractionJson = Text.decodeUtf8With Text.lenientDecode upload.reply
          , screenshotUploadPartialRowsDropped = upload.screenshot.partialRowsDropped
          }

  -- Join the overlapping screenshots into one list of rows, then number
  -- identical rows (two coffees) the way CSV imports do.
  let tagged = [[(uploadId, row) | row <- upload.screenshot.rows] | (uploadId, upload) <- zip uploadIds uploads]
      Alignment {rows = joined, warnings = alignWarnings} = alignScreenshots (rowIdentity . snd) tagged
      incoming =
        [ IncomingRow {transactionDate = row.transactionDate, fingerprint = fingerprintOfRow row, amount = row.amount, payload = (uploadId, row)}
        | (uploadId, row) <- joined
        ]

  inserted <- forM (assignOccurrences incoming) $ \(key, incomingRow) -> do
    let (uploadId, row) = incomingRow.payload
    existing <- getBy (UniqueScreenshotRow bankAccountId key.transactionDate key.fingerprint key.occurrence)
    case existing of
      Just _ -> pure Nothing
      Nothing -> do
        rowId <-
          insert
            ScreenshotRow
              { screenshotRowUploadId = uploadId
              , screenshotRowBankAccountId = bankAccountId
              , screenshotRowTransactionDate = row.transactionDate
              , screenshotRowDescription = row.description
              , screenshotRowAmountCents = row.amount
              , screenshotRowRunningBalanceCents = row.runningBalance
              , screenshotRowIsPending = row.section == Pending
              , screenshotRowUncertain = row.uncertain
              , screenshotRowFingerprint = key.fingerprint
              , screenshotRowOccurrence = key.occurrence
              }
        pure (Just (rowId, row))
  let newRows = [found | Just found <- inserted]

  -- Rows the bank's CSV already has: nothing to post.
  csvRows <- csvRowsAround bankAccountId (map (.transactionDate) (map snd newRows))
  let provisionals = [provisionalFrom rowId row | (rowId, row) <- newRows]
      csvMatches = planMatches provisionals csvRows
  for_ csvMatches $ \match ->
    insert_ (ProvisionalResolution match.provisional AlreadyInCsv (Just match.later) Nothing)

  -- Earlier pending rows that these posted rows replace: reverse the hold.
  olderPending <- openPendingRows bankAccountId (Set.fromList (map fst newRows))
  let postedNow = [Later {rowId, date = row.transactionDate, description = row.description, amount = row.amount} | (rowId, row) <- newRows, row.section == Posted]
      supersessions = planMatches olderPending postedNow
  for_ supersessions $ \match -> do
    reverseEntryOf match.provisional
    insert_ (ProvisionalResolution match.provisional SupersededByScreenshot Nothing (Just match.later))

  -- Everything else that was read with confidence becomes a provisional entry.
  let resolvedHere = Set.fromList (map (.provisional) csvMatches)
      toPost = [(rowId, row) | (rowId, row) <- newRows, not (Set.member rowId resolvedHere), not row.uncertain]
  forM_ toPost $ \(rowId, row) -> postProvisional bankAccount counterFor rowId row

  pure
    StoreSummary
      { uploadsStored = length uploads
      , rowsAdded = length newRows
      , rowsAlreadyStored = length joined - length newRows
      , provisionalPosted = length toPost
      , alreadyInCsv = length csvMatches
      , supersededHolds = length supersessions
      , uncertainNotPosted = length [() | (rowId, row) <- newRows, row.uncertain, not (Set.member rowId resolvedHere)]
      , partialRowsDropped = sum [upload.screenshot.partialRowsDropped | upload <- uploads]
      , warnings = alignWarnings
      }

-- | A hold and its posted version are different transactions to the
-- fingerprint, so a pending row and the same row posted are both stored.
fingerprintOfRow :: ExtractedRow -> Fingerprint
fingerprintOfRow row = fingerprintOf row.description (if row.section == Pending then "PENDING" else "POSTED") "" row.amount

provisionalFrom :: ScreenshotRowId -> ExtractedRow -> Provisional ScreenshotRowId
provisionalFrom rowId row =
  Provisional {rowId, date = row.transactionDate, description = row.description, amount = row.amount, section = row.section}

postProvisional :: (MonadIO m) => BankAccount -> (ExtractedRow -> LedgerAccountId) -> ScreenshotRowId -> ExtractedRow -> SqlPersistT m ()
postProvisional bankAccount counterFor rowId row =
  case mkBalancedLines
    [ EntryLine {ledgerAccountId = bankAccountLedgerAccountId bankAccount, amount = row.amount}
    , EntryLine {ledgerAccountId = counterFor row, amount = negateCents row.amount}
    ]
    >>= mkNewJournalEntry row.transactionDate ("(provisional) " <> row.description) of
    -- Can't happen: the amount is never zero and the two lines negate each other.
    Left entryError -> error ("postProvisional: " <> show entryError)
    Right newEntry -> do
      entryId <- postEntry newEntry
      insert_ ScreenshotEntryEvidence {screenshotEntryEvidenceEntryId = entryId, screenshotEntryEvidenceScreenshotRowId = rowId}

-- | Reverses the row's provisional entry, dated like the original, if one
-- is in effect.
reverseEntryOf :: (MonadIO m) => ScreenshotRowId -> SqlPersistT m ()
reverseEntryOf rowId = do
  current <- currentEntryForScreenshotRow rowId
  for_ current $ \(entryId, occurredOn) -> postReversal entryId occurredOn

currentEntryForScreenshotRow :: (MonadIO m) => ScreenshotRowId -> SqlPersistT m (Maybe (JournalEntryId, Day))
currentEntryForScreenshotRow rowId = do
  found <-
    rawSql
      "SELECT e.id, e.occurred_on FROM screenshot_entry_evidence ev \
      \JOIN journal_entries e ON e.id = ev.entry_id \
      \WHERE ev.screenshot_row_id = ? \
      \  AND NOT EXISTS (SELECT 1 FROM journal_entries r WHERE r.reverses_entry_id = e.id)"
      [PersistInt64 (fromSqlKey rowId)]
  pure (listToMaybe [(entryId, occurredOn) | (Single entryId, Single occurredOn) <- found])

-- | CSV rows of the account near these dates that no screenshot row has
-- claimed yet.
csvRowsAround :: (MonadIO m) => BankAccountId -> [Day] -> SqlPersistT m [Later RawBankRowId]
csvRowsAround _ [] = pure []
csvRowsAround bankAccountId dates = do
  found <-
    rawSql
      "SELECT r.id, r.transaction_date, r.description_1, r.description_2, r.amount_cents FROM raw_bank_rows r \
      \WHERE r.bank_account_id = ? AND r.transaction_date BETWEEN ? AND ? \
      \  AND NOT EXISTS (SELECT 1 FROM provisional_resolutions p WHERE p.raw_bank_row_id = r.id)"
      [ PersistInt64 (fromSqlKey bankAccountId)
      , PersistDay (addDays (negate sameAmountWindowDays) (minimum dates))
      , PersistDay (addDays pendingWindowDays (maximum dates))
      ]
  pure
    [ Later {rowId, date, description = joinDescriptions first second, amount}
    | (Single rowId, Single date, Single first, Single second, Single amount) <- found
    ]

-- | Older pending rows still in effect (posted, not resolved), other than
-- the ones just stored.
openPendingRows :: (MonadIO m) => BankAccountId -> Set.Set ScreenshotRowId -> SqlPersistT m [Provisional ScreenshotRowId]
openPendingRows bankAccountId excluding = do
  found <-
    openRows
      " AND s.is_pending AND s.bank_account_id = ? AND EXISTS (SELECT 1 FROM screenshot_entry_evidence ev WHERE ev.screenshot_row_id = s.id)"
      [PersistInt64 (fromSqlKey bankAccountId)]
  pure
    [ Provisional {rowId = row.rowId, date = row.date, description = row.description, amount = row.amount, section = Pending}
    | row <- found
    , not (Set.member row.rowId excluding)
    ]

-- | A screenshot row with no resolution.
data OpenRow = OpenRow
  { rowId :: ScreenshotRowId
  , bankAccount :: BankAccountId
  , date :: Day
  , description :: Text
  , amount :: Cents
  , pending :: Bool
  }

-- | Every screenshot row with no resolution, narrowed by extra SQL
-- conditions (starting with @ AND@).
openRows :: (MonadIO m) => Text -> [PersistValue] -> SqlPersistT m [OpenRow]
openRows extraConditions parameters = do
  found <-
    rawSql
      ( "SELECT s.id, s.bank_account_id, s.transaction_date, s.description, s.amount_cents, s.is_pending \
        \FROM screenshot_rows s WHERE NOT EXISTS (SELECT 1 FROM provisional_resolutions p WHERE p.screenshot_row_id = s.id)"
          <> extraConditions
      )
      parameters
  pure
    [ OpenRow {rowId, bankAccount, date, description, amount, pending}
    | (Single rowId, Single bankAccount, Single date, Single description, Single amount, Single pending) <- found
    ]

joinDescriptions :: Text -> Text -> Text
joinDescriptions first second = Text.strip (first <> " " <> second)

-- | Called when bank rows are posted: any open screenshot row that a new CSV
-- row confirms has its provisional entry reversed (dated like the original)
-- and is resolved. Then the CSV row is posted the normal way. Returns how
-- many were confirmed.
confirmProvisionalRows :: (MonadIO m) => SqlPersistT m Int
confirmProvisionalRows = do
  open <- openRows "" []
  csv <-
    rawSql
      "SELECT r.id, r.bank_account_id, r.transaction_date, r.description_1, r.description_2, r.amount_cents FROM raw_bank_rows r \
      \WHERE NOT EXISTS (SELECT 1 FROM journal_entry_evidence ev WHERE ev.raw_bank_row_id = r.id \
      \    AND NOT EXISTS (SELECT 1 FROM journal_entries rev WHERE rev.reverses_entry_id = ev.entry_id)) \
      \  AND NOT EXISTS (SELECT 1 FROM provisional_resolutions p WHERE p.raw_bank_row_id = r.id)"
      []
  let provisionalsByAccount =
        Map.fromListWith
          (flip (<>))
          [ (row.bankAccount, [Provisional {rowId = row.rowId, date = row.date, description = row.description, amount = row.amount, section = if row.pending then Pending else Posted}])
          | row <- open
          ]
      laterByAccount =
        Map.fromListWith
          (flip (<>))
          [ (accountId, [Later {rowId, date, description = joinDescriptions first second, amount}])
          | (Single rowId, Single accountId, Single date, Single first, Single second, Single amount) <- csv
          ]
      matches =
        concat
          [ planMatches provisionals (Map.findWithDefault [] accountId laterByAccount)
          | (accountId, provisionals) <- Map.toList provisionalsByAccount
          ]
  for_ matches $ \match -> do
    reverseEntryOf match.provisional
    insert_ (ProvisionalResolution match.provisional ConfirmedByCsv (Just match.later) Nothing)
  pure (length matches)

-- | A screenshot row that is still provisional.
data OpenProvisional = OpenProvisional
  { screenshotRowId :: ScreenshotRowId
  , account :: Text
  , date :: Day
  , description :: Text
  , amount :: Cents
  , pending :: Bool
  , posted :: Bool
  -- ^ Whether it has a provisional entry in the ledger. A row the model was
  -- unsure of is held without one.
  }
  deriving stock (Show, Eq)

-- | Everything read from screenshots that no CSV (or later screenshot) has
-- resolved yet, oldest first.
openProvisionalRows :: (MonadIO m) => SqlPersistT m [OpenProvisional]
openProvisionalRows = do
  found <-
    rawSql
      "SELECT s.id, b.nickname, s.transaction_date, s.description, s.amount_cents, s.is_pending, \
      \  EXISTS (SELECT 1 FROM screenshot_entry_evidence ev WHERE ev.screenshot_row_id = s.id) \
      \FROM screenshot_rows s JOIN bank_accounts b ON b.id = s.bank_account_id \
      \WHERE NOT EXISTS (SELECT 1 FROM provisional_resolutions p WHERE p.screenshot_row_id = s.id) \
      \ORDER BY s.transaction_date, s.id"
      []
  pure
    [ OpenProvisional {screenshotRowId, account, date, description, amount, pending, posted}
    | (Single screenshotRowId, Single account, Single date, Single description, Single amount, Single pending, Single posted) <- found
    ]

-- | The open provisional entries of one bank account dated on or before a
-- day, for the reconciliation report: they're in the ledger but not (yet) on
-- the bank's statement.
openProvisionalEntriesFor :: (MonadIO m) => BankAccountId -> Day -> SqlPersistT m [(Day, Text, Cents)]
openProvisionalEntriesFor bankAccountId asOf = do
  found <-
    rawSql
      "SELECT s.transaction_date, s.description, s.amount_cents FROM screenshot_rows s \
      \WHERE s.bank_account_id = ? AND s.transaction_date <= ? \
      \  AND NOT EXISTS (SELECT 1 FROM provisional_resolutions p WHERE p.screenshot_row_id = s.id) \
      \  AND EXISTS (SELECT 1 FROM screenshot_entry_evidence ev WHERE ev.screenshot_row_id = s.id \
      \    AND NOT EXISTS (SELECT 1 FROM journal_entries r WHERE r.reverses_entry_id = ev.entry_id)) \
      \ORDER BY s.transaction_date, s.id"
      [PersistInt64 (fromSqlKey bankAccountId), PersistDay asOf]
  pure [(date, description, amount) | (Single date, Single description, Single amount) <- found]

data ReleaseError
  = NoSuchScreenshotRow
  | -- | Already confirmed, superseded or released.
    AlreadyResolved
  deriving stock (Show, Eq)

-- | The owner's word that a provisional row never posted (a released hold):
-- its entry is reversed and the row is resolved as released.
releaseProvisional :: (MonadIO m) => ScreenshotRowId -> SqlPersistT m (Either ReleaseError ())
releaseProvisional rowId = do
  exists <- rowExists
  resolved <- hasResolution
  case () of
    _
      | not exists -> pure (Left NoSuchScreenshotRow)
      | resolved -> pure (Left AlreadyResolved)
      | otherwise -> do
          reverseEntryOf rowId
          insert_ (ProvisionalResolution rowId Released Nothing Nothing)
          pure (Right ())
  where
    rowExists = (not . null) <$> idsFrom "SELECT s.id FROM screenshot_rows s WHERE s.id = ?"
    hasResolution = (not . null) <$> idsFrom "SELECT p.screenshot_row_id FROM provisional_resolutions p WHERE p.screenshot_row_id = ?"
    idsFrom :: (MonadIO m) => Text -> SqlPersistT m [Single ScreenshotRowId]
    idsFrom query = rawSql query [PersistInt64 (fromSqlKey rowId)]

renderOpenProvisional :: Day -> [OpenProvisional] -> Text
renderOpenProvisional _ [] = "Nothing is waiting on a bank export: every row read from a screenshot has been confirmed.\n"
renderOpenProvisional today rows =
  Text.unlines $
    ["Read from screenshots, not yet confirmed by a bank export (" <> Text.pack (show (length rows)) <> "):"]
      <> [ "  #" <> Text.pack (show (fromSqlKey row.screenshotRowId))
             <> "  " <> Text.pack (show row.date)
             <> "  " <> renderCents row.amount
             <> "  " <> row.description
             <> "  (" <> Text.intercalate ", " (filter (not . Text.null) [kind row, age row]) <> ")"
         | row <- rows
         ]
      <> [ "Import the bank's CSV and run make post to confirm them. A pending hold that never posted: scripts/reckon.sh release-provisional ID" ]
  where
    kind row
      | not row.posted = "not posted: the model wasn't sure of it"
      | row.pending = "pending hold"
      | otherwise = "provisional"
    age row = Text.pack (show (diffDays today row.date)) <> " days ago"
