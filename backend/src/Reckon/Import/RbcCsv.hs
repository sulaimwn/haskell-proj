-- | Parses RBC's "download transactions" CSV export.
--
-- The column layout is the one RBC documents, but it hasn't yet been checked
-- against a real export (docs/STATUS.md). Columns are found by header
-- name, not position, so reordered or extra columns don't break parsing.
--
-- Parsing is pure and all-or-nothing: either every data row parses, or the
-- result lists every problem with its line number. A half-imported file
-- would be worse than a rejected one.
module Reckon.Import.RbcCsv
  ( RbcRow (..)
  , CsvError (..)
  , parseRbcCsv
  , parseCents
  , parseRbcDate
  , renderCsvError
  ) where

import Control.Monad (unless, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isDigit)
import Data.Csv qualified as Csv
import Data.Either (partitionEithers)
import Data.Int (Int64)
import Data.List (elemIndex)
import Data.Maybe (isNothing)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Text.Encoding.Error qualified as Text
import Data.Time (Day, fromGregorianValid)
import Data.Vector qualified as Vector
import Reckon.Bank (BankAccountKind (..), Last4, last4FromAccountNumber)
import Reckon.Money (Cents (..))
import Text.Read (readMaybe)

-- | One transaction as RBC exported it. Only the last 4 digits of the
-- account number survive parsing.
data RbcRow = RbcRow
  { lineNumber :: Int
  , accountKind :: BankAccountKind
  , last4 :: Last4
  , transactionDate :: Day
  , chequeNumber :: Text
  , description1 :: Text
  , description2 :: Text
  , amount :: Cents
  -- ^ As RBC shows it: negative is money leaving the account.
  }
  deriving stock (Show, Eq)

data CsvError
  = MalformedCsv String
  | NoDataRows
  | MissingColumns [Text]
  | BadRow Int Text
  -- ^ Line number (1-based, the header is line 1) and what's wrong.
  deriving stock (Show, Eq)

renderCsvError :: CsvError -> Text
renderCsvError = \case
  MalformedCsv details -> "Not a valid CSV file: " <> Text.pack details
  NoDataRows -> "The file has a header but no transactions."
  MissingColumns columns -> "Missing columns: " <> Text.intercalate ", " columns <> ". Is this an RBC export?"
  BadRow line problem -> "Line " <> Text.pack (show line) <> ": " <> problem

requiredColumns :: [Text]
requiredColumns =
  ["Account Type", "Account Number", "Transaction Date", "Cheque Number", "Description 1", "Description 2", "CAD$"]

parseRbcCsv :: ByteString -> Either [CsvError] [RbcRow]
parseRbcCsv fileBytes = do
  records <- either (Left . pure . MalformedCsv) Right (Csv.decode Csv.NoHeader (LazyByteString.fromStrict (toUtf8 fileBytes)))
  let numberedRecords = zip [1 :: Int ..] (map (map Text.strip . Vector.toList) (Vector.toList records))
  case numberedRecords of
    [] -> Left [NoDataRows]
    (_, header) : dataRecords -> do
      let columnIndex name = elemIndex name header
          missing = [name | name <- requiredColumns, isNothing (columnIndex name)]
      unless (null missing) (Left [MissingColumns missing])
      let field record name = case columnIndex name of
            Just index | index < length record -> record !! index
            _ -> ""
          nonBlank = [(line, record) | (line, record) <- dataRecords, any (not . Text.null) record]
      when (null nonBlank) (Left [NoDataRows])
      case partitionEithers [parseRow line (field record) | (line, record) <- nonBlank] of
        ([], rows) -> Right rows
        (problems, _) -> Left problems

-- | RBC exports are usually UTF-8, but older exports can be Windows-1252.
-- Anything that isn't valid UTF-8 is read as Latin-1, which never fails.
-- A leading byte-order mark is dropped.
toUtf8 :: ByteString -> ByteString
toUtf8 bytes =
  let withoutBom = if "\xEF\xBB\xBF" `ByteString.isPrefixOf` bytes then ByteString.drop 3 bytes else bytes
   in case Text.decodeUtf8' withoutBom of
        Right _ -> withoutBom
        Left (_ :: Text.UnicodeException) -> Text.encodeUtf8 (Text.decodeLatin1 withoutBom)

