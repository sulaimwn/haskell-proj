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
  , recategorizeRow
  , ManualPostingError (..)
  , loadEvidenceRow
  , repostRow
  , RepostError (..)
  , manualErrorFromRepost
  , wellKnownAccounts
  , currentEntryForRow
  , ReviewItem (..)
  , reviewItems
  ) where

import Control.Monad (forM_, when)
import Control.Monad.IO.Class (MonadIO)
import Data.Bifunctor (first)
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (Day, addDays)
import Database.Persist (insert_)
import Database.Persist.Sql (PersistValue (..), Single (..), SqlPersistT, fromSqlKey, rawSql)
import Reckon.Bank (BankAccountKind)
import Reckon.Database.Schema
import Reckon.Ledger (accountTypeFromName, findOrCreateLedgerAccount, postEntry, postReversal)
import Reckon.Ledger.AccountType (AccountType (..))
import Reckon.Ledger.Entry (EntryError, EntryLine (..), NewJournalEntry, mkBalancedLines, mkNewJournalEntry)
import Reckon.Money (Cents (..), negateCents, renderCents)
import Reckon.People (loadKnownPeople)
import Reckon.Posting.Classify
import Reckon.Rules (loadRules)
import Reckon.Screenshot.Store (confirmProvisionalRows)

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
  , confirmedProvisional :: Int
  -- ^ Rows read from screenshots and posted provisionally, now confirmed by
  -- the bank's own row (the provisional entry was reversed).
  , leftForReview :: [(RawBankRowId, Day, Text, Cents, ReviewReason RawBankRowId)]
  }
  deriving stock (Show, Eq)

postPendingRows :: (MonadIO m) => SqlPersistT m PostingSummary
postPendingRows = do
  -- Rows read from screenshots give way to the bank's own rows first: the
  -- provisional entry is reversed, then the bank's row is posted below.
  confirmed <- confirmProvisionalRows
  plan <- planCurrentRows

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
      , confirmedProvisional = confirmed
      , leftForReview =
          [ (row.rowId, row.transactionDate, entryDescription row, row.amount, reason)
          | (row, reason) <- plan.leftForReview
          ]
      }
  where
    isClassification predicate planned = predicate planned.classification
    isRule = \case CategorizedByRule _ _ -> True; SplitByRule _ _ -> True; _ -> False
    isTransfer = \case TransferWith _ -> True; _ -> False
    isCancelledPair = \case CancelledPairWith _ -> True; _ -> False

