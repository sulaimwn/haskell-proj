-- | The rule language (Phase 7, DECISIONS D067): a few lines of text that say
-- where a bank row should go.
--
-- > when description contains "TIM HORTONS" then categorize expense:coffee
-- > when description starts with "UBER" and amount < -50.00 then categorize expense:transport
-- > when description contains "DINNER" and account is credit card then split expense:food equally with alex, sam
--
-- A rule is conditions joined by @and@, then one action. This module is
-- pure: it parses text into a 'Rule', renders a 'Rule' back to text, and
-- says what is wrong, and where, when the text isn't a rule. Evaluating a
-- rule against a bank row is "Reckon.Rules.Eval".
--
-- 'parseRule' and 'renderRule' agree: rendering any rule and parsing it again
-- gives the same rule (a property test), so the text a person sees after
-- saving is always something the system can read back.
module Reckon.Rules.Language
  ( Rule (..)
  , Condition (..)
  , Comparison (..)
  , Action (..)
  , RuleProblem (..)
  , parseRule
  , renderRule
  , renderProblem
  , problemAt
  , ruleCategory
  , ruleFriends
  ) where

import Control.Monad (unless, void, when)
import Data.Char (isAlphaNum, isAscii, isDigit)
import Data.Functor (($>))
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Void (Void)
import Reckon.Bank (BankAccountKind (..))
import Reckon.Import.Dedupe (normalizeDescription)
import Reckon.Ledger.AccountType (AccountType (..), accountTypeFromName)
import Reckon.Money (Cents (..), renderCents)
import Text.Megaparsec
import Text.Megaparsec.Char (char, space1, string')
import Text.Megaparsec.Char.Lexer qualified as Lexer

-- | A rule: every condition must hold, and then the action applies.
data Rule = Rule
  { conditions :: NonEmpty Condition
  , action :: Action
  }
  deriving stock (Show, Eq)

data Condition
  = -- | Text anywhere in the description. Stored upper-case with single
    -- spaces, and compared that way, so case and spacing never matter.
    DescriptionContains Text
  | DescriptionStartsWith Text
  | DescriptionEndsWith Text
  | -- | The amount as the bank shows it: negative is money out.
    AmountIs Comparison Cents
  | AccountIs BankAccountKind
  deriving stock (Show, Eq)

data Comparison = LessThan | AtMost | GreaterThan | AtLeast | EqualTo | NotEqualTo
  deriving stock (Show, Eq, Enum, Bounded)

data Action
  = -- | Post the row against this ledger account (like @expense:coffee@).
    Categorize Text
  | -- | Split a payment equally between me and these friends: my share goes
    -- to the category, theirs to what they owe me. Money out only.
    SplitEqually Text (NonEmpty Text)
  deriving stock (Show, Eq)

-- | The account an action puts my own money in.
ruleCategory :: Rule -> Text
ruleCategory rule = case rule.action of
  Categorize account -> account
  SplitEqually account _ -> account

-- | The friends a rule splits with (none for a plain categorization).
ruleFriends :: Rule -> [Text]
ruleFriends rule = case rule.action of
  Categorize _ -> []
  SplitEqually _ friends -> NonEmpty.toList friends

-- | Where the text went wrong. Line and column count from 1.
data RuleProblem = RuleProblem
  { line :: Int
  , column :: Int
  , message :: Text
  }
  deriving stock (Show, Eq)

-- | @line 1, column 12: expected ...@
renderProblem :: RuleProblem -> Text
renderProblem problem =
  "line " <> Text.pack (show problem.line) <> ", column " <> Text.pack (show problem.column) <> ": " <> problem.message

-- | A problem found after parsing (for example, a friend who doesn't exist),
-- placed at the first place the text appears in the rule's source, so it can
-- be shown under the right word. Line 1, column 1 if it can't be found.
problemAt :: Text -> Text -> Text -> RuleProblem
problemAt needle source message = case Text.breakOn needle (Text.toLower source) of
  (before, rest)
    | not (Text.null rest) ->
        let linesBefore = Text.splitOn "\n" before
         in RuleProblem {line = length linesBefore, column = Text.length (last' linesBefore) + 1, message}
  _ -> RuleProblem {line = 1, column = 1, message}
  where
    last' = foldr (\item _ -> item) "" . reverse

-- * Parsing

type Parser = Parsec Void Text

-- | Text to a rule, or the first thing wrong with it.
parseRule :: Text -> Either RuleProblem Rule
parseRule input = case parse (spaceConsumer *> ruleParser <* eof) "rule" input of
  Right rule -> Right rule
  Left bundle -> Left (problemFrom bundle)

problemFrom :: ParseErrorBundle Text Void -> RuleProblem
problemFrom bundle =
  RuleProblem
    { line = unPos (sourceLine position)
    , column = unPos (sourceColumn position)
    , message = Text.intercalate "; " (filter (not . Text.null) (Text.strip <$> Text.lines (Text.pack (parseErrorTextPretty firstError))))
    }
  where
    firstError = NonEmpty.head (bundleErrors bundle)
    (_, positioned) = reachOffset (errorOffset firstError) (bundlePosState bundle)
    position = pstateSourcePos positioned

spaceConsumer :: Parser ()
spaceConsumer = Lexer.space space1 empty empty

lexeme :: Parser a -> Parser a
lexeme = Lexer.lexeme spaceConsumer

-- | A word, in any case, that isn't just the start of a longer word.
keyword :: Text -> Parser ()
keyword word = lexeme (try (void (string' word) <* notFollowedBy (satisfy isWordCharacter))) <?> Text.unpack word
  where
    isWordCharacter character = isAlphaNum character || character `elem` ("_:-" :: String)

symbol :: Text -> Parser ()
symbol text = void (Lexer.symbol spaceConsumer text)

-- | Fails with this message, reported at the given offset instead of where
-- the parser happens to be.
failAt :: Int -> String -> Parser a
failAt offset message = parseError (FancyError offset (Set.singleton (ErrorFail message)))

ruleParser :: Parser Rule
ruleParser = do
  keyword "when"
  first <- conditionParser
  rest <- many (keyword "and" *> conditionParser)
  keyword "then"
  Rule (first :| rest) <$> actionParser

conditionParser :: Parser Condition
conditionParser =
  choice
    [ keyword "description" *> descriptionTest
    , keyword "amount" *> (AmountIs <$> comparisonParser <*> amountParser)
    , keyword "account" *> keyword "is" *> (AccountIs <$> kindParser)
    ]
    <?> "a condition (description ..., amount ..., or account is ...)"
  where
    descriptionTest =
      choice
        [ keyword "contains" *> (DescriptionContains <$> quotedText)
        , keyword "starts" *> keyword "with" *> (DescriptionStartsWith <$> quotedText)
        , keyword "ends" *> keyword "with" *> (DescriptionEndsWith <$> quotedText)
        ]
        <?> "contains, starts with or ends with"

kindParser :: Parser BankAccountKind
kindParser =
  choice
    [ keyword "chequing" $> Chequing
    , keyword "savings" $> Savings
    , keyword "credit" *> keyword "card" $> CreditCard
    ]
    <?> "chequing, savings or credit card"

comparisonParser :: Parser Comparison
comparisonParser =
  choice
    [ try (symbol "<=") $> AtMost
    , try (symbol ">=") $> AtLeast
    , try (symbol "!=") $> NotEqualTo
    , symbol "<" $> LessThan
    , symbol ">" $> GreaterThan
    , symbol "=" $> EqualTo
    ]
    <?> "a comparison (<, <=, >, >=, = or !=)"

-- | Text in double quotes. A backslash escapes a quote or a backslash. The
-- text is kept the way descriptions are compared (upper case, one space
-- between words), so rules that only differ in case or spacing are the same
-- rule.
quotedText :: Parser Text
quotedText = do
  start <- getOffset
  text <- lexeme (char '"' *> (Text.pack <$> manyTill character (char '"'))) <?> "text in double quotes"
  when (Text.null (Text.strip text)) (failAt start "the quoted text can't be empty")
  pure (normalizeDescription text)
  where
    character = (char '\\' *> (char '"' <|> char '\\')) <|> satisfy (/= '"')

-- | Dollars and cents like @12@, @-12.5@, @$1,000.00@ (never more than two
-- decimals: that would silently lose money).
amountParser :: Parser Cents
amountParser = do
  start <- getOffset
  negative <- optional (char '-')
  _ <- optional (char '$')
  whole <- digitsWithCommas <?> "an amount like 12.50"
  fraction <- optional (char '.' *> takeWhile1P (Just "digits") isDigit)
  spaceConsumer
  case fraction of
    Just digits | Text.length digits > 2 -> failAt start "amounts have at most two decimals, like 12.50"
    _ -> pure ()
  let cents = whole * 100 + maybe 0 (read . Text.unpack . Text.justifyLeft 2 '0') fraction
  unless (cents < 10 ^ (15 :: Int)) (failAt start "that amount is too large")
  pure (Cents (fromIntegral (maybe cents (const (negate cents)) negative)))
  where
    digitsWithCommas :: Parser Integer
    digitsWithCommas = do
      first <- takeWhile1P (Just "digit") isDigit
      more <- many (char ',' *> takeWhile1P (Just "digit") isDigit)
      pure (read (Text.unpack (Text.concat (first : more))))

actionParser :: Parser Action
actionParser =
  choice
    [ keyword "categorize" *> (Categorize <$> accountName)
    , do
        keyword "split"
        categoryStart <- getOffset
        category <- accountName
        when (accountTypeFromName category /= Just Expense) $
          failAt categoryStart "the part of a payment you keep must go to an expense account, like expense:food"
        keyword "equally"
        keyword "with"
        friends <- (:|) <$> personAt <*> many (symbol "," *> personAt)
        case firstRepeat (NonEmpty.toList friends) of
          Just (offset, name) -> failAt offset (Text.unpack name <> " is listed twice")
          Nothing -> pure (SplitEqually category (snd <$> friends))
    ]
    <?> "an action (categorize ACCOUNT, or split ACCOUNT equally with NAME, NAME)"

-- | A ledger account like @expense:food@: lower-cased, with a known type
-- before the colon, and something after it.
accountName :: Parser Text
accountName = do
  start <- getOffset
  raw <- lexeme (takeWhile1P (Just "an account name like expense:food") (\character -> isAscii character && (isAlphaNum character || character `elem` (":_-" :: String))))
  let name = Text.toLower raw
  case (accountTypeFromName name, Text.breakOn ":" name) of
    (Just _, (_, rest)) | Text.length rest > 1 -> pure name
    _ -> failAt start "account names look like expense:food, starting with asset, liability, income, expense, equity or receivable"

-- | A friend, by the name they were added with (lower-case letters, digits,
-- @_@ and @-@), with where in the text it started.
personAt :: Parser (Int, Text)
personAt = do
  offset <- getOffset
  name <- lexeme (takeWhile1P (Just "a friend's name") (\character -> isAscii character && (isAlphaNum character || character `elem` ("_-" :: String))))
  pure (offset, Text.toLower name)

-- | The first name that appeared earlier in the list.
firstRepeat :: [(Int, Text)] -> Maybe (Int, Text)
firstRepeat = go Set.empty
  where
    go _ [] = Nothing
    go seen ((offset, name) : rest)
      | name `Set.member` seen = Just (offset, name)
      | otherwise = go (Set.insert name seen) rest

-- * Rendering

-- | The rule as text that 'parseRule' reads back to the same rule.
renderRule :: Rule -> Text
renderRule rule =
  "when "
    <> Text.intercalate " and " (map renderCondition (NonEmpty.toList rule.conditions))
    <> " then "
    <> renderAction rule.action

renderCondition :: Condition -> Text
renderCondition = \case
  DescriptionContains text -> "description contains " <> quoted text
  DescriptionStartsWith text -> "description starts with " <> quoted text
  DescriptionEndsWith text -> "description ends with " <> quoted text
  AmountIs comparison cents -> "amount " <> renderComparison comparison <> " " <> renderAmount cents
  AccountIs kind -> "account is " <> renderKind kind

renderAction :: Action -> Text
renderAction = \case
  Categorize account -> "categorize " <> account
  SplitEqually account friends -> "split " <> account <> " equally with " <> Text.intercalate ", " (NonEmpty.toList friends)

renderComparison :: Comparison -> Text
renderComparison = \case
  LessThan -> "<"
  AtMost -> "<="
  GreaterThan -> ">"
  AtLeast -> ">="
  EqualTo -> "="
  NotEqualTo -> "!="

renderKind :: BankAccountKind -> Text
renderKind = \case
  Chequing -> "chequing"
  Savings -> "savings"
  CreditCard -> "credit card"

-- | @-1234@ cents is @-12.34@ (no dollar sign, so it reads like what you'd type).
renderAmount :: Cents -> Text
renderAmount cents = Text.replace "$" "" (renderCents cents)

quoted :: Text -> Text
quoted text = "\"" <> Text.concatMap escape text <> "\""
  where
    escape character
      | character == '"' = "\\\""
      | character == '\\' = "\\\\"
      | otherwise = Text.singleton character
