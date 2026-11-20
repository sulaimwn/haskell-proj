-- | What Claude is asked to read from a screenshot, and strict validation of
-- what it sends back (Phase 5, DECISIONS D054, D055). Pure.
--
-- The model transcribes only what is visible: dates and amounts as
-- /text/, exactly as displayed. Everything that needs judgement or
-- arithmetic is done here, in Haskell, deterministically and under test:
-- turning the text into a date and exact cents, working out the year, and
-- refusing anything that doesn't add up. The model is never trusted to
-- return a year, and a response with any bad row is rejected whole (like a
-- CSV with a bad row), listing every problem.
module Reckon.Screenshot.Extraction
  ( -- * What is sent to the model
    extractionSchema
  , extractionInstructions

    -- * What comes back
  , Section (..)
  , ExtractedRow (..)
  , ExtractedScreenshot (..)
  , ExtractionError (..)
  , RowProblem (..)
  , parseExtraction
  , renderExtractionError
  , rowIdentity

    -- * Reading displayed text (exported for tests)
  , parseDisplayedDate
  , parseDisplayedAmount
  , inferDate
  ) where

import Control.Monad (unless, when)
import Data.Aeson (Value, object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key (Key)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser)
import Data.Aeson.Types qualified as Aeson
import Data.ByteString (ByteString)
import Data.Char (isAlpha, isDigit)
import Data.Either (partitionEithers)
import Data.List (find, sort)
import Data.Maybe (catMaybes)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (Day, addDays, fromGregorianValid, toGregorian)
import Reckon.Import.Dedupe (normalizeDescription)
import Reckon.Import.RbcCsv (parseCents)
import Reckon.Money (Cents (..))
import Text.Read (readMaybe)

-- | Which list of the app's transaction screen a row was in.
data Section
  = -- | A completed transaction.
    Posted
  | -- | Listed under a "pending" heading: a hold that may still change.
    Pending
  deriving stock (Show, Eq, Ord)

-- | A transaction as read from a screenshot and checked.
data ExtractedRow = ExtractedRow
  { transactionDate :: Day
  -- ^ The year is inferred here, never by the model.
  , description :: Text
  , amount :: Cents
  -- ^ Negative is money out.
  , runningBalance :: Maybe Cents
  , section :: Section
  , uncertain :: Bool
  -- ^ The model wasn't sure it read this row right. Kept as evidence, but
  -- never posted.
  }
  deriving stock (Show, Eq)

data ExtractedScreenshot = ExtractedScreenshot
  { accountLabel :: Text
  -- ^ The account's name as the app shows it ("Chequing"). Never a number.
  , rows :: [ExtractedRow]
  -- ^ Complete rows, top to bottom as displayed.
  , partialRowsDropped :: Int
  -- ^ Rows cut off at the screen's edge. Not imported: the same row appears
  -- whole in the neighbouring screenshot.
  }
  deriving stock (Show, Eq)

data RowProblem
  = UnreadableDate Text
  | UnreadableAmount Text
  | UnreadableBalance Text
  | -- | The model couldn't tell whether money went out or came in.
    UnknownDirection
  | -- | The text shows a minus sign but the direction says money came in.
    AmountContradictsDirection Text
  | ZeroAmount
  | EmptyDescription
  | -- | A run of 9 or more digits looks like an account or card number. The
    -- model was told never to return one, so something is wrong.
    LooksLikeAccountNumber
  deriving stock (Show, Eq)

data ExtractionError
  = -- | Not JSON, or not the shape asked for. Carries aeson's message.
    NotTheRequestedShape Text
  | NothingExtracted
  | -- | A row (counted from 1, top to bottom) with a problem.
    BadRow Int RowProblem
  | BadAccountLabel RowProblem
  deriving stock (Show, Eq)

-- * The request

-- | The JSON Schema the response must follow (sent as
-- @output_config.format@). It describes exactly what 'parseExtraction'
-- accepts. Every object forbids extra properties, as the API requires.
extractionSchema :: Value
extractionSchema =
  object
    [ "type" .= ("object" :: Text)
    , "additionalProperties" .= False
    , "required" .= (["accountLabel", "transactions"] :: [Text])
    , "properties"
        .= object
          [ "accountLabel" .= object ["type" .= ("string" :: Text), "description" .= ("The account's display name as shown on screen, e.g. Chequing. Never an account number." :: Text)]
          , "transactions"
              .= object
                [ "type" .= ("array" :: Text)
                , "description" .= ("Every transaction visible, in order from the top of the screen to the bottom." :: Text)
                , "items" .= transactionSchema
                ]
          ]
    ]

