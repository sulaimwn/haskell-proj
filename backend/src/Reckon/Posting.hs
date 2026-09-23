-- | Posting imported bank rows to the journal (Phase 3).
--
-- 'postPendingRows' loads every unposted row (plus rows posted earlier on a
-- guess that a new row might pair with), asks the pure planner in
-- "Reckon.Posting.Classify" what each one is, and posts one journal entry
-- per row, all in the caller's transaction. Running it again with nothing
-- new imported does nothing.
module Reckon.Posting
  ( postPendingRows
  , PostingSummary (..)
  , renderPostingSummary
  , postRowManually
  , ManualPostingError (..)
  , addCategorizationRule
  , RuleError (..)
  , wellKnownAccounts
  , currentEntryForRow
  ) where

import Control.Monad (forM_, when)
import Control.Monad.IO.Class (MonadIO)
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (Day, addDays)
import Database.Persist (Entity (..), getBy, insert, insert_, selectList)
import Database.Persist.Sql (PersistValue (..), Single (..), SqlPersistT, fromSqlKey, rawSql)
import Database.Persist.Types (SelectOpt (..))
import Reckon.Bank (BankAccountKind)
import Reckon.Database.Schema
import Reckon.Import.Dedupe (normalizeDescription)
import Reckon.Ledger (accountTypeFromName, findOrCreateLedgerAccount, postEntry, postReversal)
import Reckon.Ledger.AccountType (AccountType (..))
import Reckon.Ledger.Entry (EntryLine (..), mkBalancedLines, mkNewJournalEntry)
import Reckon.Money (Cents (..), negateCents, renderCents)
import Reckon.Posting.Classify

-- | The accounts the planner routes to, created on first use.
wellKnownAccounts :: (MonadIO m) => SqlPersistT m (WellKnownAccounts LedgerAccountId)
wellKnownAccounts =
  WellKnownAccounts
    <$> findOrCreateLedgerAccount "asset:clearing" Asset
    <*> findOrCreateLedgerAccount "liability:untracked-cards" Liability
    <*> findOrCreateLedgerAccount "expense:uncategorized" Expense
    <*> findOrCreateLedgerAccount "income:uncategorized" Income

data PostingSummary = PostingSummary
  { categorizedByRule :: Int
  , transferLegs :: Int
  , cancelledPairLegs :: Int
  , untrackedCardPayments :: Int
  , uncategorized :: Int
  , reposted :: Int
  -- ^ Rows posted earlier on a guess, re-posted now that their other half
  -- arrived.
  , leftForReview :: [(RawBankRowId, Day, Text, Cents, ReviewReason RawBankRowId)]
  }
  deriving stock (Show, Eq)

