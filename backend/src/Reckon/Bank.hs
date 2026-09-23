-- | Types describing real bank accounts.
module Reckon.Bank
  ( BankAccountKind (..)
  , bankAccountKindToText
  , bankAccountKindFromText
  , Last4
  , mkLast4
  , last4FromAccountNumber
  , last4Text
  ) where

import Data.Char (isDigit)
import Data.Text (Text)
import Data.Text qualified as Text
import Database.Persist.Sql (PersistField (..), PersistFieldSql (..), PersistValue (..), SqlType (..))

data BankAccountKind
  = Chequing
  | Savings
  | CreditCard
  deriving stock (Show, Eq, Ord, Enum, Bounded)

-- | The values stored in @bank_accounts.account_kind@.
bankAccountKindToText :: BankAccountKind -> Text
bankAccountKindToText = \case
  Chequing -> "chequing"
  Savings -> "savings"
  CreditCard -> "credit_card"

bankAccountKindFromText :: Text -> Maybe BankAccountKind
bankAccountKindFromText text =
  lookup text [(bankAccountKindToText kind, kind) | kind <- [minBound .. maxBound]]

instance PersistField BankAccountKind where
  toPersistValue = PersistText . bankAccountKindToText
  fromPersistValue = \case
    PersistText text -> maybe (Left ("unknown account_kind: " <> text)) Right (bankAccountKindFromText text)
    other -> Left ("account_kind: expected text, got " <> Text.pack (show other))

instance PersistFieldSql BankAccountKind where
  sqlType _ = SqlString

-- | The last four digits of an account number: the only part reckon ever
-- keeps (docs/PRIVACY.md). The constructor is hidden. 'mkLast4' accepts
-- exactly four digits, so a full account number can't be stored here by
-- accident.
newtype Last4 = Last4 Text
  deriving stock (Show, Eq, Ord)

mkLast4 :: Text -> Maybe Last4
mkLast4 text
  | Text.length text == 4 && Text.all isDigit text = Just (Last4 text)
  | otherwise = Nothing

-- | Keeps the last four digits of a full account number such as
-- @"01234-5678901"@ and discards the rest.
last4FromAccountNumber :: Text -> Maybe Last4
last4FromAccountNumber accountNumber =
  let digits = Text.filter isDigit accountNumber
   in if Text.length digits >= 4 then mkLast4 (Text.takeEnd 4 digits) else Nothing

last4Text :: Last4 -> Text
last4Text (Last4 text) = text

instance PersistField Last4 where
  toPersistValue (Last4 text) = PersistText text
  fromPersistValue = \case
    PersistText text -> maybe (Left ("invalid last4: " <> text)) Right (mkLast4 text)
    other -> Left ("last4: expected text, got " <> Text.pack (show other))

instance PersistFieldSql Last4 where
  sqlType _ = SqlString
