-- | Opening balances, statement checkpoints, and reconciliation reports
-- (Phase 3).
--
-- A /checkpoint/ is the balance printed on a bank statement for a given
-- date. Reconciling compares it with the ledger's balance for that bank
-- account as of the same date, and explains any difference (see
-- "Reckon.Reconcile.Explain").
module Reckon.Reconcile
  ( findBankAccountByLast4
  , recordOpeningBalance
  , OpeningBalanceError (..)
  , recordCheckpoint
  , CheckpointError (..)
  , ReconciliationReport (..)
  , reconcileAccount
  , reconcileAllCheckpoints
  , renderReconciliationReport
  ) where

import Control.Monad (forM, forM_)
import Control.Monad.IO.Class (MonadIO)
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (Day)
import Database.Persist (Entity (..), get, getBy, insert, insert_, selectList, (==.))
import Database.Persist.Sql (PersistValue (..), Single (..), SqlPersistT, fromSqlKey, rawSql)
import Database.Persist.Types (SelectOpt (..))
import Reckon.Bank (BankAccountKind (..), Last4, last4Text)
import Reckon.Database.Schema
import Reckon.Ledger (accountBalanceAsOf, findOrCreateLedgerAccount, postEntry, postReversal)
import Reckon.Ledger.AccountType (AccountType (..), naturalBalance)
import Reckon.Ledger.Entry (EntryLine (..), mkBalancedLines, mkNewJournalEntry)
import Reckon.Money (Cents (..), negateCents, renderCents)
import Reckon.Reconcile.Explain

-- | The bank account whose number ends in these 4 digits. Fails if none, or
-- more than one (e.g. a chequing account and a card with the same ending).
findBankAccountByLast4 :: (MonadIO m) => Last4 -> SqlPersistT m (Either Text (Entity BankAccount))
findBankAccountByLast4 last4 = do
  accounts <- selectList [BankAccountLast4 ==. last4] []
  pure $ case accounts of
    [account] -> Right account
    [] -> Left ("No imported bank account ends in " <> last4Text last4 <> ". Import an export for it first.")
    _ -> Left ("More than one bank account ends in " <> last4Text last4 <> ".")

-- | Chequing and savings accounts are assets; a credit card is a liability.
bankLedgerType :: BankAccount -> AccountType
bankLedgerType account = case bankAccountAccountKind account of
  CreditCard -> Liability
  _ -> Asset

data OpeningBalanceError
  = -- | The balance must be from before the first imported transaction,
    -- or that transaction would be counted twice. Carries its date.
    OpeningBalanceNotBeforeFirstTransaction Day
  | ZeroOpeningBalance
  deriving stock (Show, Eq)

-- | Records the account's balance at the end of @asOf@ (as the statement
-- shows it: money in the account, or owed on a card). It becomes an entry
-- against @equity:opening-balance@. Recording it again replaces the old
-- one: the old entry is reversed, not edited.
recordOpeningBalance ::
  (MonadIO m) => Entity BankAccount -> Day -> Cents -> SqlPersistT m (Either OpeningBalanceError JournalEntryId)
recordOpeningBalance (Entity bankAccountId bankAccount) asOf naturalAmount = do
  firstDate <- earliestTransactionDate bankAccountId
  case firstDate of
    Just firstTransaction | asOf >= firstTransaction -> pure (Left (OpeningBalanceNotBeforeFirstTransaction firstTransaction))
    _ | naturalAmount == mempty -> pure (Left ZeroOpeningBalance)
    _ -> do
      existing <- currentOpeningBalance bankAccountId
      forM_ existing $ \(Entity _ opening) ->
        postReversal (openingBalanceEntryId opening) (openingBalanceAsOfDate opening)
      equity <- findOrCreateLedgerAccount "equity:opening-balance" Equity
      -- The ledger stores raw debits/credits; the statement shows the
      -- natural sign. For an asset they're the same; for a card, opposite.
      let rawAmount = naturalBalance (bankLedgerType bankAccount) naturalAmount
          entryLines =
            [ EntryLine {ledgerAccountId = bankAccountLedgerAccountId bankAccount, amount = rawAmount}
            , EntryLine {ledgerAccountId = equity, amount = negateCents rawAmount}
            ]
      case mkBalancedLines entryLines >>= mkNewJournalEntry asOf ("Opening balance: " <> bankAccountNickname bankAccount) of
        Left entryError -> error ("recordOpeningBalance: " <> show entryError)
        Right newEntry -> do
          entryId <- postEntry newEntry
          insert_ OpeningBalance {openingBalanceEntryId = entryId, openingBalanceBankAccountId = bankAccountId, openingBalanceAsOfDate = asOf}
          pure (Right entryId)

