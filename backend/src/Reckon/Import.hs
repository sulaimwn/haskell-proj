-- | Importing a bank export into @raw_bank_rows@: the evidence that later
-- becomes journal entries (Phase 3). Nothing here touches the journal.
--
-- 'importRbcCsv' runs inside the caller's transaction, so an import is
-- all-or-nothing: a file that fails halfway leaves no trace.
module Reckon.Import
  ( importRbcCsv
  , ImportOutcome (..)
  , ImportError (..)
  , AccountImportSummary (..)
  , renderImportOutcome
  , renderImportError
  , sha256Hex
  ) where

import Control.Monad (forM, forM_)
import Control.Monad.IO.Class (MonadIO)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as Base16
import Data.Containers.ListUtils (nubOrd)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Time (Day)
import Database.Persist (Entity (..), getBy, insert, insert_, selectList, (<=.), (==.), (>=.))
import Data.Int (Int64)
import Database.Persist.Sql (PersistValue (..), Single (..), SqlPersistT, fromSqlKey, rawSql)
import Reckon.Bank (BankAccountKind (..), Last4, last4Text)
import Reckon.Database.Schema
import Reckon.Import.Dedupe
import Reckon.Import.RbcCsv (CsvError, RbcRow (..), parseRbcCsv, renderCsvError)
import Reckon.Ledger (createLedgerAccount)
import Reckon.Ledger.AccountType (AccountType (..))

data ImportOutcome
  = -- | This exact file (same SHA-256) was imported before. Nothing changed.
    AlreadyImported ImportBatchId
  | Imported ImportBatchId [AccountImportSummary]
  deriving stock (Show, Eq)

newtype ImportError = CsvProblems [CsvError]
  deriving stock (Show, Eq)

-- | What happened to one bank account's rows from one file.
data AccountImportSummary = AccountImportSummary
  { bankAccountId :: BankAccountId
  , nickname :: Text
  , newlyRegistered :: Bool
  , firstDate :: Day
  , lastDate :: Day
  , rowsInFile :: Int
  , rowsAdded :: Int
  , rowsAlreadyPresent :: Int
  , missingFromNewerExport :: Int
  , possibleDuplicates :: Int
  }
  deriving stock (Show, Eq)

-- | Imports an RBC CSV export. The file name is recorded for reference only.
importRbcCsv :: (MonadIO m) => Text -> ByteString -> SqlPersistT m (Either ImportError ImportOutcome)
importRbcCsv fileName fileBytes = do
  let fileSha256 = sha256Hex fileBytes
  existingBatch <- getBy (UniqueImportBatchFile fileSha256)
  case existingBatch of
    Just (Entity batchId _) -> pure (Right (AlreadyImported batchId))
    Nothing -> case parseRbcCsv fileBytes of
      Left problems -> pure (Left (CsvProblems problems))
      Right rows -> do
        batchId <- insert ImportBatch {importBatchSource = "csv", importBatchFileSha256 = fileSha256, importBatchFileName = fileName}
        summaries <- forM (groupByAccount rows) (importAccountRows batchId)
        pure (Right (Imported batchId summaries))

-- | Splits a file's rows by bank account, keeping file order within each
-- account (occurrence numbering depends on it) and ordering accounts by
-- where they first appear.
groupByAccount :: [RbcRow] -> [((BankAccountKind, Last4), [RbcRow])]
groupByAccount rows =
  [(account, filter ((== account) . accountOf) rows) | account <- nubOrd (map accountOf rows)]
  where
    accountOf row = (row.accountKind, row.last4)

