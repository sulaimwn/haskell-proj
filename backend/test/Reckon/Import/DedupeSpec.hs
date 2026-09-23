module Reckon.Import.DedupeSpec (spec) where

import Control.Monad (foldM, forM)
import Data.Int (Int64)
import Data.List (sort)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Time (Day, fromGregorian)
import Hedgehog (Gen, PropertyT, annotateShow, forAll, (===))
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import Reckon.Import.Dedupe
import Reckon.Money (Cents (..))
import Test.Hspec
import Test.Hspec.Hedgehog (hedgehog)

spec :: Spec
spec = do
  describe "fingerprintOf" $ do
    it "ignores case and extra whitespace in descriptions" $
      fingerprintOf "Interac  purchase " "Coffee   Co" "" (Cents (-450))
        `shouldBe` fingerprintOf "INTERAC PURCHASE" "COFFEE CO" "" (Cents (-450))

    it "distinguishes amounts and cheque numbers" $ do
      fingerprintOf "A" "B" "" (Cents (-450)) `shouldNotBe` fingerprintOf "A" "B" "" (Cents (-451))
      fingerprintOf "CHEQUE" "" "101" (Cents (-5000)) `shouldNotBe` fingerprintOf "CHEQUE" "" "102" (Cents (-5000))

  describe "assignOccurrences" $
    it "numbers identical rows on the same day 1, 2, ..., and everything else 1" $ do
      let rows = [coffee (day 20), coffee (day 20), books (day 20), coffee (day 21)]
      map ((.occurrence) . fst) (assignOccurrences rows) `shouldBe` [1, 2, 1, 1]

  describe "planImport" $ do
    it "adds nothing when the same rows are imported again" $ do
      let rows = [coffee (day 20), coffee (day 20), books (day 21)]
          plan = planImport (storeAll rows) rows
      length plan.rowsToAdd `shouldBe` 0
      plan.rowsAlreadyPresent `shouldBe` 3
      plan.reviewFlags `shouldBe` []

    it "keeps two identical coffees on the same day as two transactions" $ do
      let plan = planImport [] [coffee (day 20), coffee (day 20)]
      map ((.occurrence) . fst) plan.rowsToAdd `shouldBe` [1, 2]

    it "adds only the extra coffee when a later export has more of them" $ do
      let plan = planImport (storeAll [coffee (day 31)]) [coffee (day 31), coffee (day 31)]
      map fst plan.rowsToAdd `shouldBe` [RowKey (day 31) (coffee (day 31)).fingerprint 2]

    it "doesn't care about the order of different transactions within a day" $ do
      let stored = storeAll [coffee (day 20), books (day 20), coffee (day 20)]
          plan = planImport stored [books (day 20), coffee (day 20), coffee (day 20)]
      plan.rowsToAdd `shouldBe` []

    it "flags a stored row missing from the middle of a newer export" $ do
      let stored = storeAll [books (day 25)]
          plan = planImport stored [coffee (day 20), coffee (day 30)]
      plan.reviewFlags `shouldBe` [MissingFromNewerExport 1]

    it "doesn't flag a row missing from an export's first or last day (it may be partial)" $ do
      let stored = storeAll [books (day 20), books (day 30)]
          plan = planImport stored [coffee (day 20), coffee (day 30)]
      plan.reviewFlags `shouldBe` []

    it "flags a renamed row (same day, same amount) as a possible duplicate" $ do
      let renamed = row (day 22) "GROCERY STORE #0012" (-6308)
          stored = storeAll [row (day 22) "GROCERY STORE #12" (-6308)]
          plan = planImport stored [coffee (day 20), renamed, coffee (day 25)]
      map fst plan.rowsToAdd `shouldContain` [RowKey (day 22) renamed.fingerprint 1]
      plan.reviewFlags `shouldBe` [PossibleDuplicate 1 (RowKey (day 22) renamed.fingerprint 1)]

  describe "importing overlapping exports (property)" $ do
    it "stores exactly the true history, whatever the overlaps, order, or partial last days" $
      hedgehog overlappingExportsReconstructHistory

-- * The property

-- | A simulated database: every stored row, keyed by its dedupe key.
type Store = Map.Map RowKey (StoredRow Int)