-- | What posting would do right now, without doing it: every unposted row,
-- plus rows posted on a guess that a new row might pair with.
planCurrentRows :: (MonadIO m) => SqlPersistT m (PostingPlan RawBankRowId LedgerAccountId)
planCurrentRows = do
  wellKnown <- wellKnownAccounts
  rules <- loadRules
  people <- loadKnownPeople
  unposted <- loadUnpostedRows
  -- Rows already posted on a guess (uncategorized, or "payment to an
  -- untracked card") can pair with a newly imported row, within the widest
  -- pairing window of the new rows.
  pairable <- case map (.transactionDate) unposted of
    [] -> pure []
    dates -> loadRepairableRows wellKnown (addDays (negate cancellationWindowDays) (minimum dates))
  pure (planPosting wellKnown rules people (unposted <> pairable))

-- | An imported row that posting leaves for a person to decide.
data ReviewItem = ReviewItem
  { rowId :: RawBankRowId
  , account :: Text
  , date :: Day
  , description :: Text
  , amount :: Cents
  , reason :: ReviewReason RawBankRowId
  }
  deriving stock (Show, Eq)

-- | The rows the next @post@ would leave for review, without posting
-- anything.
reviewItems :: (MonadIO m) => SqlPersistT m [ReviewItem]
reviewItems = do
  plan <- planCurrentRows
  nicknames <- rawSql "SELECT ledger_account_id, nickname FROM bank_accounts" []
  let nicknameOf ledgerAccount = Map.findWithDefault "" ledgerAccount (Map.fromList [(accountId, nickname) | (Single accountId, Single nickname) <- nicknames])
  pure
    [ ReviewItem
        { rowId = row.rowId
        , account = nicknameOf row.bankAccount
        , date = row.transactionDate
        , description = entryDescription row
        , amount = row.amount
        , reason
        }
    | (row, reason) <- plan.leftForReview
    ]

-- | One entry per row: the row's amount on its bank's ledger account,
-- balanced by the counter account, with the row recorded as its evidence.
postRow :: (MonadIO m) => PlannedPosting RawBankRowId LedgerAccountId -> SqlPersistT m ()
postRow planned = do
  let row = planned.row
      counterLines = case planned.classification of
        -- A split rule decided who pays what; everything else is one counter account.
        SplitByRule _ parts -> parts
        _ -> [(planned.counterAccount, negateCents row.amount)]
  case buildEntry row counterLines of
    -- Can't happen: zero-amount rows are left for review, and the two lines
    -- negate each other by construction.
    Left entryError -> error ("postRow: " <> show entryError)
    Right newEntry -> postWithEvidence row newEntry

-- | The row's amount on its bank's ledger account, and the given amounts on
-- other accounts. They must add up to zero, or the entry is rejected.
buildEntry :: EvidenceRow RawBankRowId LedgerAccountId -> [(LedgerAccountId, Cents)] -> Either EntryError NewJournalEntry
buildEntry row counterLines =
  mkBalancedLines
    ( EntryLine {ledgerAccountId = row.bankAccount, amount = row.amount}
        : [EntryLine {ledgerAccountId = counterAccount, amount} | (counterAccount, amount) <- counterLines]
    )
    >>= mkNewJournalEntry row.transactionDate (entryDescription row)

postWithEvidence :: (MonadIO m) => EvidenceRow RawBankRowId LedgerAccountId -> NewJournalEntry -> SqlPersistT m ()
postWithEvidence row newEntry = do
  entryId <- postEntry newEntry
  insert_ JournalEntryEvidence {journalEntryEvidenceEntryId = entryId, journalEntryEvidenceRawBankRowId = row.rowId}

data RepostError
  = -- | The row's entry in effect is one leg of a transfer or cancelled
    -- pair. Re-posting one leg would leave the clearing account out of
    -- balance, so a person has to look at the pair as a whole.
    RepostPartOfPair
  | RepostZeroAmount
  | RepostUnbalanced EntryError
  deriving stock (Show, Eq)

-- | Posts the row against the given counter amounts (which must add up to
-- the negated row amount), first reversing its entry in effect, if any. The
-- reversal is dated like the entry it reverses, so the bank account's
-- balance on every date is unchanged by the change (D042).
--
-- Nothing is written unless everything checks out.
repostRow :: (MonadIO m) => EvidenceRow RawBankRowId LedgerAccountId -> [(LedgerAccountId, Cents)] -> SqlPersistT m (Either RepostError ())
repostRow row counterLines = do
  existing <- currentEntryForRow row.rowId
  partOfPair <- maybe (pure False) (touchesClearingAccount . fst) existing
  case buildEntry row counterLines of
    _ | partOfPair -> pure (Left RepostPartOfPair)
    _ | row.amount == mempty -> pure (Left RepostZeroAmount)
    Left entryError -> pure (Left (RepostUnbalanced entryError))
    Right newEntry -> do
      forM_ existing $ \(entryId, occurredOn) -> postReversal entryId occurredOn
      postWithEvidence row newEntry
      pure (Right ())

touchesClearingAccount :: (MonadIO m) => JournalEntryId -> SqlPersistT m Bool
touchesClearingAccount entryId = do
  found <-
    rawSql
      "SELECT EXISTS (SELECT 1 FROM journal_lines l JOIN ledger_accounts a ON a.id = l.ledger_account_id \
      \WHERE l.entry_id = ? AND a.name = 'asset:clearing')"
      [PersistInt64 (fromSqlKey entryId)]
  pure (found == [Single True])

entryDescription :: EvidenceRow rowId account -> Text
entryDescription row = case (Text.strip row.description1, Text.strip row.description2) of
  (one, "") -> one
  ("", two) -> two
  (one, two) -> one <> " - " <> two

data ManualPostingError
  = RowNotFound
  | RowAlreadyPosted
  | UnknownAccount Text
  | ZeroAmountRow
  | -- | See 'RepostPartOfPair'.
    RowIsPartOfPair
  | EntryRejected EntryError
  deriving stock (Show, Eq)

-- | Posts one unposted row against an account you choose: the way to settle
-- a row left for review. The account is created if needed (its type comes
-- from its prefix). Posting both legs of an ambiguous transfer to
-- @asset:clearing@ records them as a transfer.
postRowManually :: (MonadIO m) => RawBankRowId -> Text -> SqlPersistT m (Either ManualPostingError ())
postRowManually rowId accountName = do
  found <- loadEvidenceRow rowId
  existing <- currentEntryForRow rowId
  case (found, existing, accountTypeFromName accountName) of
    (Nothing, _, _) -> pure (Left RowNotFound)
    (_, Just _, _) -> pure (Left RowAlreadyPosted)
    (_, _, Nothing) -> pure (Left (UnknownAccount accountName))
    (Just row, Nothing, Just accountType)
      | row.amount == mempty -> pure (Left ZeroAmountRow)
      | otherwise -> do
          counterAccount <- findOrCreateLedgerAccount accountName accountType
          postRow PlannedPosting {row, classification = CategorizedByRule "manual" counterAccount, counterAccount, replacesExistingEntry = False}
          pure (Right ())

-- | Moves an already-posted row to a different account: the way to fix a
-- row that was categorized by a guess, or before a rule existed. The old
-- entry is reversed (on its own date) and the row posted again. A row that
-- isn't posted yet is simply posted. Transfer and cancellation legs can't
-- be moved on their own.
recategorizeRow :: (MonadIO m) => RawBankRowId -> Text -> SqlPersistT m (Either ManualPostingError ())
recategorizeRow rowId accountName = do
  found <- loadEvidenceRow rowId
  case (found, accountTypeFromName accountName) of
    (Nothing, _) -> pure (Left RowNotFound)
    (_, Nothing) -> pure (Left (UnknownAccount accountName))
    (Just row, Just accountType) -> do
      counterAccount <- findOrCreateLedgerAccount accountName accountType
      first manualErrorFromRepost <$> repostRow row [(counterAccount, negateCents row.amount)]

manualErrorFromRepost :: RepostError -> ManualPostingError
manualErrorFromRepost = \case
  RepostPartOfPair -> RowIsPartOfPair
  RepostZeroAmount -> ZeroAmountRow
  RepostUnbalanced entryError -> EntryRejected entryError

-- | One imported row, whether or not it has been posted. 'alreadyPosted' is
-- left False: callers that care ask 'currentEntryForRow'.
loadEvidenceRow :: (MonadIO m) => RawBankRowId -> SqlPersistT m (Maybe (EvidenceRow RawBankRowId LedgerAccountId))
loadEvidenceRow rowId = do
  found <-
    rawSql
      "SELECT r.id, b.ledger_account_id, b.account_kind, r.transaction_date, r.description_1, r.description_2, r.amount_cents \
      \FROM raw_bank_rows r JOIN bank_accounts b ON b.id = r.bank_account_id WHERE r.id = ?"
      [PersistInt64 (fromSqlKey rowId)]
  pure (listToMaybe (map (toEvidenceRow False) found))

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

renderPostingSummary :: PostingSummary -> Text
renderPostingSummary summary =
  Text.unlines $
    postedLines
      <> ["  " <> showText summary.reposted <> " earlier row(s) re-posted after their other half arrived" | summary.reposted > 0]
      <> ["  " <> showText summary.confirmedProvisional <> " provisional entr(ies) read from screenshots confirmed by the bank's rows" | summary.confirmedProvisional > 0]
      <> case summary.leftForReview of
        [] -> []
        items ->
          ("Left for review (" <> showText (length items) <> "), not posted:")
            : [ "  #" <> showText (fromSqlKey rowId) <> "  " <> showText date <> "  " <> renderCents amount <> "  " <> description <> "  (" <> renderReason rowId reason <> ")"
              | (rowId, date, description, amount, reason) <- items
              ]
              <> ["Decide these yourself with: scripts/reckon.sh post-row ROW_ID ACCOUNT  (e.g. asset:clearing for a transfer leg, receivable:NAME for a repayment)"]
  where
    postedLines
      | total == 0 && summary.confirmedProvisional == 0 = ["Nothing new to post."]
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
    renderReason rowId = \case
      ZeroAmount -> "zero amount"
      AmbiguousPair _ -> "looks like half of a transfer or cancellation, but which rows go together is ambiguous"
      PossibleRepayment names ->
        "might be a repayment from " <> Text.intercalate " or " names <> "; if so: scripts/reckon.sh post-row "
          <> showText (fromSqlKey rowId) <> " receivable:" <> Text.intercalate " or receivable:" names
    showText :: (Show a) => a -> Text
    showText = Text.pack . show