importAccountRows :: (MonadIO m) => ImportBatchId -> ((BankAccountKind, Last4), [RbcRow]) -> SqlPersistT m AccountImportSummary
importAccountRows batchId ((accountKind, last4), rows) = do
  (Entity bankAccountId bankAccount, newlyRegistered) <- findOrRegisterBankAccount accountKind last4

  -- Serialize imports per account: a second import of the same account
  -- waits here until this transaction commits, so both never plan against
  -- the same stored rows. The UNIQUE key is the backstop if this is ever
  -- removed.
  _locked :: [Single Int64] <-
    rawSql "SELECT id FROM bank_accounts WHERE id = ? FOR UPDATE" [PersistInt64 (fromSqlKey bankAccountId)]

  let dates = map (.transactionDate) rows
      firstDate = minimum dates
      lastDate = maximum dates
  storedEntities <-
    selectList
      [ RawBankRowBankAccountId ==. bankAccountId
      , RawBankRowTransactionDate >=. firstDate
      , RawBankRowTransactionDate <=. lastDate
      ]
      []
  let storedRows =
        [ StoredRow
            { storedId = rowId
            , key = RowKey {transactionDate = rawBankRowTransactionDate row, fingerprint = rawBankRowFingerprint row, occurrence = rawBankRowOccurrence row}
            , amount = rawBankRowAmountCents row
            }
        | Entity rowId row <- storedEntities
        ]
      storedDates = Map.fromList [(storedRow.storedId, storedRow.key.transactionDate) | storedRow <- storedRows]
      incoming =
        [ IncomingRow
            { transactionDate = row.transactionDate
            , fingerprint = fingerprintOf row.description1 row.description2 row.chequeNumber row.amount
            , amount = row.amount
            , payload = row
            }
        | row <- rows
        ]
      plan = planImport storedRows incoming

  insertedIds <- forM plan.rowsToAdd $ \(key, incomingRow) -> do
    let row = incomingRow.payload
    rowId <-
      insert
        RawBankRow
          { rawBankRowBankAccountId = bankAccountId
          , rawBankRowFirstSeenBatchId = batchId
          , rawBankRowTransactionDate = key.transactionDate
          , rawBankRowDescription1 = row.description1
          , rawBankRowDescription2 = row.description2
          , rawBankRowChequeNumber = row.chequeNumber
          , rawBankRowAmountCents = row.amount
          , rawBankRowFingerprint = key.fingerprint
          , rawBankRowOccurrence = key.occurrence
          }
    pure (key, rowId)
  let insertedIdForKey = Map.fromList insertedIds

  forM_ plan.reviewFlags $ \flag -> do
    let (storedRowId, relatedRowId) = case flag of
          MissingFromNewerExport storedRowId' -> (storedRowId', Nothing)
          PossibleDuplicate storedRowId' addedKey -> (storedRowId', Map.lookup addedKey insertedIdForKey)
    forM_ (Map.lookup storedRowId storedDates) $ \transactionDate ->
      insert_
        ImportReviewItem
          { importReviewItemBatchId = batchId
          , importReviewItemBankAccountId = bankAccountId
          , importReviewItemTransactionDate = transactionDate
          , importReviewItemKind = reviewFlagKind flag
          , importReviewItemRawBankRowId = storedRowId
          , importReviewItemRelatedRawBankRowId = relatedRowId
          }

  insert_
    ImportBatchCoverage
      { importBatchCoverageBatchId = batchId
      , importBatchCoverageBankAccountId = bankAccountId
      , importBatchCoverageFirstDate = firstDate
      , importBatchCoverageLastDate = lastDate
      , importBatchCoverageRowsInFile = length rows
      , importBatchCoverageRowsAdded = length plan.rowsToAdd
      }

  let countFlags kind = length (filter ((== kind) . reviewFlagKind) plan.reviewFlags)
  pure
    AccountImportSummary
      { bankAccountId
      , nickname = bankAccountNickname bankAccount
      , newlyRegistered
      , firstDate
      , lastDate
      , rowsInFile = length rows
      , rowsAdded = length plan.rowsToAdd
      , rowsAlreadyPresent = plan.rowsAlreadyPresent
      , missingFromNewerExport = countFlags MissingFromNewerExportKind
      , possibleDuplicates = countFlags PossibleDuplicateKind
      }

-- | The first time an account appears in an export, it's registered along
-- with the ledger account that mirrors it (@asset:rbc-chequing-1234@).
findOrRegisterBankAccount :: (MonadIO m) => BankAccountKind -> Last4 -> SqlPersistT m (Entity BankAccount, Bool)
findOrRegisterBankAccount accountKind last4 = do
  existing <- getBy (UniqueBankAccount "rbc" accountKind last4)
  case existing of
    Just entity -> pure (entity, False)
    Nothing -> do
      let (accountType, ledgerPrefix, displayKind) = case accountKind of
            Chequing -> (Asset, "asset:rbc-chequing-", "Chequing")
            Savings -> (Asset, "asset:rbc-savings-", "Savings")
            CreditCard -> (Liability, "liability:rbc-credit-card-", "Credit card")
      ledgerAccountId <- createLedgerAccount (ledgerPrefix <> last4Text last4) accountType
      let bankAccount =
            BankAccount
              { bankAccountInstitution = "rbc"
              , bankAccountAccountKind = accountKind
              , bankAccountLast4 = last4
              , bankAccountNickname = "RBC " <> displayKind <> " ending " <> last4Text last4
              , bankAccountLedgerAccountId = ledgerAccountId
              }
      bankAccountId <- insert bankAccount
      pure (Entity bankAccountId bankAccount, True)

sha256Hex :: ByteString -> Text
sha256Hex = Text.decodeUtf8 . Base16.encode . SHA256.hash

renderImportError :: ImportError -> Text
renderImportError (CsvProblems problems) =
  Text.unlines ("The file was not imported. Nothing was changed." : map (("  " <>) . renderCsvError) problems)

renderImportOutcome :: ImportOutcome -> Text
renderImportOutcome = \case
  AlreadyImported batchId ->
    "This exact file was already imported (batch " <> showText (fromSqlKey batchId) <> "). Nothing changed.\n"
  Imported batchId summaries ->
    Text.unlines (("Imported as batch " <> showText (fromSqlKey batchId) <> ".") : concatMap renderSummary summaries)
  where
    renderSummary summary =
      [ ""
      , summary.nickname <> (if summary.newlyRegistered then " (newly registered)" else "")
          <> ": " <> showText summary.firstDate <> " to " <> showText summary.lastDate
      , "  " <> showText summary.rowsInFile <> " rows in file, "
          <> showText summary.rowsAdded <> " added, "
          <> showText summary.rowsAlreadyPresent <> " already present"
      ]
        <> [ "  " <> showText summary.possibleDuplicates <> " possible duplicate(s) flagged for review"
           | summary.possibleDuplicates > 0
           ]
        <> [ "  " <> showText summary.missingFromNewerExport <> " earlier row(s) missing from this export, flagged for review"
           | summary.missingFromNewerExport > 0
           ]
    showText :: (Show a) => a -> Text
    showText = Text.pack . show
