module Reckon.Posting.SplitSpec (spec) where

import Data.Text (Text)
import Hedgehog (Gen, forAll, (===))
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import Reckon.Money (Cents (..), negateCents, sumCents)
import Reckon.Posting.Split
import Test.Hspec
import Test.Hspec.Hedgehog (hedgehog)

spec :: Spec
spec = do
  describe "mkSplit" $ do
    it "gives me what the friends' shares leave over" $
      fmap splitParts (mkSplit (Cents (-12000)) [("alex", Cents 3000), ("sam", Cents 3000), ("jo", Cents 3000)])
        `shouldBe` Right [(Me, Cents 3000), (Friend "alex", Cents 3000), (Friend "sam", Cents 3000), (Friend "jo", Cents 3000)]

    it "leaves my share out when friends cover the whole payment" $
      fmap splitParts (mkSplit (Cents (-5000)) [("alex", Cents 5000)]) `shouldBe` Right [(Friend "alex", Cents 5000)]

    it "refuses money coming in" $
      mkSplit (Cents 5000) [("alex", Cents 100)] `shouldBe` Left OnlyMoneyOutCanBeSplit

    it "needs someone to split with" $
      mkSplit (Cents (-5000)) [] `shouldBe` Left NoOneToSplitWith

    it "refuses a share of zero or less" $ do
      mkSplit (Cents (-5000)) [("alex", Cents 0)] `shouldBe` Left (NonPositiveShare "alex")
      mkSplit (Cents (-5000)) [("alex", Cents 100), ("sam", Cents (-1))] `shouldBe` Left (NonPositiveShare "sam")

    it "refuses the same person twice" $
      mkSplit (Cents (-5000)) [("alex", Cents 100), ("alex", Cents 200)] `shouldBe` Left (PersonListedTwice "alex")

    it "refuses shares that add up to more than the payment" $
      mkSplit (Cents (-5000)) [("alex", Cents 3000), ("sam", Cents 2001)]
        `shouldBe` Left (SharesExceedAmount (Cents 5001) (Cents 5000))

    it "splits the payment exactly, with every part positive (property)" $ hedgehog $ do
      friends <- forAll genFriendNames
      shares <- forAll (traverse (\name -> (name,) . Cents <$> Gen.int64 (Range.linear 1 5000)) friends)
      mine <- forAll (Gen.int64 (Range.linear 0 5000))
      let spent = sumCents (map snd shares) <> Cents mine
      case mkSplit (negateCents spent) shares of
        Left problem -> fail ("a valid split was refused: " <> show problem)
        Right split -> do
          let parts = splitParts split
          all ((> mempty) . snd) parts === True
          sumCents (map snd parts) === spent
          -- My part is there exactly when I kept something.
          (Me `elem` map fst parts) === (mine > 0)

    it "refuses friends who ask for more than was paid (property)" $ hedgehog $ do
      friends <- forAll genFriendNames
      shares <- forAll (traverse (\name -> (name,) . Cents <$> Gen.int64 (Range.linear 100 5000)) friends)
      short <- forAll (Gen.int64 (Range.linear 1 99))
      let total = sumCents (map snd shares)
          Cents totalCents = total
          paid = Cents (totalCents - short)
      mkSplit (negateCents paid) shares === Left (SharesExceedAmount total paid)

  describe "equalSplit" $ do
    it "splits a $120 dinner four ways" $
      fmap splitParts (equalSplit (Cents (-12000)) ["alex", "sam", "jo"])
        `shouldBe` Right [(Me, Cents 3000), (Friend "alex", Cents 3000), (Friend "sam", Cents 3000), (Friend "jo", Cents 3000)]

    it "gives the odd cent to me first, then to the friends in order" $
      fmap splitParts (equalSplit (Cents (-10001)) ["alex", "sam", "jo"])
        `shouldBe` Right [(Me, Cents 2501), (Friend "alex", Cents 2500), (Friend "sam", Cents 2500), (Friend "jo", Cents 2500)]
    it "shares two odd cents between me and the first friend" $
      fmap splitParts (equalSplit (Cents (-10002)) ["alex", "sam", "jo"])
        `shouldBe` Right [(Me, Cents 2501), (Friend "alex", Cents 2501), (Friend "sam", Cents 2500), (Friend "jo", Cents 2500)]

    it "needs at least one friend" $
      equalSplit (Cents (-5000)) [] `shouldBe` Left NoOneToSplitWith

  describe "equalShares" $
    it "adds up to the whole and differs by at most a cent (property)" $ hedgehog $ do
      total <- forAll (Gen.int64 (Range.linear 0 1000000))
      parts <- forAll (Gen.int (Range.linear 1 12))
      let shares = equalShares (Cents total) parts
          amounts = [amount | Cents amount <- shares]
      length shares === parts
      sumCents shares === Cents total
      (maximum amounts - minimum amounts <= 1) === True
      -- The extra cents go to the earliest pieces.
      and (zipWith (>=) amounts (drop 1 amounts)) === True

genFriendNames :: Gen [Text]
genFriendNames = do
  count <- Gen.int (Range.linear 1 4)
  pure (take count ["alex", "sam", "jo", "kim"])
