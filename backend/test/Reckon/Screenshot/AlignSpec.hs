module Reckon.Screenshot.AlignSpec (spec) where

import Data.ByteString qualified as ByteString
import Data.Time (fromGregorian)
import Hedgehog (Gen, forAll, (===))
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import Reckon.Money (Cents (..))
import Reckon.Screenshot.Align
import Reckon.Screenshot.Extraction (ExtractedRow (..), ExtractedScreenshot (..), parseExtraction, rowIdentity)
import Test.Hspec
import Test.Hspec.Hedgehog (hedgehog)

align :: [[Char]] -> Alignment Char
align = alignScreenshots id

spec :: Spec
spec = do
  describe "alignScreenshots" $ do
    it "joins two screenshots at their overlap" $
      align ["abcd", "cdef"] `shouldBe` Alignment "abcdef" []

    it "joins a whole scroll" $
      align ["abcd", "cdef", "efgh"] `shouldBe` Alignment "abcdefgh" []

    it "keeps identical rows that are really there" $
      -- Two coffees (c c) at the end of the first screenshot, and the second
      -- starts with the second coffee, then a new row. The overlap is the
      -- last coffee and the row after it, so both coffees survive.
      align ["abccd", "cde"] `shouldBe` Alignment "abccde" []

    it "reports an overlap that could be read more than one way, and uses the longest" $
      -- "cc" then "cc": either the same two coffees (overlap 2), or three
      -- (overlap 1). Without a balance to tell them apart, it can't know.
      align ["abcc", "ccd"] `shouldBe` Alignment "abccd" [AmbiguousOverlap 1 [1, 2]]

    it "warns when two screenshots share no rows" $
      align ["abc", "xyz"] `shouldBe` Alignment "abcxyz" [NoOverlap 1]

    it "recognizes screenshots given in the wrong order, and joins them the right way round" $
      align ["cdef", "abcd"] `shouldBe` Alignment "abcdef" [OutOfOrder 1]

    it "does nothing with one screenshot, or none" $ do
      align ["abc"] `shouldBe` Alignment "abc" []
      align [] `shouldBe` Alignment "" []

    it "joins any scroll over distinct rows exactly (property)" $ hedgehog $ do
      windows <- forAll genScroll
      let Alignment joined warnings = alignScreenshots id windows
      joined === [1 .. maximum (concat windows)]
      warnings === []

  describe "joining the fake screenshots" $
    it "keeps both coffees and reports no ambiguity" $ do
      let taken = fromGregorian 2026 2 20
          rowsOf name = do
            bytes <- ByteString.readFile ("../fixtures/screenshots/" <> name)
            case parseExtraction taken bytes of
              Right screenshot -> pure screenshot.rows
              Left problems -> fail (show problems)
      first <- rowsOf "scroll-1.json"
      second <- rowsOf "scroll-2.json"
      let Alignment joined warnings = alignScreenshots rowIdentity [first, second]
      warnings `shouldBe` []
      map (\row -> (row.description, row.amount)) joined
        `shouldBe` [ ("SHELL GAS STATION", Cents (-10000))
                   , ("PAYROLL DEPOSIT EXAMPLE EMPLOYER", Cents 150000)
                   , ("COFFEE CO", Cents (-450))
                   , ("COFFEE CO", Cents (-450))
                   , ("CORNER GROCERY", Cents (-4217))
                   , ("EXAMPLE HYDRO", Cents (-8540))
                   , ("E-TRANSFER SENT ALEX EXAMPLE", Cents (-3000))
                   , ("RENT TRANSFER", Cents (-120000))
                   ]

-- | Windows over the rows 1, 2, 3, ... in scroll order. Each window
-- starts after the previous one's start but no later than its last row, so
-- they share at least one row, and each runs past the previous one's end.
genScroll :: Gen [[Int]]
genScroll = do
  windowCount <- Gen.int (Range.linear 1 6)
  firstSize <- Gen.int (Range.linear 2 10)
  steps <- Gen.list (Range.singleton (windowCount - 1)) ((,) <$> Gen.int (Range.linear 1 8) <*> Gen.int (Range.linear 1 8))
  pure (build 1 (firstSize - 1) steps)
  where
    build start span' steps =
      let end = start + span'
          window = [start .. end]
       in case steps of
            [] -> [window]
            (advance, extra) : more -> window : build (min end (start + advance)) (end + extra - min end (start + advance)) more
