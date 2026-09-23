-- | Journal entries before they are saved, as pure values.
--
-- The key idea is a /smart constructor/: 'BalancedLines' can only be built
-- by 'mkBalancedLines', which checks the lines. The data constructor isn't
-- exported, so anywhere a 'BalancedLines' exists, it is known to be
-- balanced. The type checker carries that proof around for us.
module Reckon.Ledger.Entry
  ( EntryLine (..)
  , BalancedLines
  , balancedLines
  , mkBalancedLines
  , reverseLines
  , NewJournalEntry
  , mkNewJournalEntry
  , newEntryOccurredOn
  , newEntryDescription
  , newEntryLines
  , EntryError (..)
  ) where

import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (Day)
import Reckon.Database.Schema (LedgerAccountId)
import Reckon.Money (Cents (..), negateCents, sumCents)

-- | One line of an entry: an amount posted to an account. Debit positive,
-- credit negative.
data EntryLine = EntryLine
  { ledgerAccountId :: LedgerAccountId
  , amount :: Cents
  }
  deriving stock (Show, Eq)

-- | At least two lines, none zero, summing to exactly zero.
newtype BalancedLines = BalancedLines [EntryLine]
  deriving stock (Show, Eq)

balancedLines :: BalancedLines -> [EntryLine]
balancedLines (BalancedLines entryLines) = entryLines

data EntryError
  = FewerThanTwoLines
  | ZeroAmountLine
  | LinesDoNotBalance Cents
  -- ^ Carries the non-zero total, e.g. @LinesDoNotBalance (Cents 150)@.
  | EmptyDescription
  deriving stock (Show, Eq)

mkBalancedLines :: [EntryLine] -> Either EntryError BalancedLines
mkBalancedLines entryLines
  | length entryLines < 2 = Left FewerThanTwoLines
  | any ((== mempty) . (.amount)) entryLines = Left ZeroAmountLine
  | total /= mempty = Left (LinesDoNotBalance total)
  | otherwise = Right (BalancedLines entryLines)
  where
    total = sumCents (map (.amount) entryLines)

-- | The lines that exactly cancel these ones. Negating every line of a
-- balanced set gives another balanced set, so this can't fail and returns
-- 'BalancedLines' directly.
reverseLines :: BalancedLines -> BalancedLines
reverseLines (BalancedLines entryLines) =
  BalancedLines [line {amount = negateCents line.amount} | line <- entryLines]

-- | A valid entry, ready to post. Built only by 'mkNewJournalEntry'.
--
-- The fields are not exported (only the getter functions below are). If they
-- were, record-update syntax (@entry {description = ""}@) would let other
-- modules skip the validation.
data NewJournalEntry = NewJournalEntry
  { occurredOn :: Day
  , description :: Text
  , entryLines :: BalancedLines
  }
  deriving stock (Show, Eq)

newEntryOccurredOn :: NewJournalEntry -> Day
newEntryOccurredOn entry = entry.occurredOn

newEntryDescription :: NewJournalEntry -> Text
newEntryDescription entry = entry.description

newEntryLines :: NewJournalEntry -> BalancedLines
newEntryLines entry = entry.entryLines

mkNewJournalEntry :: Day -> Text -> BalancedLines -> Either EntryError NewJournalEntry
mkNewJournalEntry occurredOn description entryLines
  | Text.null (Text.strip description) = Left EmptyDescription
  | otherwise = Right (NewJournalEntry occurredOn description entryLines)