overlappingExportsReconstructHistory :: PropertyT IO ()
overlappingExportsReconstructHistory = do
  -- The truth: for each of 20 days, the transactions in the order they
  -- happened. Small pools of descriptions and amounts make identical
  -- same-day rows common.
  history <-
    forAll $
      forM [1 .. 20] $ \dayNumber ->
        (day dayNumber,) . map (placedOn (day dayNumber)) <$> Gen.list (Range.linear 0 4) genTransaction
  exports <- forAll (genExports history)
  importOrder <- forAll (Gen.shuffle exports)

  (store, flags) <- foldM importExport (Map.empty, []) importOrder
  annotateShow flags

  -- The store holds exactly the true history: nothing lost, nothing doubled.
  sort [(storedRow.key.transactionDate, storedRow.key.fingerprint) | storedRow <- Map.elems store]
    === sort [(date, transaction.fingerprint) | (date, transactions) <- history, transaction <- transactions]
  -- Truthful exports never need a person to look at anything.
  flags === []

  -- And importing every export again changes nothing.
  (storeAfterReimport, _) <- foldM importExport (store, []) exports
  Map.size storeAfterReimport === Map.size store

importExport :: (Store, [ReviewFlag Int]) -> [IncomingRow ()] -> PropertyT IO (Store, [ReviewFlag Int])
importExport (store, flags) exportRows = do
  let dates = map (.transactionDate) exportRows
      inRange storedRow = not (null dates) && storedRow.key.transactionDate >= minimum dates && storedRow.key.transactionDate <= maximum dates
      plan = planImport (filter inRange (Map.elems store)) exportRows
      nextIds = [Map.size store + 1 ..]
      added = Map.fromList [(key, StoredRow {storedId, key, amount = incoming.amount}) | ((key, incoming), storedId) <- zip plan.rowsToAdd nextIds]
  pure (Map.union store added, flags <> plan.reviewFlags)

-- | Consecutive, overlapping exports covering all 20 days. Each export starts
-- on or before the previous one's last day. Every export except the last may
-- be cut short on its last day (taken mid-day), keeping only the day's
-- earliest transactions. Within each day, rows are shuffled: banks don't
-- promise a stable order.
genExports :: [(Day, [IncomingRow ()])] -> Gen [[IncomingRow ()]]
genExports history = go 1 0
  where
    lastDay = 20
    -- Each export ends strictly later than the previous one, so there are
    -- at most 20 exports, even while hedgehog shrinks a failing case.
    go start previousEnd = do
      end <- Gen.int (Range.constant (previousEnd + 1) lastDay)
      let isFinal = end == lastDay
      rows <- fmap concat . forM [start .. end] $ \dayNumber -> do
        let transactions = fromMaybe [] (lookup (day dayNumber) history)
        kept <-
          if dayNumber == end && not isFinal
            then (`take` transactions) <$> Gen.int (Range.constant 0 (length transactions))
            else pure transactions
        Gen.shuffle kept
      rest <-
        if isFinal
          then pure []
          else do
            -- Start on or before this export's last day. The next export
            -- ends later, so a cut-short day is always exported in full.
            nextStart <- Gen.int (Range.constant (max 1 (end - 3)) end)
            go nextStart end
      pure (rows : rest)

genTransaction :: Gen (IncomingRow ())
genTransaction = do
  description <- Gen.element ["COFFEE CO", "GROCERY", "BOOKSHOP", "TRANSIT"]
  amount <- Gen.element [-450, -1000, -6308, 150000]
  pure (row (day 1) description amount)

-- * Helpers

day :: Int -> Day
day = fromGregorian 2026 1

row :: Day -> Text -> Int64 -> IncomingRow ()
row date description amountCents =
  IncomingRow
    { transactionDate = date
    , fingerprint = fingerprintOf "Interac purchase" description "" (Cents amountCents)
    , amount = Cents amountCents
    , payload = ()
    }

-- | The same row on another day. (Built with the constructor, not
-- record-update syntax, because two records share the field name
-- @transactionDate@.)
placedOn :: Day -> IncomingRow () -> IncomingRow ()
placedOn date (IncomingRow _ fingerprint amount payload) = IncomingRow date fingerprint amount payload

coffee :: Day -> IncomingRow ()
coffee date = row date "COFFEE CO" (-450)

books :: Day -> IncomingRow ()
books date = row date "BOOKSHOP" (-1999)

-- | Stores rows as a previous import would have, with ids 1, 2, 3, ...
storeAll :: [IncomingRow ()] -> [StoredRow Int]
storeAll rows =
  [StoredRow {storedId, key, amount = incoming.amount} | ((key, incoming), storedId) <- zip (assignOccurrences rows) [1 ..]]