parseRow :: Int -> (Text -> Text) -> Either CsvError RbcRow
parseRow line field = do
  -- The signature lets 'problem' be used at every result type below
  -- (GHC2024's MonoLocalBinds wouldn't infer that on its own).
  let problem :: Text -> Either CsvError a
      problem = Left . BadRow line
  accountKind <- maybe (problem ("unknown Account Type " <> quoted (field "Account Type"))) Right (parseAccountKind (field "Account Type"))
  last4 <- maybe (problem "Account Number has fewer than 4 digits") Right (last4FromAccountNumber (field "Account Number"))
  transactionDate <- either problem Right (parseRbcDate (field "Transaction Date"))
  amount <- case (field "CAD$", field "USD$") of
    ("", "") -> problem "no amount in CAD$ or USD$"
    ("", _) -> problem "USD amounts aren't supported yet: reckon is CAD-only (DECISIONS D023)"
    (cadAmount, _) -> either (\reason -> problem ("CAD$ " <> reason)) Right (parseCents cadAmount)
  pure
    RbcRow
      { lineNumber = line
      , accountKind
      , last4
      , transactionDate
      , chequeNumber = field "Cheque Number"
      , description1 = field "Description 1"
      , description2 = field "Description 2"
      , amount
      }
  where
    quoted text = "\"" <> text <> "\""

parseAccountKind :: Text -> Maybe BankAccountKind
parseAccountKind text = case Text.toLower text of
  "chequing" -> Just Chequing
  "savings" -> Just Savings
  "visa" -> Just CreditCard
  "mastercard" -> Just CreditCard
  _ -> Nothing

-- | RBC dates look like @1/5/2026@ (month/day/year, no zero padding).
parseRbcDate :: Text -> Either Text Day
parseRbcDate text = case Text.splitOn "/" text of
  [month, day, year]
    | Just m <- readNumber month
    , Just d <- readNumber day
    , Just y <- readNumber year
    , Text.length year == 4 ->
        maybe (Left ("invalid date " <> text)) Right (fromGregorianValid y m d)
  _ -> Left ("expected a date like 1/31/2026, got \"" <> text <> "\"")
  where
    readNumber part
      | not (Text.null part) && Text.all isDigit part = readMaybe (Text.unpack part)
      | otherwise = Nothing

-- | Parses an amount like @-4.50@, @12@ or @1234.5@ into exact cents,
-- without ever going through a floating point number.
parseCents :: Text -> Either Text Cents
parseCents raw = do
  let text = Text.strip raw
      (isNegative, unsigned) = case Text.uncons text of
        Just ('-', rest) -> (True, rest)
        Just ('+', rest) -> (False, rest)
        _ -> (False, text)
      (wholePart, fractionWithDot) = Text.breakOn "." unsigned
      fractionPart = Text.drop 1 fractionWithDot
      allDigits part = Text.all isDigit part
  when (Text.null wholePart || not (allDigits wholePart)) (Left (invalid text))
  when (not (Text.null fractionWithDot) && (Text.null fractionPart || not (allDigits fractionPart))) (Left (invalid text))
  when (Text.length fractionPart > 2) (Left ("has more than 2 decimal places: " <> text))
  -- 15 digits of dollars is far beyond any real balance, and keeps the
  -- arithmetic below safely inside Int64.
  when (Text.length wholePart > 15) (Left ("is too large: " <> text))
  let wholeCents = read (Text.unpack wholePart) * 100 :: Int64
      fractionCents = read (Text.unpack (Text.justifyLeft 2 '0' fractionPart)) :: Int64
      magnitude = wholeCents + fractionCents
  pure (Cents (if isNegative then negate magnitude else magnitude))
  where
    invalid text = "is not an amount: \"" <> text <> "\""
