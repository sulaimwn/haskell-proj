-- | Money as an exact integer number of cents.
--
-- Money is never a floating point number anywhere in reckon: 0.1 + 0.2 is
-- not 0.3 in floating point, and a ledger that must reconcile to the cent
-- can't tolerate that. 'Cents' wraps an 'Int64' (SQL @BIGINT@).
module Reckon.Money
  ( Cents (..)
  , negateCents
  , sumCents
  , renderCents
  ) where

import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as Text
import Database.Persist.Sql (PersistField, PersistFieldSql)

-- | A signed amount of cents. In the journal, positive is a debit and
-- negative is a credit.
--
-- There is deliberately no 'Num' instance: multiplying two amounts of money
-- is meaningless, and @fromInteger@ would let a bare literal like @5@
-- silently mean five cents. Addition is '<>' ('Semigroup'), zero is
-- 'mempty' ('Monoid').
newtype Cents = Cents Int64
  deriving stock (Show)
  deriving newtype (Eq, Ord, PersistField, PersistFieldSql)

instance Semigroup Cents where
  Cents a <> Cents b = Cents (a + b)

instance Monoid Cents where
  mempty = Cents 0

negateCents :: Cents -> Cents
negateCents (Cents amount) = Cents (negate amount)

sumCents :: (Foldable t) => t Cents -> Cents
sumCents = mconcat . foldr (:) []

-- | For display only: @Cents (-1234)@ is @"-$12.34"@.
renderCents :: Cents -> Text
renderCents (Cents cents) =
  Text.pack ((if cents < 0 then "-" else "") <> "$" <> show (abs cents `div` 100) <> "." <> twoDigits (abs cents `mod` 100))
  where
    twoDigits number = (if number < 10 then "0" else "") <> show number
