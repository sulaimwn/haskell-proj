-- | What the screens show (Phase 6): read-only queries, answered in the
-- API's own types ("Reckon.Api.Types").
--
-- Nothing here changes anything. Each function answers one question the
-- frontend asks, and the handlers in "Reckon.Server" are thin wrappers
-- around them.
module Reckon.Views
  ( accountSummaries
  , TransactionFilter (..)
  , transactionsFor
  , spendingByMonth
  , receivablesView
  , reviewQueue
  , ledgerAccountViews
  ) where

import Control.Applicative ((<|>))
import Control.Monad (forM)
import Control.Monad.IO.Class (MonadIO)
import Data.Aeson qualified as Aeson
import Data.Int (Int64)
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust, listToMaybe)
import Data.Ord (Down (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Time (Day)
import Database.Persist (Entity (..), selectList, (==.))
import Database.Persist.Sql (PersistValue (..), Single (..), SqlPersistT, fromSqlKey, rawSql)
import Database.Persist.Types (SelectOpt (..))
import Reckon.Api.Types
import Reckon.Bank (BankAccountKind (..), last4Text)
import Reckon.Database.Schema
import Reckon.Ledger (accountBalanceAsOf)
import Reckon.Ledger.AccountType (accountTypeToText, naturalBalance)
import Reckon.Money (Cents (..))
import Reckon.People (PersonOwes (..), whoOwesWhat)
import Reckon.Posting (ReviewItem (..), reviewItems)
import Reckon.Posting.Classify (ReviewReason (..))
import Reckon.Reconcile (ReconciliationReport (..), bankLedgerType, reconcileAccount, renderFindings)
import Reckon.Reconcile.Explain (Finding (..), ReconciliationInputs (..))
import Reckon.Screenshot.Store (OpenProvisional (..), openProvisionalRows)

wireCents :: Cents -> Int
wireCents (Cents amount) = fromIntegral amount

isoDay :: Day -> Text
isoDay = Text.pack . show

-- | Every bank account: its balance today, what's waiting on it, and how
-- the ledger compared with the latest statement balance recorded for it.
accountSummaries :: (MonadIO m) => Day -> SqlPersistT m [AccountSummary]
accountSummaries today = do
  accounts <- selectList [] [Asc BankAccountId]
  forM accounts $ \account@(Entity bankAccountId bankAccount) -> do
    rawBalance <- accountBalanceAsOf (bankAccountLedgerAccountId bankAccount) today
    unposted <- countOf "SELECT count(*) FROM raw_bank_rows r WHERE r.bank_account_id = ? AND NOT EXISTS (SELECT 1 FROM journal_entry_evidence ev WHERE ev.raw_bank_row_id = r.id AND NOT EXISTS (SELECT 1 FROM journal_entries rev WHERE rev.reverses_entry_id = ev.entry_id))" bankAccountId
    provisional <- countOf "SELECT count(*) FROM screenshot_rows s WHERE s.bank_account_id = ? AND NOT EXISTS (SELECT 1 FROM provisional_resolutions p WHERE p.screenshot_row_id = s.id)" bankAccountId
    checkpoints <- selectList [StatementCheckpointBankAccountId ==. bankAccountId] [Desc StatementCheckpointAsOfDate, LimitTo 1]
    latest <- forM (take 1 checkpoints) $ \(Entity _ checkpoint) -> do
      report <- reconcileAccount account (statementCheckpointAsOfDate checkpoint) (statementCheckpointStatementBalanceCents checkpoint)
      let reconciled = report.findings == [Reconciled]
      pure
        CheckpointSummary
          { asOf = isoDay report.inputs.asOf
          , statementBalanceCents = wireCents report.inputs.statementBalance
          , ledgerBalanceCents = wireCents report.inputs.ledgerBalance
          , state = if reconciled then ReconciliationReconciled else ReconciliationGap
          , explanation = if reconciled then [] else renderFindings report.findings
          }
    pure
      AccountSummary
        { last4 = last4Text (bankAccountLast4 bankAccount)
        , nickname = bankAccountNickname bankAccount
        , kind = kindText (bankAccountAccountKind bankAccount)
        , balanceCents = wireCents (naturalBalance (bankLedgerType bankAccount) rawBalance)
        , unpostedRows = unposted
        , openProvisional = provisional
        , latestCheckpoint = listToMaybe latest
        }
  where
    countOf query bankAccountId = do
      found <- rawSql query [PersistInt64 (fromSqlKey bankAccountId)]
      pure (sum [fromIntegral (total :: Int64) | Single total <- found])
    kindText = \case
      Chequing -> "chequing"
      Savings -> "savings"
      CreditCard -> "credit_card"

data TransactionFilter = TransactionFilter
  { from :: Maybe Day
  , to :: Maybe Day
  , search :: Maybe Text
  -- ^ Matched anywhere in the description, ignoring case.
  , limit :: Int
  }
  deriving stock (Show, Eq)

-- | The entries on a bank account as the bank shows them, newest first.
-- Entries that were reversed, and the reversals themselves, are left out:
-- this is what the ledger says now, not its history.
transactionsFor :: (MonadIO m) => Entity BankAccount -> TransactionFilter -> SqlPersistT m [TransactionView]
transactionsFor (Entity _ bankAccount) filters = do
  let ledgerAccount = PersistInt64 (fromSqlKey (bankAccountLedgerAccountId bankAccount))
      optionalDay = maybe PersistNull PersistDay
      optionalText = maybe PersistNull PersistText
  found <-
    rawSql
      "SELECT e.id, e.occurred_on, e.description, bl.amount_cents, ev.raw_bank_row_id, sev.screenshot_row_id, (ob.entry_id IS NOT NULL), \
      \  (SELECT coalesce(json_agg(json_build_object('account', a.name, 'amountCents', l.amount_cents) ORDER BY a.name, l.id), '[]'::json)::text \
      \     FROM journal_lines l JOIN ledger_accounts a ON a.id = l.ledger_account_id \
      \    WHERE l.entry_id = e.id AND l.ledger_account_id <> ?) \
      \FROM journal_entries e \
      \JOIN journal_lines bl ON bl.entry_id = e.id AND bl.ledger_account_id = ? \
      \LEFT JOIN journal_entry_evidence ev ON ev.entry_id = e.id \
      \LEFT JOIN screenshot_entry_evidence sev ON sev.entry_id = e.id \
      \LEFT JOIN opening_balances ob ON ob.entry_id = e.id \
      \WHERE e.reverses_entry_id IS NULL \
      \  AND NOT EXISTS (SELECT 1 FROM journal_entries r WHERE r.reverses_entry_id = e.id) \
      \  AND (?::date IS NULL OR e.occurred_on >= ?::date) \
      \  AND (?::date IS NULL OR e.occurred_on <= ?::date) \
      \  AND (?::text IS NULL OR position(lower(?::text) in lower(e.description)) > 0) \
      \ORDER BY e.occurred_on DESC, e.id DESC \
      \LIMIT ?"
      [ ledgerAccount
      , ledgerAccount
      , optionalDay filters.from
      , optionalDay filters.from
      , optionalDay filters.to
      , optionalDay filters.to
      , optionalText filters.search
      , optionalText filters.search
      , PersistInt64 (fromIntegral filters.limit)
      ]
  pure
    [ TransactionView
        { entryId = fromIntegral (entryId :: Int64)
        , date = isoDay date
        , description
        , amountCents = fromIntegral (amount :: Int64)
        , counterLines = fromMaybe [] (Aeson.decodeStrict (Text.encodeUtf8 countersJson))
        , source = case (csvRow, screenshotRow, isOpening) of
            (Just _, _, _) -> SourceCsv
            (_, Just _, _) -> SourceScreenshot
            (_, _, True) -> SourceOpeningBalance
            _ -> SourceOther
        , rowId = fmap fromIntegral (csvRow <|> screenshotRow :: Maybe Int64)
        , provisional = isJust screenshotRow
        }
    | (Single entryId, Single date, Single description, Single amount, Single csvRow, Single screenshotRow, Single isOpening, Single countersJson) <- found
    ]

-- | Spending by expense account, month by month, newest month first. Only
-- expense accounts count, so friends' shares and transfers aren't in it
-- (DECISIONS D052).
spendingByMonth :: (MonadIO m) => Day -> Day -> SqlPersistT m [SpendingMonth]
spendingByMonth from to = do
  found <-
    rawSql
      "SELECT to_char(e.occurred_on, 'YYYY-MM'), a.name, sum(l.amount_cents)::bigint \
      \FROM journal_lines l \
      \JOIN journal_entries e ON e.id = l.entry_id \
      \JOIN ledger_accounts a ON a.id = l.ledger_account_id \
      \WHERE a.account_type = 'expense' AND e.occurred_on BETWEEN ? AND ? \
      \GROUP BY 1, 2 HAVING sum(l.amount_cents) <> 0 \
      \ORDER BY 1 DESC, 3 DESC, 2"
      [PersistDay from, PersistDay to]
  let byMonth = Map.fromListWith (flip (<>)) [(month, [SpendingLine {account, cents = fromIntegral (total :: Int64)}]) | (Single month, Single account, Single total) <- found]
  pure
    [ SpendingMonth {month, totalCents = sum (map (.cents) lines'), categories = sortOn (Down . (.cents)) lines'}
    | (month, lines') <- sortOn (Down . fst) (Map.toList byMonth)
    ]

receivablesView :: (MonadIO m) => Day -> SqlPersistT m ReceivablesResponse
receivablesView today = do
  owed <- whoOwesWhat today
  let people = [PersonBalance {name = person.name, owedCents = wireCents person.owes} | person <- owed]
  pure ReceivablesResponse {people, totalOwedCents = sum (map (.owedCents) people)}

-- | Everything waiting for a person: rows posting won't decide, rows read
-- from screenshots no bank export has confirmed, and what imports flagged.
reviewQueue :: (MonadIO m) => SqlPersistT m ReviewQueue
reviewQueue = do
  items <- reviewItems
  provisional <- openProvisionalRows
  flags <-
    rawSql
      "SELECT i.kind, b.nickname, r.transaction_date, r.description_1, r.description_2, r.amount_cents, rr.description_1, rr.description_2 \
      \FROM import_review_items i \
      \JOIN bank_accounts b ON b.id = i.bank_account_id \
      \JOIN raw_bank_rows r ON r.id = i.raw_bank_row_id \
      \LEFT JOIN raw_bank_rows rr ON rr.id = i.related_raw_bank_row_id \
      \ORDER BY r.transaction_date DESC, i.id DESC LIMIT 200"
      []
  pure
    ReviewQueue
      { unposted = map reviewRowFrom items
      , provisional =
          [ ProvisionalRow
              { screenshotRowId = fromIntegral (fromSqlKey row.screenshotRowId)
              , account = row.account
              , date = isoDay row.date
              , description = row.description
              , amountCents = wireCents row.amount
              , pending = row.pending
              , posted = row.posted
              }
          | row <- provisional
          ]
      , importFlags =
          [ ImportFlag
              { kind = if kind == ("possible_duplicate" :: Text) then ImportFlagPossibleDuplicate else ImportFlagMissingFromNewerExport
              , account
              , date = isoDay date
              , description = joinDescriptions first second
              , amountCents = fromIntegral (amount :: Int64)
              , relatedDescription = case (relatedFirst, relatedSecond) of
                  (Nothing, Nothing) -> Nothing
                  (one, two) -> Just (joinDescriptions (fromMaybe "" one) (fromMaybe "" two))
              }
          | (Single kind, Single account, Single date, Single first, Single second, Single amount, Single relatedFirst, Single relatedSecond) <- flags
          ]
      }

reviewRowFrom :: ReviewItem -> ReviewRow
reviewRowFrom item =
  ReviewRow
    { rowId = fromIntegral (fromSqlKey item.rowId)
    , account = item.account
    , date = isoDay item.date
    , description = item.description
    , amountCents = wireCents item.amount
    , reason = case item.reason of
        AmbiguousPair _ -> ReviewAmbiguousPair
        ZeroAmount -> ReviewZeroAmount
        PossibleRepayment _ -> ReviewPossibleRepayment
    , detail = case item.reason of
        AmbiguousPair _ -> "Looks like half of a transfer or a cancellation, but which rows go together is ambiguous."
        ZeroAmount -> "A zero amount can't be posted."
        PossibleRepayment names -> "Might be a repayment from " <> Text.intercalate " or " names <> "."
    , people = case item.reason of
        PossibleRepayment names -> names
        _ -> []
    }

joinDescriptions :: Text -> Text -> Text
joinDescriptions first second = Text.strip (first <> " " <> second)

ledgerAccountViews :: (MonadIO m) => SqlPersistT m [LedgerAccountView]
ledgerAccountViews = do
  accounts <- selectList [] [Asc LedgerAccountName]
  pure [LedgerAccountView {name = ledgerAccountName account, accountType = accountTypeToText (ledgerAccountAccountType account)} | Entity _ account <- accounts]
