-- | Ledger operations against the database: create accounts, post entries,
-- post reversals, and read balances.
--
-- Every function runs in 'SqlPersistT', i.e. /inside/ a database
-- transaction that the caller opens (with @runSqlPool@). An entry and its
-- lines are therefore always inserted in one transaction, and the
-- database's deferred balance check runs when that transaction commits.
module Reckon.Ledger
  ( createLedgerAccount
  , postEntry
  , postReversal
  , ReversalError (..)
  , accountBalanceAsOf
  ) where

import Control.Monad (forM_)
import Control.Monad.IO.Class (MonadIO)
import Data.Ratio (denominator, numerator)
import Data.Text (Text)
import Data.Time (Day)
import Database.Esqueleto.Experimental qualified as E
import Database.Persist (Entity (..), get, insert, insert_, selectFirst, selectList, (==.))
import Database.Persist.Sql (SqlPersistT)
import Reckon.Database.Schema
import Reckon.Ledger.AccountType (AccountType)
import Reckon.Ledger.Entry
import Reckon.Money (Cents (..))

-- | Creates a CAD ledger account. The name must look like
-- @type:detail@ (e.g. @expense:food@); the database rejects anything else.
createLedgerAccount :: (MonadIO m) => Text -> AccountType -> SqlPersistT m LedgerAccountId
createLedgerAccount name accountType =
  insert
    LedgerAccount
      { ledgerAccountName = name
      , ledgerAccountAccountType = accountType
      , ledgerAccountCurrency = "CAD"
      }

-- | Inserts the entry and its lines. The lines are already known to balance
-- (the type says so), and the database checks again at commit.
postEntry :: (MonadIO m) => NewJournalEntry -> SqlPersistT m JournalEntryId
postEntry entry = insertEntry (newEntryOccurredOn entry) (newEntryDescription entry) Nothing (newEntryLines entry)

data ReversalError
  = EntryNotFound JournalEntryId
  | EntryAlreadyReversed JournalEntryId JournalEntryId
  -- ^ The entry, and the reversal that already cancelled it.
  | StoredEntryIsInvalid JournalEntryId EntryError
  -- ^ Can only happen if the database's own checks were bypassed.
  deriving stock (Show, Eq)

-- | Posts an entry that exactly cancels an earlier one, dated @reversalDate@.
-- This is the only way to "undo" anything: the journal is append-only.
postReversal :: (MonadIO m) => JournalEntryId -> Day -> SqlPersistT m (Either ReversalError JournalEntryId)
postReversal originalEntryId reversalDate = do
  maybeOriginal <- get originalEntryId
  existingReversal <- selectFirst [JournalEntryReversesEntryId ==. Just originalEntryId] []
  originalLines <- selectList [JournalLineEntryId ==. originalEntryId] []
  case (maybeOriginal, existingReversal) of
    (Nothing, _) -> pure (Left (EntryNotFound originalEntryId))
    (Just _, Just (Entity reversalId _)) -> pure (Left (EntryAlreadyReversed originalEntryId reversalId))
    (Just original, Nothing) ->
      case mkBalancedLines (map toEntryLine originalLines) of
        Left entryError -> pure (Left (StoredEntryIsInvalid originalEntryId entryError))
        Right storedLines ->
          Right
            <$> insertEntry
              reversalDate
              ("Reversal of: " <> journalEntryDescription original)
              (Just originalEntryId)
              (reverseLines storedLines)
  where
    toEntryLine (Entity _ line) =
      EntryLine {ledgerAccountId = journalLineLedgerAccountId line, amount = journalLineAmountCents line}

insertEntry :: (MonadIO m) => Day -> Text -> Maybe JournalEntryId -> BalancedLines -> SqlPersistT m JournalEntryId
insertEntry occurredOn description reversesEntryId entryLines = do
  entryId <-
    insert
      JournalEntry
        { journalEntryOccurredOn = occurredOn
        , journalEntryDescription = description
        , journalEntryReversesEntryId = reversesEntryId
        }
  forM_ (balancedLines entryLines) $ \line ->
    insert_
      JournalLine
        { journalLineEntryId = entryId
        , journalLineLedgerAccountId = line.ledgerAccountId
        , journalLineAmountCents = line.amount
        }
  pure entryId

-- | The raw balance of an account (debits positive, credits negative),
-- counting every entry that occurred on or before the given date.
-- Use 'Reckon.Ledger.AccountType.naturalBalance' to display it.
accountBalanceAsOf :: (MonadIO m) => LedgerAccountId -> Day -> SqlPersistT m Cents
accountBalanceAsOf accountId asOf = do
  totals <- E.select $ do
    (line E.:& entry) <-
      E.from $
        E.table @JournalLine
          `E.innerJoin` E.table @JournalEntry
          `E.on` (\(line E.:& entry) -> line E.^. JournalLineEntryId E.==. entry E.^. JournalEntryId)
    E.where_ $
      (line E.^. JournalLineLedgerAccountId E.==. E.val accountId)
        E.&&. (entry E.^. JournalEntryOccurredOn E.<=. E.val asOf)
    -- SUM over BIGINT is NUMERIC in Postgres, which arrives as a Rational.
    pure (E.sum_ (line E.^. JournalLineAmountCents))
  case totals of
    -- No lines yet: SUM of zero rows is NULL.
    [E.Value Nothing] -> pure mempty
    -- A sum of BIGINTs is always a whole number.
    [E.Value (Just (total :: Rational))]
      | denominator total == 1 -> pure (Cents (fromInteger (numerator total)))
    _ -> error ("accountBalanceAsOf: unexpected SUM result " <> show totals)
