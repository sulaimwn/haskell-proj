module Reckon.Reconcile.ExplainSpec (spec) where

import Data.Time (Day, addDays, fromGregorian)
import Hedgehog (forAll, (===))
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import Reckon.Money (Cents (..))
import Reckon.Reconcile.Explain
import Test.Hspec
import Test.Hspec.Hedgehog (hedgehog)

spec :: Spec
spec = do
  describe "explainReconciliation" $ do
    it "reports a match as reconciled, and nothing else" $
      explainReconciliation (inputs 155243 155243) `shouldBe` [Reconciled]

    it "points at the unposted rows that close the gap" $ do
      let unposted = [EvidenceSummary (day 14) "Online Banking transfer" (Cents (-20000))]
      explainReconciliation (inputs 155243 175243) {unpostedRows = unposted}
        `shouldBe` [UnpostedRowsExplainGap unposted]

    it "suggests the opening balance when none is recorded" $
      explainReconciliation (inputs 155243 55243) {openingBalanceDate = Nothing}
        `shouldBe` [NoOpeningBalance (Cents 100000)]

    it "points at a possible duplicate whose amount is the extra in the ledger" $ do
      let duplicate = EvidenceSummary (day 22) "GROCERY STORE #0012" (Cents (-6308))
      explainReconciliation (inputs 100000 93692) {possibleDuplicates = [duplicate]}
        `shouldBe` [DuplicateMatchesGap duplicate]

    it "lists days no export includes" $
      explainReconciliation (inputs 100000 90000) {coveredRanges = [(day 1, day 10), (day 20, day 28)]}
        `shouldBe` [UncoveredDays [(day 11, day 19)]]

    it "says so plainly when nothing explains the gap" $
      explainReconciliation (inputs 100000 99999) `shouldBe` [Unexplained (Cents 1)]

  describe "coverageGaps" $ do
    it "finds the uncovered runs of days" $
      coverageGaps (day 1) (day 28) [(day 3, day 5), (day 4, day 10), (day 20, day 30)]
        `shouldBe` [(day 1, day 2), (day 11, day 19)]

    it "finds no gaps when the range is covered" $
      coverageGaps (day 1) (day 28) [(day 1, day 15), (day 16, day 28)] `shouldBe` []

    it "never marks a covered day as a gap, and misses no uncovered day (property)" $ hedgehog $ do
      let genDay = day <$> Gen.int (Range.constant 1 28)
      from <- forAll genDay
      to <- forAll genDay
      covered <- forAll (Gen.list (Range.linear 0 5) ((\a b -> (min a b, max a b)) <$> genDay <*> genDay))
      let gaps = coverageGaps from to covered
          inGap date = any (\(start, end) -> start <= date && date <= end) gaps
          isCovered date = any (\(start, end) -> start <= date && date <= end) covered
      [date | date <- daysFrom from to, inGap date == isCovered date] === []
      [gap | gap@(start, end) <- gaps, start < from || end > to || start > end] === []

-- | Statement vs ledger, with an opening balance recorded on Jan 31 and the
-- whole of February covered, so only the fields a test sets matter.
inputs :: Int -> Int -> ReconciliationInputs
inputs statement ledger =
  ReconciliationInputs
    { asOf = day 28
    , statementBalance = Cents (fromIntegral statement)
    , ledgerBalance = Cents (fromIntegral ledger)
    , unpostedRows = []
    , possibleDuplicates = []
    , openingBalanceDate = Just (fromGregorian 2026 1 31)
    , firstTransactionDate = Just (day 2)
    , coveredRanges = [(day 1, day 28)]
    }

daysFrom :: Day -> Day -> [Day]
daysFrom from to = takeWhile (<= to) (iterate (addDays 1) from)

day :: Int -> Day
day = fromGregorian 2026 2
