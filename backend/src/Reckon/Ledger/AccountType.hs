-- | The five kinds of ledger account, and how their balances are presented.
module Reckon.Ledger.AccountType
  ( AccountType (..)
  , accountTypeToText
  , accountTypeFromText
  , naturalBalance
  ) where

import Data.Text (Text)
import Data.Text qualified as Text
import Database.Persist.Sql (PersistField (..), PersistFieldSql (..), PersistValue (..), SqlType (..))
import Reckon.Money (Cents, negateCents)

data AccountType
  = Asset
  | Liability
  | Income
  | Expense
  | Equity
  deriving stock (Show, Eq, Ord, Enum, Bounded)

-- | The values stored in @ledger_accounts.account_type@ (a CHECK constraint
-- in the migration lists the same five).
accountTypeToText :: AccountType -> Text
accountTypeToText = \case
  Asset -> "asset"
  Liability -> "liability"
  Income -> "income"
  Expense -> "expense"
  Equity -> "equity"

accountTypeFromText :: Text -> Maybe AccountType
accountTypeFromText text =
  lookup text [(accountTypeToText accountType, accountType) | accountType <- [minBound .. maxBound]]

-- | Stored as text so the column is plain SQL, readable in psql.
instance PersistField AccountType where
  toPersistValue = PersistText . accountTypeToText
  fromPersistValue = \case
    PersistText text -> maybe (Left ("unknown account_type: " <> text)) Right (accountTypeFromText text)
    other -> Left ("account_type: expected text, got " <> Text.pack (show other))

instance PersistFieldSql AccountType where
  sqlType _ = SqlString

-- | Converts a raw ledger balance (debits positive, credits negative) to
-- the sign a person expects to read.
--
-- Assets and expenses normally carry debit balances, so they are shown as
-- stored. Liabilities, income and equity normally carry credit balances, so
-- they are negated: a credit card you owe $120 on has a raw balance of
-- -12000 cents and is shown as 12000.
naturalBalance :: AccountType -> Cents -> Cents
naturalBalance accountType rawBalance = case accountType of
  Asset -> rawBalance
  Expense -> rawBalance
  Liability -> negateCents rawBalance
  Income -> negateCents rawBalance
  Equity -> negateCents rawBalance