postPendingRows :: (MonadIO m) => SqlPersistT m PostingSummary
postPendingRows = do
  wellKnown <- wellKnownAccounts
  rules <- loadRules
  unposted <- loadUnpostedRows
  -- Rows already posted on a guess (uncategorized, or "payment to an
  -- untracked card") can pair with a newly imported row, within the widest
  -- pairing window of the new rows.
  pairable <- case map (.transactionDate) unposted of
    [] -> pure []
    dates -> loadRepairableRows wellKnown (addDays (negate cancellationWindowDays) (minimum dates))
  let plan = planPosting wellKnown rules (unposted <> pairable)

  forM_ plan.postings $ \planned -> do
    when planned.replacesExistingEntry $ do
      existing <- currentEntryForRow planned.row.rowId
      forM_ existing $ \(entryId, occurredOn) ->
        -- Dated like the entry it reverses, so the bank account's balance
        -- as of every date is unchanged by re-posting.
        postReversal entryId occurredOn
    postRow planned

  let count predicate = length (filter predicate plan.postings)
  pure
    PostingSummary
      { categorizedByRule = count (isClassification isRule)
      , transferLegs = count (isClassification isTransfer)
      , cancelledPairLegs = count (isClassification isCancelledPair)
      , untrackedCardPayments = count (isClassification (== UntrackedCardPayment))
      , uncategorized = count (isClassification (== Uncategorized))
      , reposted = count (.replacesExistingEntry)
      , leftForReview =
          [ (row.rowId, row.transactionDate, entryDescription row, row.amount, reason)
          | (row, reason) <- plan.leftForReview
          ]
      }
  where
    isClassification predicate planned = predicate planned.classification
    isRule = \case CategorizedByRule _ _ -> True; _ -> False
    isTransfer = \case TransferWith _ -> True; _ -> False
    isCancelledPair = \case CancelledPairWith _ -> True; _ -> False

-- | One entry per row: the row's amount on its bank's ledger account,
-- balanced by the counter account, with the row recorded as its evidence.
postRow :: (MonadIO m) => PlannedPosting RawBankRowId LedgerAccountId -> SqlPersistT m ()
postRow planned = do
  let row = planned.row
      entryLines =
        [ EntryLine {ledgerAccountId = row.bankAccount, amount = row.amount}
        , EntryLine {ledgerAccountId = planned.counterAccount, amount = negateCents row.amount}
        ]
  case mkBalancedLines entryLines >>= mkNewJournalEntry row.transactionDate (entryDescription row) of
    -- Can't happen: zero-amount rows are left for review, and the two lines
    -- negate each other by construction.
    Left entryError -> error ("postRow: " <> show entryError)
    Right newEntry -> do
      entryId <- postEntry newEntry
      insert_ JournalEntryEvidence {journalEntryEvidenceEntryId = entryId, journalEntryEvidenceRawBankRowId = row.rowId}

entryDescription :: EvidenceRow rowId account -> Text
entryDescription row = case (Text.strip row.description1, Text.strip row.description2) of
  (first, "") -> first
  ("", second) -> second
  (first, second) -> first <> " - " <> second

data ManualPostingError
  = RowNotFound
  | RowAlreadyPosted
  | UnknownAccount Text
  | ZeroAmountRow
  deriving stock (Show, Eq)

-- | Posts one unposted row against an account you choose: the way to settle
-- a row left for review. The account is created if needed (its type comes
-- from its prefix). Posting both legs of an ambiguous transfer to
-- @asset:clearing@ records them as a transfer.
postRowManually :: (MonadIO m) => RawBankRowId -> Text -> SqlPersistT m (Either ManualPostingError ())
postRowManually rowId accountName = do
  found <-
    rawSql
      "SELECT r.id, b.ledger_account_id, b.account_kind, r.transaction_date, r.description_1, r.description_2, r.amount_cents \
      \FROM raw_bank_rows r JOIN bank_accounts b ON b.id = r.bank_account_id WHERE r.id = ?"
      [PersistInt64 (fromSqlKey rowId)]
  existing <- currentEntryForRow rowId
  case (map (toEvidenceRow False) found, existing, accountTypeFromName accountName) of
    ([], _, _) -> pure (Left RowNotFound)
    (_, Just _, _) -> pure (Left RowAlreadyPosted)
    (_, _, Nothing) -> pure (Left (UnknownAccount accountName))
    (row : _, Nothing, Just accountType)
      | row.amount == mempty -> pure (Left ZeroAmountRow)
      | otherwise -> do
          counterAccount <- findOrCreateLedgerAccount accountName accountType
          postRow PlannedPosting {row, classification = CategorizedByRule "manual" counterAccount, counterAccount, replacesExistingEntry = False}
          pure (Right ())

-- | The row's entry that is still in effect (posted and not reversed), with
-- its date.
currentEntryForRow :: (MonadIO m) => RawBankRowId -> SqlPersistT m (Maybe (JournalEntryId, Day))
currentEntryForRow rowId = do
  found <-
    rawSql
      "SELECT e.id, e.occurred_on FROM journal_entry_evidence ev \
      \JOIN journal_entries e ON e.id = ev.entry_id \
      \WHERE ev.raw_bank_row_id = ? \
      \  AND NOT EXISTS (SELECT 1 FROM journal_entries r WHERE r.reverses_entry_id = e.id)"
      [PersistInt64 (fromSqlKey rowId)]
  pure (listToMaybe [(entryId, occurredOn) | (Single entryId, Single occurredOn) <- found])

type EvidenceColumns =
  (Single RawBankRowId, Single LedgerAccountId, Single BankAccountKind, Single Day, Single Text, Single Text, Single Cents)

-- | Rows with no entry in effect: never posted, or posted and reversed.
loadUnpostedRows :: (MonadIO m) => SqlPersistT m [EvidenceRow RawBankRowId LedgerAccountId]
loadUnpostedRows = do
  found <-
    rawSql
      "SELECT r.id, b.ledger_account_id, b.account_kind, r.transaction_date, r.description_1, r.description_2, r.amount_cents \
      \FROM raw_bank_rows r JOIN bank_accounts b ON b.id = r.bank_account_id \
      \WHERE NOT EXISTS ( \
      \  SELECT 1 FROM journal_entry_evidence ev \
      \  WHERE ev.raw_bank_row_id = r.id \
      \    AND NOT EXISTS (SELECT 1 FROM journal_entries rev WHERE rev.reverses_entry_id = ev.entry_id)) \
      \ORDER BY r.transaction_date, r.id"
      []
  pure (map (toEvidenceRow False) found)

-- | Rows whose entry in effect was a guess (uncategorized, or a payment to an
-- untracked card), dated on or after the given day. They may still turn out
-- to be half of a transfer: a card payment from chequing is only "untracked"
-- until that card's own export is imported.
loadRepairableRows ::
  (MonadIO m) => WellKnownAccounts LedgerAccountId -> Day -> SqlPersistT m [EvidenceRow RawBankRowId LedgerAccountId]
loadRepairableRows wellKnown since = do
  found <-
    rawSql
      "SELECT r.id, b.ledger_account_id, b.account_kind, r.transaction_date, r.description_1, r.description_2, r.amount_cents \
      \FROM raw_bank_rows r \
      \JOIN bank_accounts b ON b.id = r.bank_account_id \
      \JOIN journal_entry_evidence ev ON ev.raw_bank_row_id = r.id \
      \WHERE r.transaction_date >= ? \
      \  AND NOT EXISTS (SELECT 1 FROM journal_entries rev WHERE rev.reverses_entry_id = ev.entry_id) \
      \  AND EXISTS (SELECT 1 FROM journal_lines l WHERE l.entry_id = ev.entry_id AND l.ledger_account_id IN (?, ?, ?)) \
      \ORDER BY r.transaction_date, r.id"
      [ PersistDay since
      , PersistInt64 (fromSqlKey wellKnown.uncategorizedExpense)
      , PersistInt64 (fromSqlKey wellKnown.uncategorizedIncome)
      , PersistInt64 (fromSqlKey wellKnown.untrackedCards)
      ]
  pure (map (toEvidenceRow True) found)

toEvidenceRow :: Bool -> EvidenceColumns -> EvidenceRow RawBankRowId LedgerAccountId
toEvidenceRow alreadyPosted (Single rowId, Single bankAccount, Single bankAccountKind, Single transactionDate, Single description1, Single description2, Single amount) =
  EvidenceRow {rowId, bankAccount, bankAccountKind, transactionDate, description1, description2, amount, alreadyPosted}

loadRules :: (MonadIO m) => SqlPersistT m [Rule LedgerAccountId]
loadRules = do
  rules <- selectList [] [Asc CategorizationRulePriority, Asc CategorizationRuleId]
  pure
    [ Rule {descriptionContains = categorizationRuleDescriptionContains rule, account = categorizationRuleLedgerAccountId rule}
    | Entity _ rule <- rules
    ]

data RuleError
  = UnknownAccountPrefix Text
  | EmptyRuleText
  | RuleAlreadyExists Text
  deriving stock (Show, Eq)

-- | Adds "description contains TEXT → account". The account is created if
-- it doesn't exist; its type comes from its prefix (@expense:@ etc.).
-- Existing posted entries are not changed. The rule applies to rows posted
-- from now on.
addCategorizationRule :: (MonadIO m) => Text -> Text -> Int -> SqlPersistT m (Either RuleError CategorizationRuleId)
addCategorizationRule rawText accountName priority = do
  let ruleText = normalizeDescription rawText
  case accountTypeFromName accountName of
    _ | Text.null ruleText -> pure (Left EmptyRuleText)
    Nothing -> pure (Left (UnknownAccountPrefix accountName))
    Just accountType -> do
      existing <- getBy (UniqueCategorizationRule ruleText)
      case existing of
        Just _ -> pure (Left (RuleAlreadyExists ruleText))
        Nothing -> do
          accountId <- findOrCreateLedgerAccount accountName accountType
          Right <$> insert CategorizationRule {categorizationRuleDescriptionContains = ruleText, categorizationRuleLedgerAccountId = accountId, categorizationRulePriority = priority}

renderPostingSummary :: PostingSummary -> Text
renderPostingSummary summary =
  Text.unlines $
    postedLines
      <> ["  " <> showText summary.reposted <> " earlier row(s) re-posted after their other half arrived" | summary.reposted > 0]
      <> case summary.leftForReview of
        [] -> []
        items ->
          ("Left for review (" <> showText (length items) <> "), not posted:")
            : [ "  #" <> showText (fromSqlKey rowId) <> "  " <> showText date <> "  " <> renderCents amount <> "  " <> description <> "  (" <> renderReason reason <> ")"
              | (rowId, date, description, amount, reason) <- items
              ]
              <> ["Decide these yourself with: scripts/reckon.sh post-row ROW_ID ACCOUNT  (e.g. asset:clearing for a transfer leg)"]
  where
    postedLines
      | total == 0 = ["Nothing new to post."]
      | otherwise =
          [ "Posted " <> showText total <> " row(s) to the journal:"
          , "  " <> showText summary.categorizedByRule <> " categorized by a rule"
          , "  " <> showText summary.transferLegs <> " transfer leg(s) between your accounts (via asset:clearing)"
          , "  " <> showText summary.cancelledPairLegs <> " cancelled/refunded pair leg(s) (net to zero via asset:clearing)"
          , "  " <> showText summary.untrackedCardPayments <> " payment(s) to untracked credit cards"
          , "  " <> showText summary.uncategorized <> " uncategorized (add rules with: scripts/reckon.sh add-rule TEXT expense:...)"
          ]
    total =
      summary.categorizedByRule + summary.transferLegs + summary.cancelledPairLegs
        + summary.untrackedCardPayments + summary.uncategorized
    renderReason = \case
      ZeroAmount -> "zero amount"
      AmbiguousPair _ -> "looks like half of a transfer or cancellation, but which rows go together is ambiguous"
    showText :: (Show a) => a -> Text
    showText = Text.pack . show
