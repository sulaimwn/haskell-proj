module Reckon.Ledger.EntrySpec (spec) where

import Data.Int (Int64)
import Data.Time (fromGregorian)
import Database.Persist.Sql (toSqlKey)
import Hedgehog (Gen, forAll, (===))
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import Reckon.Ledger.AccountType
import Reckon.Ledger.Entry
import Reckon.Money
import Test.Hspec
import Test.Hspec.Hedgehog (hedgehog)

spec :: Spec
spec = do
  describe "mkBalancedLines" $ do
    it "accepts any set of two or more non-zero lines that sums to zero" $ hedgehog $ do
      amounts <- forAll genBalancedAmounts
      fmap (map (.amount) . balancedLines) (mkBalancedLines (linesFor amounts))
        === Right (map Cents amounts)

    it "rejects lines that don't sum to zero, reporting the total" $ hedgehog $ do
      amounts <- forAll genBalancedAmounts
      offBy <- forAll (Gen.filter (/= 0) (Gen.int64 (Range.linearFrom 0 (-5000) 5000)))
      let skewed = case amounts of
            first : rest | first + offBy /= 0 -> (first + offBy) : rest
            _ -> amounts <> [offBy]
      mkBalancedLines (linesFor skewed) === Left (LinesDoNotBalance (Cents offBy))

    it "rejects fewer than two lines" $ do
      mkBalancedLines [] `shouldBe` Left FewerThanTwoLines
      mkBalancedLines (linesFor [0]) `shouldBe` Left FewerThanTwoLines

    it "rejects a zero-amount line even when the total is zero" $
      mkBalancedLines (linesFor [500, -500, 0]) `shouldBe` Left ZeroAmountLine

  describe "reverseLines" $
    it "negates every line, and the result still balances" $ hedgehog $ do
      amounts <- forAll genBalancedAmounts
      case mkBalancedLines (linesFor amounts) of
        Left entryError -> fail (show entryError)
        Right original -> do
          let reversed = reverseLines original
          map (.amount) (balancedLines reversed) === map (Cents . negate) amounts
          mkBalancedLines (balancedLines reversed) === Right reversed

  describe "mkNewJournalEntry" $
    it "rejects a blank description" $ do
      twoLines <- expectRight (mkBalancedLines (linesFor [100, -100]))
      mkNewJournalEntry (fromGregorian 2026 1 1) "   " twoLines `shouldBe` Left EmptyDescription

  describe "naturalBalance" $ do
    it "shows debit-normal accounts (asset, expense) as stored" $ do
      naturalBalance Asset (Cents 1200) `shouldBe` Cents 1200
      naturalBalance Expense (Cents 450) `shouldBe` Cents 450

    it "flips credit-normal accounts (liability, income, equity)" $ do
      naturalBalance Liability (Cents (-12000)) `shouldBe` Cents 12000
      naturalBalance Income (Cents (-500000)) `shouldBe` Cents 500000
      naturalBalance Equity (Cents (-100)) `shouldBe` Cents 100

  describe "AccountType text" $
    it "round-trips every account type" $
      mapM_ (\accountType -> accountTypeFromText (accountTypeToText accountType) `shouldBe` Just accountType) [minBound .. maxBound]

-- | 2 to 6 non-zero amounts that sum to zero: generate all but the last,
-- then make the last one cancel them.
genBalancedAmounts :: Gen [Int64]
genBalancedAmounts = Gen.filter valid $ do
  leading <- Gen.list (Range.linear 1 5) genNonZeroAmount
  pure (leading <> [negate (sum leading)])
  where
    valid = all (/= 0)

genNonZeroAmount :: Gen Int64
genNonZeroAmount = Gen.filter (/= 0) (Gen.int64 (Range.linearFrom 0 (-1000000) 1000000))

expectRight :: (Show e) => Either e a -> IO a
expectRight = either (\problem -> expectationFailure (show problem) >> error "unreachable") pure

-- | Lines on made-up account ids. mkBalancedLines doesn't look at accounts.
linesFor :: [Int64] -> [EntryLine]
linesFor amounts =
  [EntryLine {ledgerAccountId = toSqlKey index, amount = Cents value} | (index, value) <- zip [1 ..] amounts]
