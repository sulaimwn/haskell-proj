module Reckon.Screenshot.ExtractionSpec (spec) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as ByteString.Char8
import Data.Time (Day, addDays, fromGregorian, toGregorian)
import Hedgehog (forAll, (===))
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import Reckon.Money (Cents (..))
import Reckon.Screenshot.Extraction
import Test.Hspec
import Test.Hspec.Hedgehog (hedgehog)

fixture :: FilePath -> IO ByteString
fixture name = ByteString.readFile ("../fixtures/screenshots/" <> name)

day :: Integer -> Int -> Int -> Day
day = fromGregorian

spec :: Spec
spec = do
  describe "parseDisplayedDate" $ do
    let taken = day 2026 2 20
    it "puts a month and day in the most recent year that isn't after the screenshot" $ do
      parseDisplayedDate taken "Feb 14" `shouldBe` Right (day 2026 2 14)
      parseDisplayedDate taken "Feb 20" `shouldBe` Right (day 2026 2 20)
      -- Feb 21 hasn't happened yet this year, so it was last year's.
      parseDisplayedDate taken "Feb 21" `shouldBe` Right (day 2025 2 21)
      parseDisplayedDate (day 2026 1 10) "Dec 28" `shouldBe` Right (day 2025 12 28)

    it "reads long month names, full stops and an explicit year" $ do
      parseDisplayedDate taken "February 14" `shouldBe` Right (day 2026 2 14)
      parseDisplayedDate taken "Feb. 14" `shouldBe` Right (day 2026 2 14)
      parseDisplayedDate taken "Sept 3" `shouldBe` Right (day 2025 9 3)
      parseDisplayedDate taken "Feb 14, 2024" `shouldBe` Right (day 2024 2 14)

    it "reads Today and Yesterday against the day the screenshot was taken" $ do
      parseDisplayedDate taken "Today" `shouldBe` Right taken
      parseDisplayedDate taken "yesterday" `shouldBe` Right (day 2026 2 19)

    it "finds the last 29 February" $
      parseDisplayedDate (day 2026 3 5) "Feb 29" `shouldBe` Right (day 2024 2 29)

    it "refuses what isn't a date" $ do
      parseDisplayedDate taken "Smarch 3" `shouldBe` Left (UnreadableDate "Smarch 3")
      parseDisplayedDate taken "Feb 30" `shouldBe` Left (UnreadableDate "Feb 30")
      parseDisplayedDate taken "Feb 14 26" `shouldBe` Left (UnreadableDate "Feb 14 26")
      parseDisplayedDate taken "14" `shouldBe` Left (UnreadableDate "14")
      parseDisplayedDate taken "Fe 14" `shouldBe` Left (UnreadableDate "Fe 14")

  describe "inferDate" $
    it "is the latest matching date that is not after the screenshot (property)" $ hedgehog $ do
      offset <- forAll (Gen.integral (Range.linear 0 4000))
      month <- forAll (Gen.int (Range.linear 1 12))
      dayOfMonth <- forAll (Gen.int (Range.linear 1 28))
      let taken = addDays offset (day 2018 1 1)
      case inferDate taken month dayOfMonth of
        Nothing -> fail "a date with a day of 28 or less always exists"
        Just found -> do
          let (year, foundMonth, foundDay) = toGregorian found
              (takenYear, _, _) = toGregorian taken
          (foundMonth, foundDay) === (month, dayOfMonth)
          (found <= taken) === True
          -- Nothing later fits: the same date next year is after the screenshot.
          (year == takenYear || year == takenYear - 1) === True
          (year == takenYear) === (day takenYear month dayOfMonth <= taken)

  describe "parseDisplayedAmount" $ do
    it "reads amounts as exact cents, and notes a minus sign" $ do
      parseDisplayedAmount "$12.34" `shouldBe` Right (Cents 1234, False)
      parseDisplayedAmount "-$12.34" `shouldBe` Right (Cents 1234, True)
      parseDisplayedAmount "$1,250.00" `shouldBe` Right (Cents 125000, False)
      parseDisplayedAmount "+$5.00" `shouldBe` Right (Cents 500, False)
      parseDisplayedAmount "12.3" `shouldBe` Right (Cents 1230, False)
      parseDisplayedAmount "\8722$5.00" `shouldBe` Right (Cents 500, True)
      parseDisplayedAmount "(12.34)" `shouldBe` Right (Cents 1234, True)
      parseDisplayedAmount "$1,234.56 CAD" `shouldBe` Right (Cents 123456, False)

    it "refuses what isn't an amount, and a zero amount" $ do
      parseDisplayedAmount "twelve dollars" `shouldBe` Left (UnreadableAmount "twelve dollars")
      parseDisplayedAmount "12.345" `shouldBe` Left (UnreadableAmount "12.345")
      parseDisplayedAmount "" `shouldBe` Left (UnreadableAmount "")
      parseDisplayedAmount "$0.00" `shouldBe` Left ZeroAmount

  describe "parseExtraction" $ do
    let taken = day 2026 2 20

    it "validates a response, infers the year, signs amounts by direction, and drops partial rows" $ do
      Right screenshot <- parseExtraction taken <$> fixture "scroll-1.json"
      screenshot.accountLabel `shouldBe` "Chequing"
      screenshot.partialRowsDropped `shouldBe` 1
      map (\row -> (row.transactionDate, row.description, row.amount, row.section)) screenshot.rows
        `shouldBe` [ (day 2026 2 19, "SHELL GAS STATION", Cents (-10000), Pending)
                   , (day 2026 2 19, "PAYROLL DEPOSIT EXAMPLE EMPLOYER", Cents 150000, Posted)
                   , (day 2026 2 18, "COFFEE CO", Cents (-450), Posted)
                   , (day 2026 2 18, "COFFEE CO", Cents (-450), Posted)
                   , (day 2026 2 17, "CORNER GROCERY", Cents (-4217), Posted)
                   ]
      map (.runningBalance) screenshot.rows `shouldBe` [Nothing, Just (Cents 287410), Nothing, Nothing, Nothing]

    it "keeps uncertain rows, flagged" $ do
      Right screenshot <- parseExtraction taken <$> fixture "scroll-2.json"
      map (.uncertain) screenshot.rows `shouldBe` [False, False, False, False, True]

    it "rejects the whole response and lists every bad row and the account label" $ do
      Left problems <- parseExtraction taken <$> fixture "bad-rows.json"
      problems
        `shouldBe` [ BadAccountLabel LooksLikeAccountNumber
                   , BadRow 1 (UnreadableDate "Smarch 3")
                   , BadRow 2 UnknownDirection
                   , BadRow 3 (AmountContradictsDirection "-$9.99")
                   , BadRow 4 ZeroAmount
                   , BadRow 5 LooksLikeAccountNumber
                   , BadRow 6 (UnreadableAmount "twelve dollars")
                   , BadRow 7 EmptyDescription
                   ]
      -- ...and says so in words, with the row's position.
      map renderExtractionError problems `shouldSatisfy` any (== "Transaction 1: can't read the date \"Smarch 3\"")

    it "rejects a field the schema doesn't allow" $ do
      Left [NotTheRequestedShape message] <- parseExtraction taken <$> fixture "extra-field.json"
      show message `shouldContain` "unexpected field(s)"

    it "rejects text that isn't JSON, and a missing field" $ do
      parseExtraction taken "I can see a list of transactions." `shouldSatisfy` isNotShape
      parseExtraction taken (ByteString.Char8.pack "{\"accountLabel\": \"Chequing\"}") `shouldSatisfy` isNotShape

    it "rejects a direction or section outside the allowed values" $ do
      let response direction section =
            ByteString.Char8.pack
              ( "{\"accountLabel\":\"Chequing\",\"transactions\":[{\"dateText\":\"Feb 1\",\"description\":\"X\",\"amountText\":\"$1.00\",\"direction\":\""
                  <> direction
                  <> "\",\"section\":\""
                  <> section
                  <> "\",\"runningBalanceText\":null,\"uncertain\":false,\"partial\":false}]}"
              )
      parseExtraction taken (response "sideways" "posted") `shouldSatisfy` isNotShape
      parseExtraction taken (response "debit" "someday") `shouldSatisfy` isNotShape

    it "says so when there is nothing to import" $
      parseExtraction taken "{\"accountLabel\":\"Chequing\",\"transactions\":[]}" `shouldBe` Left [NothingExtracted]

  describe "the schema sent to the model" $
    it "has exactly the fields parseExtraction accepts" $ do
      let rendered = show extractionSchema
      mapM_ (\field -> rendered `shouldContain` field) ["accountLabel", "dateText", "amountText", "direction", "section", "runningBalanceText", "uncertain", "partial", "additionalProperties"]

isNotShape :: Either [ExtractionError] a -> Bool
isNotShape = \case
  Left [NotTheRequestedShape _] -> True
  _ -> False