transactionSchema :: Value
transactionSchema =
  object
    [ "type" .= ("object" :: Text)
    , "additionalProperties" .= False
    , "required" .= (["dateText", "description", "amountText", "direction", "section", "runningBalanceText", "uncertain", "partial"] :: [Text])
    , "properties"
        .= object
          [ "dateText" .= object ["type" .= ("string" :: Text), "description" .= ("The date exactly as displayed, e.g. Feb 14 or Today. Do not add a year." :: Text)]
          , "description" .= object ["type" .= ("string" :: Text), "description" .= ("The merchant or description exactly as displayed." :: Text)]
          , "amountText" .= object ["type" .= ("string" :: Text), "description" .= ("The amount exactly as displayed, with any sign and currency symbol, e.g. -$12.34." :: Text)]
          , "direction"
              .= object
                [ "type" .= ("string" :: Text)
                , "enum" .= (["debit", "credit", "unknown"] :: [Text])
                , "description" .= ("debit if money left the account, credit if money arrived, unknown if the screen doesn't make it clear." :: Text)
                ]
          , "section"
              .= object
                [ "type" .= ("string" :: Text)
                , "enum" .= (["posted", "pending"] :: [Text])
                , "description" .= ("pending only for transactions under a Pending heading." :: Text)
                ]
          , "runningBalanceText"
              .= object
                [ "anyOf" .= ([object ["type" .= ("string" :: Text)], object ["type" .= ("null" :: Text)]] :: [Value])
                , "description" .= ("The balance shown next to this transaction, if any, else null." :: Text)
                ]
          , "uncertain" .= object ["type" .= ("boolean" :: Text), "description" .= ("true if any part of this transaction was hard to read." :: Text)]
          , "partial" .= object ["type" .= ("boolean" :: Text), "description" .= ("true if the transaction is cut off at the top or bottom edge of the screen." :: Text)]
          ]
    ]

-- | The system prompt. It asks for transcription only: no guessing, no
-- arithmetic, no years, no account numbers.
extractionInstructions :: Text
extractionInstructions =
  Text.unlines
    [ "You transcribe screenshots of a bank app's transaction list into JSON."
    , "Transcribe only what is visible on the screen. Never guess, infer or calculate."
    , "If any part of a transaction is hard to read, still include it and set uncertain to true."
    , "Copy dates, descriptions and amounts exactly as displayed. Do not add a year to a date."
    , "Never output an account number or card number. If the screen shows one, ignore it and use only the account's display name."
    , "A transaction cut off at the top or bottom edge of the screen has partial set to true."
    , "Transactions under a Pending heading have section pending. All others have section posted."
    , "Include every transaction, in order from the top of the screen to the bottom."
    ]

-- * The response

-- | Validates the model's JSON text. @takenOn@ is the day the screenshot was
-- taken, which "Today", "Yesterday" and year-less dates are read against.
parseExtraction :: Day -> ByteString -> Either [ExtractionError] ExtractedScreenshot
parseExtraction takenOn bytes = do
  raw <- either (\message -> Left [NotTheRequestedShape (Text.pack message)]) Right (Aeson.eitherDecodeStrict bytes >>= Aeson.parseEither parseRawScreenshot)
  let labelProblems = [BadAccountLabel problem | Just problem <- [checkNotAccountNumber raw.accountLabel]]
      (problems, checked) =
        partitionEithers
          [ either (Left . BadRow index) Right (checkRow takenOn rawRow)
          | (index, rawRow) <- zip [1 ..] raw.transactions
          ]
      complete = catMaybes checked
      dropped = length (filter (.partial) raw.transactions)
  case labelProblems <> problems of
    [] | null complete && dropped == 0 -> Left [NothingExtracted]
    [] -> Right ExtractedScreenshot {accountLabel = Text.strip raw.accountLabel, rows = complete, partialRowsDropped = dropped}
    errors -> Left errors