-- | The opening balance in effect: the one whose entry isn't reversed.
currentOpeningBalance :: (MonadIO m) => BankAccountId -> SqlPersistT m (Maybe (Entity OpeningBalance))
currentOpeningBalance bankAccountId = do
  openings <- selectList [OpeningBalanceBankAccountId ==. bankAccountId] [Desc OpeningBalanceAsOfDate]
  live <- forM openings $ \opening@(Entity _ value) -> do
    reversals <- selectList [JournalEntryReversesEntryId ==. Just (openingBalanceEntryId value)] []
    pure [opening | null reversals]
  pure (listToMaybe (concat live))

earliestTransactionDate :: (MonadIO m) => BankAccountId -> SqlPersistT m (Maybe Day)
earliestTransactionDate bankAccountId = do
  found <- rawSql "SELECT min(transaction_date) FROM raw_bank_rows WHERE bank_account_id = ?" [PersistInt64 (fromSqlKey bankAccountId)]
  pure (case found of [Single date] -> date; _ -> Nothing)

newtype CheckpointError = CheckpointAlreadyRecorded Day
  deriving stock (Show, Eq)

-- | Records the balance printed on a statement. Checkpoints are evidence and
-- can't be changed afterwards.
recordCheckpoint :: (MonadIO m) => Entity BankAccount -> Day -> Cents -> SqlPersistT m (Either CheckpointError StatementCheckpointId)
recordCheckpoint (Entity bankAccountId _) asOf statementBalance = do
  existing <- getBy (UniqueStatementCheckpoint bankAccountId asOf)
  case existing of
    Just _ -> pure (Left (CheckpointAlreadyRecorded asOf))
    Nothing ->
      Right
        <$> insert
          StatementCheckpoint
            { statementCheckpointBankAccountId = bankAccountId
            , statementCheckpointAsOfDate = asOf
            , statementCheckpointStatementBalanceCents = statementBalance
            }

data ReconciliationReport = ReconciliationReport
  { nickname :: Text
  , inputs :: ReconciliationInputs
  , findings :: [Finding]
  }
  deriving stock (Show, Eq)

