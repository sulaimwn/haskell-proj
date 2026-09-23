-- | Why doesn't the ledger match the statement? Pure: given the numbers,
-- say what explains the gap (DECISIONS D043).
--
-- The central invariant of reckon is that, for every bank account, the
-- ledger balance on a statement date equals the balance printed on the
-- statement. When it doesn't, a bare "off by $12.34" is useless. This
-- module looks for the specific cause.
module Reckon.Reconcile.Explain
  ( ReconciliationInputs (..)
  , EvidenceSummary (..)
  , Finding (..)
  , explainReconciliation
  , coverageGaps
  ) where

import Data.List (sortOn)
import Data.Text (Text)
import Data.Time (Day, addDays)
import Reckon.Money (Cents (..), negateCents, sumCents)

-- | A bank row as the report shows it. The amount is in the statement's
-- sign convention (natural balance: money in a chequing account, money
-- owed on a card).
data EvidenceSummary = EvidenceSummary
  { transactionDate :: Day
  , description :: Text
  , naturalAmount :: Cents
  }
  deriving stock (Show, Eq)

data ReconciliationInputs = ReconciliationInputs
  { asOf :: Day
  , statementBalance :: Cents
  , ledgerBalance :: Cents
  -- ^ Both in the natural sign convention.
  , unpostedRows :: [EvidenceSummary]
  -- ^ Imported but not posted, dated on or before 'asOf'.
  , possibleDuplicates :: [EvidenceSummary]
  -- ^ Rows flagged as possible duplicates at import, on or before 'asOf'.
  , openingBalanceDate :: Maybe Day
  , firstTransactionDate :: Maybe Day
  , coveredRanges :: [(Day, Day)]
  -- ^ Date ranges the imported exports covered (first to last date).
  }
  deriving stock (Show, Eq)

data Finding
  = Reconciled
  | -- | Posting these rows would close the gap exactly.
    UnpostedRowsExplainGap [EvidenceSummary]
  | -- | One unposted row's amount equals the gap.
    UnpostedRowMatchesGap EvidenceSummary
  | -- | No opening balance is recorded, so the ledger starts from zero
    -- while the bank account didn't. The gap may be the opening balance.
    NoOpeningBalance Cents
  | -- | Removing this possible duplicate would close the gap exactly.
    DuplicateMatchesGap EvidenceSummary
  | -- | Days between the opening balance (or first transaction) and the
    -- statement date that no imported export covers. Transactions on those
    -- days are missing.
    UncoveredDays [(Day, Day)]
  | -- | None of the above explains it. The difference is statement minus ledger.
    Unexplained Cents
  deriving stock (Show, Eq)

explainReconciliation :: ReconciliationInputs -> [Finding]
explainReconciliation inputs
  -- When the balance matches, days no export includes had no transactions:
  -- nothing to report.
  | difference == mempty = [Reconciled]
  | otherwise =
      case findings of
        [] -> [Unexplained difference]
        _ -> findings
  where
    difference = inputs.statementBalance <> negateCents inputs.ledgerBalance
    findings =
      concat
        [ [UnpostedRowsExplainGap inputs.unpostedRows | not (null inputs.unpostedRows), sumCents (map (.naturalAmount) inputs.unpostedRows) == difference]
        , [ UnpostedRowMatchesGap row
          | length inputs.unpostedRows > 1
          , row <- inputs.unpostedRows
          , row.naturalAmount == difference
          ]
        , [NoOpeningBalance difference | inputs.openingBalanceDate == Nothing]
        , [DuplicateMatchesGap row | row <- inputs.possibleDuplicates, row.naturalAmount == negateCents difference]
        , [UncoveredDays gaps | not (null gaps)]
        ]
    gaps = case inputs.openingBalanceDate of
      -- Coverage must be continuous from the day after the opening balance.
      Just openingDate -> coverageGaps (addDays 1 openingDate) inputs.asOf inputs.coveredRanges
      -- Without one, from the first imported transaction.
      Nothing -> maybe [] (\firstDate -> coverageGaps firstDate inputs.asOf inputs.coveredRanges) inputs.firstTransactionDate

-- | The days in @[from, to]@ that none of the covered ranges include, as
-- maximal runs of consecutive days.
coverageGaps :: Day -> Day -> [(Day, Day)] -> [(Day, Day)]
coverageGaps from to covered
  | from > to = []
  | otherwise = go from (sortOn fst [(max from start, min to end) | (start, end) <- covered, end >= from, start <= to])
  where
    go current []
      | current <= to = [(current, to)]
      | otherwise = []
    go current ((start, end) : rest)
      | current > to = []
      | start > current = (current, addDays (-1) start) : go (max current (addDays 1 end)) rest
      | otherwise = go (max current (addDays 1 end)) rest
