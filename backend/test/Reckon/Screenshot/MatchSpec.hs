module Reckon.Screenshot.MatchSpec (spec) where

import Data.List (nub)
import Data.Text (Text)
import Data.Time (Day, fromGregorian)
import Hedgehog (Gen, forAll, (===))
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import Reckon.Money (Cents (..))
import Reckon.Screenshot.Extraction (Section (..))
import Reckon.Screenshot.Match
import Test.Hspec
import Test.Hspec.Hedgehog (hedgehog)

march :: Int -> Day
march = fromGregorian 2026 3

prov :: Int -> Int -> Text -> Int -> Section -> Provisional Int
prov rowId dayOfMonth description cents section =
  Provisional {rowId, date = march dayOfMonth, description, amount = Cents (fromIntegral cents), section}

lat :: Int -> Int -> Text -> Int -> Later Int
lat rowId dayOfMonth description cents =
  Later {rowId, date = march dayOfMonth, description, amount = Cents (fromIntegral cents)}

spec :: Spec
spec = do
  describe "planMatches, same amount" $ do
    it "matches a row to the bank's row for it, despite different wording and a day's difference" $
      planMatches [prov 1 2 "Coffee Co" (-450) Posted] [lat 10 3 "Interac purchase - COFFEE CO" (-450)]
        `shouldBe` [Match 1 10 SameAmount]

    it "needs the same amount" $
      planMatches [prov 1 2 "Coffee Co" (-450) Posted] [lat 10 2 "COFFEE CO" (-451)] `shouldBe` []

    it "needs the dates close" $
      planMatches [prov 1 2 "Coffee Co" (-450) Posted] [lat 10 9 "COFFEE CO" (-450)] `shouldBe` []

    it "needs a word in common" $
      planMatches [prov 1 2 "Coffee Co" (-450) Posted] [lat 10 2 "GROCERY MART" (-450)] `shouldBe` []

    it "ignores words that say nothing about which transaction it is" $
      planMatches [prov 1 2 "Interac purchase" (-450) Posted] [lat 10 2 "Interac purchase - GROCERY MART" (-450)] `shouldBe` []

    it "matches nothing when two later rows could be it, rather than guess" $
      planMatches [prov 1 2 "Coffee Co" (-450) Posted] [lat 10 2 "COFFEE CO" (-450), lat 11 3 "COFFEE CO" (-450)] `shouldBe` []

    it "matches nothing when two different rows could both be one later row" $
      -- Coffees on the 2nd and the 3rd are both within a few days of a bank
      -- row dated the 3rd. Which is it? Not decided by guessing.
      planMatches [prov 1 2 "Coffee Co" (-450) Posted, prov 2 3 "Coffee Co" (-450) Posted] [lat 10 3 "COFFEE CO" (-450)] `shouldBe` []

    it "matches identical rows one to one when each has its own partner" $
      -- Two coffees on different days, each with one bank row near it.
      planMatches
        [prov 1 2 "Coffee Co" (-450) Posted, prov 2 20 "Coffee Co" (-450) Posted]
        [lat 10 2 "COFFEE CO" (-450), lat 11 20 "COFFEE CO" (-450)]
        `shouldBe` [Match 1 10 SameAmount, Match 2 11 SameAmount]

  describe "planMatches, identical rows" $ do
    it "pairs two identical coffees on one day with two identical bank rows, one to one, in order" $
      planMatches
        [prov 1 2 "Coffee Co" (-450) Posted, prov 2 2 "Coffee Co" (-450) Posted]
        [lat 10 2 "COFFEE CO" (-450), lat 11 2 "COFFEE CO" (-450)]
        `shouldBe` [Match 1 10 SameAmount, Match 2 11 SameAmount]

    it "leaves the extra one unmatched when the bank has fewer" $
      planMatches
        [prov 1 2 "Coffee Co" (-450) Posted, prov 2 2 "Coffee Co" (-450) Posted, prov 3 2 "Coffee Co" (-450) Posted]
        [lat 10 2 "COFFEE CO" (-450), lat 11 2 "COFFEE CO" (-450)]
        `shouldBe` [Match 1 10 SameAmount, Match 2 11 SameAmount]

    it "still refuses when the identical rows could belong to different days' bank rows" $
      planMatches
        [prov 1 2 "Coffee Co" (-450) Posted]
        [lat 10 1 "COFFEE CO" (-450), lat 11 3 "COFFEE CO" (-450)]
        `shouldBe` []

  describe "planMatches, a hold that posted for a different amount" $ do
    let hold = prov 1 1 "Shell Gas Station" (-10000) Pending

    it "matches a pending hold to the posted row for its final amount" $
      planMatches [hold] [lat 10 2 "SHELL GAS STATION #1234" (-4320)]
        `shouldBe` [Match 1 10 (AmountChanged (Cents (-10000)) (Cents (-4320)))]

    it "does this only for pending rows" $
      planMatches [prov 1 1 "Shell Gas Station" (-10000) Posted] [lat 10 2 "SHELL GAS STATION" (-4320)] `shouldBe` []

    it "needs the same direction of money" $
      planMatches [hold] [lat 10 2 "SHELL GAS STATION" 4320] `shouldBe` []

    it "needs the posted row to come after the hold, within a week" $ do
      planMatches [hold] [lat 10 20 "SHELL GAS STATION" (-4320)] `shouldBe` []
      planMatches [prov 1 10 "Shell Gas Station" (-10000) Pending] [lat 10 5 "SHELL GAS STATION" (-4320)] `shouldBe` []

    it "prefers an exact amount, and never matches twice" $
      planMatches [hold] [lat 10 2 "SHELL GAS STATION" (-10000), lat 11 3 "SHELL GAS STATION" (-4320)]
        `shouldBe` [Match 1 10 SameAmount]

    it "matches nothing when two posted rows could be the hold" $
      planMatches [hold] [lat 10 2 "SHELL GAS STATION" (-4320), lat 11 3 "SHELL GAS STATION" (-1500)] `shouldBe` []

  describe "descriptionsAgree" $
    it "is symmetric (property)" $ hedgehog $ do
      first <- forAll genDescription
      second <- forAll genDescription
      descriptionsAgree first second === descriptionsAgree second first

  describe "planMatches (property)" $
    it "only ever matches one to one" $ hedgehog $ do
      provisionals <- forAll (Gen.list (Range.linear 0 8) genProvisional)
      laters <- forAll (Gen.list (Range.linear 0 8) genLater)
      let matches = planMatches (uniqueIds (.rowId) provisionals) (uniqueIds (.rowId) laters)
      nub (map (.provisional) matches) === map (.provisional) matches
      nub (map (.later) matches) === map (.later) matches

uniqueIds :: (Eq b) => (a -> b) -> [a] -> [a]
uniqueIds identify = foldr (\item kept -> if identify item `elem` map identify kept then kept else item : kept) []

genDescription :: Gen Text
genDescription = Gen.element ["COFFEE CO", "Coffee Co", "SHELL GAS", "GROCERY MART", "Interac purchase - COFFEE CO", "RENT", "PAYMENT"]

genProvisional :: Gen (Provisional Int)
genProvisional =
  Provisional
    <$> Gen.int (Range.linear 1 20)
    <*> (march <$> Gen.int (Range.linear 1 10))
    <*> genDescription
    <*> (Cents <$> Gen.element [-450, -4320, -10000, 500])
    <*> Gen.element [Posted, Pending]

genLater :: Gen (Later Int)
genLater =
  Later
    <$> Gen.int (Range.linear 1 20)
    <*> (march <$> Gen.int (Range.linear 1 14))
    <*> genDescription
    <*> (Cents <$> Gen.element [-450, -4320, -10000, 500])