reconcileAccount :: (MonadIO m) => Entity BankAccount -> Day -> Cents -> SqlPersistT m ReconciliationReport
reconcileAccount (Entity bankAccountId bankAccount) asOf statementBalance = do
  let toNatural = naturalBalance (bankLedgerType bankAccount)
      summaries rows = [EvidenceSummary {transactionDate, description = describe first second, naturalAmount = toNatural amount} | (Single transactionDate, Single first, Single second, Single amount) <- rows]
      accountParameter = PersistInt64 (fromSqlKey bankAccountId)
  ledgerBalance <- toNatural <$> accountBalanceAsOf (bankAccountLedgerAccountId bankAccount) asOf
  unposted <-
    rawSql
      "SELECT r.transaction_date, r.description_1, r.description_2, r.amount_cents FROM raw_bank_rows r \
      \WHERE r.bank_account_id = ? AND r.transaction_date <= ? \
      \  AND NOT EXISTS ( \
      \    SELECT 1 FROM journal_entry_evidence ev WHERE ev.raw_bank_row_id = r.id \
      \      AND NOT EXISTS (SELECT 1 FROM journal_entries rev WHERE rev.reverses_entry_id = ev.entry_id)) \
      \ORDER BY r.transaction_date, r.id"
      [accountParameter, PersistDay asOf]
  duplicates <-
    rawSql
      "SELECT r.transaction_date, r.description_1, r.description_2, r.amount_cents FROM import_review_items i \
      \JOIN raw_bank_rows r ON r.id = i.related_raw_bank_row_id \
      \WHERE i.bank_account_id = ? AND i.kind = 'possible_duplicate' AND r.transaction_date <= ? \
      \ORDER BY r.transaction_date, r.id"
      [accountParameter, PersistDay asOf]
  covered <-
    rawSql
      "SELECT first_date, last_date FROM import_batch_coverage WHERE bank_account_id = ?"
      [accountParameter]
  opening <- currentOpeningBalance bankAccountId
  firstDate <- earliestTransactionDate bankAccountId
  let inputs =
        ReconciliationInputs
          { asOf
          , statementBalance
          , ledgerBalance
          , unpostedRows = summaries unposted
          , possibleDuplicates = summaries duplicates
          , openingBalanceDate = fmap (openingBalanceAsOfDate . entityVal) opening
          , firstTransactionDate = firstDate
          , coveredRanges = [(start, end) | (Single start, Single end) <- covered]
          }
  pure ReconciliationReport {nickname = bankAccountNickname bankAccount, inputs, findings = explainReconciliation inputs}
  where
    describe first second = case (Text.strip first, Text.strip second) of
      (text, "") -> text
      ("", text) -> text
      (one, two) -> one <> " - " <> two

-- | Reconciles every recorded checkpoint, oldest first.
reconcileAllCheckpoints :: (MonadIO m) => SqlPersistT m [ReconciliationReport]
reconcileAllCheckpoints = do
  checkpoints <- selectList [] [Asc StatementCheckpointAsOfDate, Asc StatementCheckpointBankAccountId]
  fmap concat . forM checkpoints $ \(Entity _ checkpoint) -> do
    maybeAccount <- get (statementCheckpointBankAccountId checkpoint)
    case maybeAccount of
      Nothing -> pure []
      Just account ->
        pure
          <$> reconcileAccount
            (Entity (statementCheckpointBankAccountId checkpoint) account)
            (statementCheckpointAsOfDate checkpoint)
            (statementCheckpointStatementBalanceCents checkpoint)

renderReconciliationReport :: ReconciliationReport -> Text
renderReconciliationReport report =
  Text.unlines $
    [ report.nickname <> ", statement dated " <> showText report.inputs.asOf <> ":"
    , "  statement " <> renderCents report.inputs.statementBalance
        <> ", ledger " <> renderCents report.inputs.ledgerBalance
    ]
      <> concatMap renderFinding report.findings
  where
    renderFinding = \case
      Reconciled -> ["  RECONCILED: the ledger matches the statement to the cent."]
      UnpostedRowsExplainGap rows ->
        ("  These " <> showText (length rows) <> " imported row(s) aren't posted yet, and posting them closes the gap exactly (make post says why each is waiting):")
          : map renderRow rows
      UnpostedRowMatchesGap row -> ["  This unposted row's amount equals the gap:", renderRow row]
      NoOpeningBalance difference ->
        [ "  No opening balance is recorded. If the account held " <> renderCents difference
            <> " before your first import, record it with:"
        , "    scripts/reckon.sh opening-balance LAST4 DATE AMOUNT"
        ]
      DuplicateMatchesGap row -> ["  This row was flagged as a possible duplicate, and its amount equals the extra in the ledger:", renderRow row]
      UncoveredDays gaps ->
        "  No imported export includes these days. Any transactions on them are missing (exports are dated by their first and last transaction):"
          : ["    " <> showText start <> (if start == end then "" else " to " <> showText end) | (start, end) <- gaps]
      Unexplained difference ->
        ["  OFF BY " <> renderCents difference <> " (statement minus ledger), and nothing above explains it."]
    renderRow row = "    " <> showText row.transactionDate <> "  " <> renderCents row.naturalAmount <> "  " <> row.description
    showText :: (Show a) => a -> Text
    showText = Text.pack . show
