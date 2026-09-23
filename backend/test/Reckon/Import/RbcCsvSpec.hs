module Reckon.Import.RbcCsvSpec (spec) where

import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as Char8
import Data.Int (Int64)
import Data.List (isInfixOf)
import Data.Text qualified as Text
import Data.Time (fromGregorian)
import Hedgehog (forAll, (===))
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import Reckon.Bank (BankAccountKind (..), last4Text)
import Reckon.Import.RbcCsv
import Reckon.Money (Cents (..))
import Test.Hspec
import Test.Hspec.Hedgehog (hedgehog)

spec :: Spec
spec = do
  describe "parseRbcCsv" $ do
    it "parses every row of the January fixture" $ do
      rows <- parseFixture "january.csv"
      length rows `shouldBe` 10
      case rows of
        payroll : _ -> do
          payroll.lineNumber `shouldBe` 2
          payroll.accountKind `shouldBe` Chequing
          last4Text payroll.last4 `shouldBe` "1234"
          payroll.transactionDate `shouldBe` fromGregorian 2026 1 2
          payroll.description1 `shouldBe` "PAYROLL DEPOSIT"
          payroll.description2 `shouldBe` "EXAMPLE EMPLOYER INC"
          payroll.amount `shouldBe` Cents 150000
        [] -> expectationFailure "no rows"

    it "keeps a comma inside a quoted description" $ do
      rows <- parseFixture "january.csv"
      map (.description2) rows `shouldContain` ["COFFEE CO, DOWNTOWN"]

    it "keeps only the last 4 digits of the account number" $ do
      rows <- parseFixture "january.csv"
      -- The full number is 00000-0001234. Nothing beyond "1234" may survive.
      show rows `shouldNotSatisfy` isInfixOf "0001234"
      map (last4Text . (.last4)) rows `shouldSatisfy` all (== "1234")

    it "handles a byte-order mark, Windows line endings, and trailing blank lines" $ do
      unixBytes <- ByteString.readFile (fixture "january.csv")
      let windowsBytes = "\xEF\xBB\xBF" <> Char8.intercalate "\r\n" (Char8.lines unixBytes) <> "\r\n\r\n\r\n"
      parseRbcCsv windowsBytes `shouldBe` parseRbcCsv unixBytes

    it "finds columns by name, so reordered and extra columns still work" $ do
      let reordered =
            "\"CAD$\",\"Transaction Date\",\"Extra\",\"Account Number\",\"Account Type\",\"Description 1\",\"Description 2\",\"Cheque Number\"\n\
            \-4.50,1/20/2026,whatever,00000-0001234,Chequing,Interac purchase,COFFEE CO,\n"
      fmap (map (.amount)) (parseRbcCsv reordered) `shouldBe` Right [Cents (-450)]

    it "rejects a file missing required columns" $
      parseRbcCsv "\"Date\",\"Amount\"\n1/2/2026,5.00\n"
        `shouldSatisfy` either (any isMissingColumns) (const False)

    it "rejects the whole file, listing every bad row by line number" $ do
      bytes <- ByteString.readFile (fixture "malformed.csv")
      case parseRbcCsv bytes of
        Right _ -> expectationFailure "expected the file to be rejected"
        Left problems -> do
          map lineOf problems `shouldBe` [Just 3, Just 4, Just 5, Just 6]
          map (fmap Text.unpack . messageOf) problems
            `shouldSatisfy` \messages ->
              and
                [ any (maybe False ("invalid date" `isInfixOf`)) messages
                , any (maybe False ("is not an amount" `isInfixOf`)) messages
                , any (maybe False ("CAD-only" `isInfixOf`)) messages
                , any (maybe False ("unknown Account Type" `isInfixOf`)) messages
                ]

    it "rejects a file with a header and no transactions" $
      parseRbcCsv "\"Account Type\",\"Account Number\",\"Transaction Date\",\"Cheque Number\",\"Description 1\",\"Description 2\",\"CAD$\",\"USD$\"\n"
        `shouldBe` Left [NoDataRows]

  describe "parseCents" $ do
    it "parses amounts exactly" $ do
      parseCents "-4.50" `shouldBe` Right (Cents (-450))
      parseCents "12" `shouldBe` Right (Cents 1200)
      parseCents "1234.5" `shouldBe` Right (Cents 123450)
      parseCents "+3.00" `shouldBe` Right (Cents 300)
      parseCents "0.07" `shouldBe` Right (Cents 7)
      parseCents " 19.99 " `shouldBe` Right (Cents 1999)

    it "rejects anything that isn't a plain amount" $
      mapM_
        (\bad -> parseCents bad `shouldSatisfy` either (const True) (const False))
        ["", "abc", "4.555", "4.", ".50", "1e5", "--4", "4.5.0", "$4.50", "1,000.00"]

    it "round-trips any amount written the way RBC writes it" $ hedgehog $ do
      cents <- forAll (Gen.int64 (Range.linearFrom 0 (-10000000000) 10000000000))
      parseCents (renderAmount cents) === Right (Cents cents)

  describe "parseRbcDate" $ do
    it "parses month/day/year without zero padding" $ do
      parseRbcDate "1/5/2026" `shouldBe` Right (fromGregorian 2026 1 5)
      parseRbcDate "12/31/2025" `shouldBe` Right (fromGregorian 2025 12 31)

    it "rejects impossible and differently formatted dates" $
      mapM_
        (\bad -> parseRbcDate bad `shouldSatisfy` either (const True) (const False))
        ["2/30/2026", "2026-01-05", "13/1/2026", "1/5/26", ""]

fixture :: FilePath -> FilePath
fixture name = "../fixtures/rbc/" <> name

parseFixture :: FilePath -> IO [RbcRow]
parseFixture name = do
  bytes <- ByteString.readFile (fixture name)
  either (\problems -> expectationFailure (show problems) >> pure []) pure (parseRbcCsv bytes)

-- | Writes cents as RBC does: optional minus, dollars, dot, two digits.
renderAmount :: Int64 -> Text.Text
renderAmount cents =
  Text.pack ((if cents < 0 then "-" else "") <> show (abs cents `div` 100) <> "." <> twoDigits (abs cents `mod` 100))
  where
    twoDigits number = (if number < 10 then "0" else "") <> show number

isMissingColumns :: CsvError -> Bool
isMissingColumns = \case
  MissingColumns _ -> True
  _ -> False

lineOf :: CsvError -> Maybe Int
lineOf = \case
  BadRow line _ -> Just line
  _ -> Nothing

messageOf :: CsvError -> Maybe Text.Text
messageOf = \case
  BadRow _ message -> Just message
  _ -> Nothing
