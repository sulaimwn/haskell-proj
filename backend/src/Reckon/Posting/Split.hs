-- | Splitting one payment between me and my friends (DECISIONS D049).
-- Pure: no database.
--
-- A $120 dinner paid from chequing is one bank row of -$120. As a journal
-- entry it has one line on the bank account and several on the other side:
-- my own share in a category like @expense:food@, and each friend's share
-- as money they owe me, in @receivable:<friend>@. Reported spending then
-- reflects only my share.
module Reckon.Posting.Split
  ( Split
  , SplitError (..)
  , Participant (..)
  , mkSplit
  , equalSplit
  , equalShares
  , splitParts
  ) where

import Data.List (find)
import Data.Set qualified as Set
import Data.Text (Text)
import Reckon.Money (Cents (..), negateCents, sumCents)

-- | Who a part of a split belongs to.
data Participant
  = Me
  | -- | A friend, by the name they were added with.
    Friend Text
  deriving stock (Show, Eq)

data SplitError
  = -- | Only a payment out of an account can be shared.
    OnlyMoneyOutCanBeSplit
  | NoOneToSplitWith
  | -- | A friend's share must be more than zero.
    NonPositiveShare Text
  | PersonListedTwice Text
  | -- | The friends' shares add up to more than the payment. Carries the
    -- shares' total and the payment.
    SharesExceedAmount Cents Cents
  deriving stock (Show, Eq)

-- | A valid split: my share is whatever the friends' shares leave over, so
-- the parts always add up to the payment exactly. The constructor isn't
-- exported, for the same reason as 'Reckon.Ledger.Entry.BalancedLines':
-- anywhere a 'Split' exists, it is known to be valid.
data Split = Split
  { myShare :: Cents
  , friendShares :: [(Text, Cents)]
  }
  deriving stock (Show, Eq)

-- | @mkSplit rowAmount shares@: the bank row's amount (negative, as the bank
-- shows it) and what each friend owes me (positive). I keep the rest.
mkSplit :: Cents -> [(Text, Cents)] -> Either SplitError Split
mkSplit rowAmount shares
  | rowAmount >= mempty = Left OnlyMoneyOutCanBeSplit
  | null shares = Left NoOneToSplitWith
  | Just (name, _) <- find ((<= mempty) . snd) shares = Left (NonPositiveShare name)
  | Just name <- firstDuplicate (map fst shares) = Left (PersonListedTwice name)
  | friendTotal > spent = Left (SharesExceedAmount friendTotal spent)
  | otherwise = Right Split {myShare = spent <> negateCents friendTotal, friendShares = shares}
  where
    spent = negateCents rowAmount
    friendTotal = sumCents (map snd shares)

-- | Everyone, me included, pays the same. When the amount doesn't divide
-- evenly, the odd cents go to me first (the one who paid absorbs the
-- rounding), then to the friends in the order given.
equalSplit :: Cents -> [Text] -> Either SplitError Split
equalSplit rowAmount friends = case equalShares (negateCents rowAmount) (length friends + 1) of
  _myShare : friendAmounts | not (null friends) -> mkSplit rowAmount (zip friends friendAmounts)
  _ -> Left NoOneToSplitWith

-- | An amount cut into @parts@ pieces that differ by at most one cent and
-- add up to the whole. The earliest pieces get the extra cents.
equalShares :: Cents -> Int -> [Cents]
equalShares (Cents total) parts
  | parts <= 0 = []
  | otherwise = [Cents (base + (if fromIntegral index < extra then 1 else 0)) | index <- [0 .. parts - 1]]
  where
    (base, extra) = total `divMod` fromIntegral parts

-- | What goes on the non-bank side of the entry: each part as a positive
-- amount. My share is left out when it's zero (I paid it all for friends).
splitParts :: Split -> [(Participant, Cents)]
splitParts split =
  [(Me, split.myShare) | split.myShare > mempty]
    <> [(Friend name, amount) | (name, amount) <- split.friendShares]

firstDuplicate :: (Ord a) => [a] -> Maybe a
firstDuplicate = go Set.empty
  where
    go _ [] = Nothing
    go seen (item : rest)
      | item `Set.member` seen = Just item
      | otherwise = go (Set.insert item seen) rest
