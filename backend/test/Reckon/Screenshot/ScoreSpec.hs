module Reckon.Screenshot.ScoreSpec (spec) where

import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (fromGregorian)
import Reckon.Money (Cents (..))
import Reckon.Screenshot.Extraction (ExtractedRow (..), Section (..))
import Reckon.Screenshot.Score
import Test.Hspec

row :: Int -> Text -> Int -> ExtractedRow
row dayOfMonth description cents =
  ExtractedRow
    { transactionDate = fromGregorian 2026 2 dayOfMonth
    , description
    , amount = Cents (fromIntegral cents)
    , runningBalance = Nothing
    , section = Posted
    , uncertain = False
    }

spec :: Spec
spec = describe "scoreExtraction" $ do
  let expected = [row 19 "PAYROLL" 150000, row 18 "COFFEE CO" (-450), row 18 "COFFEE CO" (-450), row 17 "GROCERY" (-4217)]

  it "scores a perfect extraction as perfect" $ do
    let score = scoreExtraction expected expected
    (score.foundCount, score.missed, score.invented) `shouldBe` (4, [], [])
    (score.descriptionsRight, score.sectionsRight, score.balancesRight) `shouldBe` (4, 4, 4)

  it "counts a dropped duplicate row as missed" $ do
    let score = scoreExtraction expected [row 19 "PAYROLL" 150000, row 18 "COFFEE CO" (-450), row 17 "GROCERY" (-4217)]
    score.foundCount `shouldBe` 3
    map (.description) score.missed `shouldBe` ["COFFEE CO"]
    score.invented `shouldBe` []

  it "counts a row that isn't in the answer as invented" $ do
    let score = scoreExtraction expected (expected <> [row 16 "PHANTOM" (-100)])
    score.foundCount `shouldBe` 4
    map (.description) score.invented `shouldBe` ["PHANTOM"]

  it "finds a row with a misread description, and says the description was wrong" $ do
    let score = scoreExtraction expected [row 19 "PAYROLL" 150000, row 18 "COFFEE CO" (-450), row 18 "COFFEE CO" (-450), row 17 "GROCERY MART" (-4217)]
    (score.foundCount, score.descriptionsRight) `shouldBe` (4, 3)

  it "doesn't find a row whose amount was misread" $ do
    let score = scoreExtraction expected [row 19 "PAYROLL" 150000, row 18 "COFFEE CO" (-450), row 18 "COFFEE CO" (-450), row 17 "GROCERY" (-4271)]
    (score.foundCount, length score.missed, length score.invented) `shouldBe` (3, 1, 1)

  it "reads out as text, with whole percentages" $ do
    let rendered = renderScore "scroll-1" (scoreExtraction expected (take 3 expected))
    Text.unpack rendered `shouldContain` "scroll-1: 3 of 4 expected rows found (75%)"
    Text.unpack rendered `shouldContain` "missed 1, invented 0"