-- | One row, checked. 'Nothing' for a partial row, which is dropped.
checkRow :: Day -> RawRow -> Either RowProblem (Maybe ExtractedRow)
checkRow takenOn raw
  | raw.partial = Right Nothing
  | otherwise = do
      let description = Text.unwords (Text.words raw.description)
      when (Text.null description) (Left EmptyDescription)
      mapM_ Left (checkNotAccountNumber description)
      transactionDate <- parseDisplayedDate takenOn raw.dateText
      magnitude <- parseDisplayedAmount raw.amountText
      amount <- applyDirection raw.direction raw.amountText magnitude
      runningBalance <- traverse readBalance raw.runningBalanceText
      let section = if raw.section == "pending" then Pending else Posted
      pure (Just ExtractedRow {transactionDate, description, amount, runningBalance, section, uncertain = raw.uncertain})
  where
    readBalance text = either (const (Left (UnreadableBalance text))) Right (parseSignedCents text)

-- | Money out is negative. The text's own minus sign, when it has one, must
-- agree with the direction the model reported.
applyDirection :: Text -> Text -> (Cents, Bool) -> Either RowProblem Cents
applyDirection direction text (Cents magnitude, hadMinusSign) = case direction of
  "debit" -> Right (Cents (negate magnitude))
  "credit"
    | hadMinusSign -> Left (AmountContradictsDirection text)
    | otherwise -> Right (Cents magnitude)
  _ -> Left UnknownDirection

checkNotAccountNumber :: Text -> Maybe RowProblem
checkNotAccountNumber text
  | any ((>= 9) . Text.length) (Text.split (not . isDigit) text) = Just LooksLikeAccountNumber
  | otherwise = Nothing

-- | What makes two rows "the same row" when joining screenshots: the same
-- date, words, amount, section and running balance (when shown).
rowIdentity :: ExtractedRow -> (Day, Text, Cents, Section, Maybe Cents)
rowIdentity row = (row.transactionDate, normalizeDescription row.description, row.amount, row.section, row.runningBalance)

-- * Reading displayed text

-- | Dates as the app prints them: "Feb 14", "February 14", "Feb 14, 2026",
-- "Today", "Yesterday". Without a year, the most recent such date that
-- isn't after the day the screenshot was taken.
parseDisplayedDate :: Day -> Text -> Either RowProblem Day
parseDisplayedDate takenOn raw = case words' of
  ["today"] -> Right takenOn
  ["yesterday"] -> Right (addDays (-1) takenOn)
  [monthWord, dayWord] -> monthAndDay monthWord dayWord >>= \(month, day) -> maybe invalid Right (inferDate takenOn month day)
  [monthWord, dayWord, yearWord] -> do
    (month, day) <- monthAndDay monthWord dayWord
    year <- maybe invalid Right (readMaybe (Text.unpack yearWord) :: Maybe Integer)
    when (Text.length yearWord /= 4) invalid
    maybe invalid Right (fromGregorianValid year month day)
  _ -> invalid
  where
    invalid :: Either RowProblem a
    invalid = Left (UnreadableDate raw)
    words' = Text.words (Text.toLower (Text.filter (\character -> character /= ',' && character /= '.') raw))
    monthAndDay monthWord dayWord = do
      month <- maybe invalid Right (monthNumber monthWord)
      day <- maybe invalid Right (readMaybe (Text.unpack dayWord) :: Maybe Int)
      when (Text.any (not . isDigit) dayWord) invalid
      pure (month, day)

-- | "feb", "febr" and "february" are February. At least 3 letters, and a
-- prefix of the full name.
monthNumber :: Text -> Maybe Int
monthNumber word
  | Text.length word < 3 || not (Text.all isAlpha word) = Nothing
  | otherwise = fmap snd (find (\(name, _) -> word `Text.isPrefixOf` name) months)
  where
    months =
      zip
        ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]
        [1 ..]

-- | The most recent date with this month and day that is not after
-- @takenOn@. Looks back far enough to find a 29 February.
inferDate :: Day -> Int -> Int -> Maybe Day
inferDate takenOn month day = find (<= takenOn) candidates
  where
    (takenYear, _, _) = toGregorian takenOn
    candidates = catMaybes [fromGregorianValid year month day | year <- [takenYear, takenYear - 1 .. takenYear - 8]]

-- | An amount as displayed ("$1,234.56", "-$12.34", "(12.34)", "+$5.00"):
-- its size in cents, and whether the text itself showed a minus sign.
parseDisplayedAmount :: Text -> Either RowProblem (Cents, Bool)
parseDisplayedAmount raw = case parseSignedCents raw of
  Left _ -> Left (UnreadableAmount raw)
  Right (Cents 0) -> Left ZeroAmount
  Right (Cents cents) -> Right (Cents (abs cents), cents < 0)

-- | Cents from displayed text, keeping the sign.
parseSignedCents :: Text -> Either Text Cents
parseSignedCents raw =
  parseCents (signed (Text.filter (`notElem` ['$', ',', ' ', '(', ')']) (Text.replace "\8722" "-" (Text.replace "CAD" "" (Text.toUpper raw)))))
  where
    -- "(12.34)" is how some apps show a negative amount.
    signed cleaned
      | "(" `Text.isPrefixOf` Text.strip raw && not ("-" `Text.isPrefixOf` cleaned) = "-" <> cleaned
      | otherwise = cleaned

-- * The raw shape

data RawRow = RawRow
  { dateText :: Text
  , description :: Text
  , amountText :: Text
  , direction :: Text
  , section :: Text
  , runningBalanceText :: Maybe Text
  , uncertain :: Bool
  , partial :: Bool
  }

data RawScreenshot = RawScreenshot
  { accountLabel :: Text
  , transactions :: [RawRow]
  }

parseRawScreenshot :: Value -> Parser RawScreenshot
parseRawScreenshot = Aeson.withObject "screenshot" $ \object' -> do
  onlyKeys ["accountLabel", "transactions"] object'
  RawScreenshot <$> object' Aeson..: "accountLabel" <*> (object' Aeson..: "transactions" >>= traverse parseRawRow)

parseRawRow :: Value -> Parser RawRow
parseRawRow = Aeson.withObject "transaction" $ \object' -> do
  onlyKeys ["dateText", "description", "amountText", "direction", "section", "runningBalanceText", "uncertain", "partial"] object'
  direction <- object' Aeson..: "direction"
  unless (direction `elem` ["debit", "credit", "unknown" :: Text]) (fail ("direction must be debit, credit or unknown, got " <> show direction))
  section <- object' Aeson..: "section"
  unless (section `elem` ["posted", "pending" :: Text]) (fail ("section must be posted or pending, got " <> show section))
  RawRow
    <$> object' Aeson..: "dateText"
    <*> object' Aeson..: "description"
    <*> object' Aeson..: "amountText"
    <*> pure direction
    <*> pure section
    <*> object' Aeson..: "runningBalanceText"
    <*> object' Aeson..: "uncertain"
    <*> object' Aeson..: "partial"

-- | The object has exactly these keys: no more, and (by the @..:@ lookups
-- that follow) no fewer.
onlyKeys :: [Key] -> Aeson.Object -> Parser ()
onlyKeys expected object' = do
  let extra = [key | key <- KeyMap.keys object', key `notElem` expected]
  unless (null extra) (fail ("unexpected field(s): " <> show (sort extra)))

renderExtractionError :: ExtractionError -> Text
renderExtractionError = \case
  NotTheRequestedShape message -> "The response wasn't the requested shape: " <> message
  NothingExtracted -> "No transactions were found. Is this the transaction list?"
  BadRow index problem -> "Transaction " <> Text.pack (show index) <> ": " <> renderProblem problem
  BadAccountLabel problem -> "Account label: " <> renderProblem problem
  where
    renderProblem = \case
      UnreadableDate text -> "can't read the date \"" <> text <> "\""
      UnreadableAmount text -> "can't read the amount \"" <> text <> "\""
      UnreadableBalance text -> "can't read the running balance \"" <> text <> "\""
      UnknownDirection -> "it isn't clear whether money went out or came in"
      AmountContradictsDirection text -> "the amount \"" <> text <> "\" shows a minus sign but the direction is credit"
      ZeroAmount -> "the amount is zero"
      EmptyDescription -> "the description is empty"
      LooksLikeAccountNumber -> "contains a long run of digits that looks like an account number, which must never be returned"
