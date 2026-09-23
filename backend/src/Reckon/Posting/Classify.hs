-- | Deciding what each imported bank row *is*, before it becomes a journal
-- entry (DECISIONS D038–D042). Pure: no database.
--
-- Every row becomes exactly one entry: the row's amount on its bank's
-- ledger account, balanced by a /counter account/ chosen here:
--
-- 1. Cancelled or refunded pairs: two rows in the same account with
--    opposite amounts, where one says "cancelled", "reversed", "returned",
--    "declined" or "refund". Both go to the clearing account and net to zero.
-- 2. Transfers between two of my accounts: opposite amounts in different
--    accounts within a few days. Both legs go to the clearing account, so
--    moving money is never counted as spending, and each account still
--    matches its own statement on every date.
-- 3. The first categorization rule whose text appears in the description.
-- 4. A payment to a credit card reckon doesn't track goes to
--    @liability:untracked-cards@, not to spending.
-- 5. Otherwise @expense:uncategorized@ (money out) or @income:uncategorized@
--    (money in).
--
-- Pairing is only accepted when it's unambiguous: each row has exactly one
-- candidate and is that candidate's only candidate. Anything else is left
-- for a person to review, never guessed.
--
-- A row that was posted on a guess (uncategorized, or a payment to an
-- untracked card) can still be paired later, when its other half arrives in
-- a later import. The plan then marks it to be
-- re-posted: its old entry is reversed and a new one posted against the
-- clearing account.
module Reckon.Posting.Classify
  ( EvidenceRow (..)
  , Rule (..)
  , WellKnownAccounts (..)
  , Classification (..)
  , ReviewReason (..)
  , PlannedPosting (..)
  , PostingPlan (..)
  , planPosting
  , searchableDescription
  , matchingRule
  , transferWindowDays
  , cancellationWindowDays
  ) where

import Data.List (find)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (Day, diffDays)
import Reckon.Bank (BankAccountKind (..))
import Reckon.Import.Dedupe (normalizeDescription)
import Reckon.Money (Cents (..), negateCents)

-- | A bank row the planner may post. @account@ identifies the bank account
-- (in practice its ledger account's id).
data EvidenceRow rowId account = EvidenceRow
  { rowId :: rowId
  , bankAccount :: account
  , bankAccountKind :: BankAccountKind
  , transactionDate :: Day
  , description1 :: Text
  , description2 :: Text
  , amount :: Cents
  -- ^ As the bank shows it: negative is money leaving the account.
  , alreadyPosted :: Bool
  -- ^ True for a row already posted on a guess (uncategorized or untracked
  -- card), offered only so a newly imported row can pair with it.
  }
  deriving stock (Show, Eq)

data Rule account = Rule
  { descriptionContains :: Text
  -- ^ Upper-case, as stored.
  , account :: account
  }
  deriving stock (Show, Eq)

-- | The accounts the planner routes to when no rule applies.
data WellKnownAccounts account = WellKnownAccounts
  { clearing :: account
  , untrackedCards :: account
  , uncategorizedExpense :: account
  , uncategorizedIncome :: account
  }
  deriving stock (Show, Eq)

data Classification rowId account
  = -- | Same account, opposite amount, one side cancelled or refunded.
    CancelledPairWith rowId
  | -- | The other side of a transfer between two of my accounts.
    TransferWith rowId
  | CategorizedByRule Text account
  | UntrackedCardPayment
  | Uncategorized
  deriving stock (Show, Eq)

data ReviewReason rowId
  = -- | More than one row could be the other side of this transfer or
    -- cancellation.
    AmbiguousPair [rowId]
  | -- | A zero amount can't be a journal line.
    ZeroAmount
  deriving stock (Show, Eq)

data PlannedPosting rowId account = PlannedPosting
  { row :: EvidenceRow rowId account
  , classification :: Classification rowId account
  , counterAccount :: account
  , replacesExistingEntry :: Bool
  -- ^ The row was posted before, on a guess. Its entry must be reversed
  -- before this one is posted.
  }
  deriving stock (Show, Eq)

data PostingPlan rowId account = PostingPlan
  { postings :: [PlannedPosting rowId account]
  , leftForReview :: [(EvidenceRow rowId account, ReviewReason rowId)]
  }
  deriving stock (Show, Eq)

-- | How far apart the two legs of a transfer may be dated.
transferWindowDays :: Integer
transferWindowDays = 5

-- | How long after a transaction its cancellation or refund may appear.
cancellationWindowDays :: Integer
cancellationWindowDays = 45

-- | Both descriptions, normalized as for dedupe, joined by a space. Rules and
-- heuristics match against this.
searchableDescription :: EvidenceRow rowId account -> Text
searchableDescription row = normalizeDescription (row.description1 <> " " <> row.description2)

-- | The first rule (in the given priority order) whose text appears in the
-- row's description.
matchingRule :: [Rule account] -> EvidenceRow rowId account -> Maybe (Rule account)
matchingRule rules row = find (\rule -> rule.descriptionContains `Text.isInfixOf` searchableDescription row) rules

planPosting ::
  (Ord rowId, Eq account) =>
  WellKnownAccounts account ->
  [Rule account] ->
  -- | Unposted rows, plus rows posted on a guess (marked 'alreadyPosted')
  -- that may pair with them.
  [EvidenceRow rowId account] ->
  PostingPlan rowId account
planPosting wellKnown rules rows =
  PostingPlan
    { postings = pairPostings <> singlePostings
    , leftForReview = zeroAmountRows <> ambiguousRows
    }
  where
    (zeroRows, nonZeroRows) = partitionOn (\row -> row.amount == mempty) rows
    zeroAmountRows = [(row, ZeroAmount) | row <- zeroRows, not row.alreadyPosted]

    -- Cancellations first: "cancelled" in a description is stronger
    -- evidence than a matching amount in another account.
    (cancelPairs, cancelAmbiguous) = pairUniquely isCancellationPair nonZeroRows
    afterCancellations = withoutRows (pairedIds cancelPairs <> Set.fromList (map (\(row, _) -> row.rowId) cancelAmbiguous)) nonZeroRows
    (transferPairs, transferAmbiguous) = pairUniquely isTransferPair afterCancellations
    -- Rows the pairing steps have claimed (paired or ambiguous). Everything
    -- else is classified on its own.
    claimedByPairing =
      pairedIds cancelPairs
        <> pairedIds transferPairs
        <> Set.fromList (map (\(row, _) -> row.rowId) (cancelAmbiguous <> transferAmbiguous))

    pairPostings =
      concat
        [ [leg pairedWith first second, leg pairedWith second first]
        | (pairedWith, pairs) <- [(CancelledPairWith, cancelPairs), (TransferWith, transferPairs)]
        , (first, second) <- pairs
        , -- A pair of two already-posted rows would have been paired when
          -- they were posted. Something new happens only if one side is new.
          not (first.alreadyPosted && second.alreadyPosted)
        ]
    leg pairedWith row other =
      PlannedPosting
        { row
        , classification = pairedWith other.rowId
        , counterAccount = wellKnown.clearing
        , replacesExistingEntry = row.alreadyPosted
        }

    ambiguousRows =
      [ (row, AmbiguousPair (map (.rowId) candidates))
      | (row, candidates) <- cancelAmbiguous <> transferAmbiguous
      , not row.alreadyPosted
      ]

    singlePostings =
      [ classifySingle row
      | row <- nonZeroRows
      , not row.alreadyPosted
      , not (Set.member row.rowId claimedByPairing)
      ]

    classifySingle row = case matchingRule rules row of
      Just rule -> posting row (CategorizedByRule rule.descriptionContains rule.account) rule.account
      Nothing
        | looksLikeCardPayment row -> posting row UntrackedCardPayment wellKnown.untrackedCards
        | row.amount < mempty -> posting row Uncategorized wellKnown.uncategorizedExpense
        | otherwise -> posting row Uncategorized wellKnown.uncategorizedIncome
    posting row classification counterAccount =
      PlannedPosting {row, classification, counterAccount, replacesExistingEntry = False}

    pairedIds pairs = Set.fromList (concat [[first.rowId, second.rowId] | (first, second) <- pairs])
    withoutRows ids = filter (\row -> not (Set.member row.rowId ids))

-- | Same account, opposite amounts, close in time, and one side describes
-- itself as a cancellation or refund.
isCancellationPair :: (Eq account) => EvidenceRow rowId account -> EvidenceRow rowId account -> Bool
isCancellationPair first second =
  first.bankAccount == second.bankAccount
    && first.amount == negateCents second.amount
    && abs (diffDays first.transactionDate second.transactionDate) <= cancellationWindowDays
    && (mentionsCancellation first || mentionsCancellation second)
  where
    mentionsCancellation row =
      any (`Text.isInfixOf` searchableDescription row) ["CANCEL", "REVERS", "RETURN", "DECLIN", "REFUND"]

-- | Different accounts, opposite amounts, close in time.
isTransferPair :: (Eq account) => EvidenceRow rowId account -> EvidenceRow rowId account -> Bool
isTransferPair first second =
  first.bankAccount /= second.bankAccount
    && first.amount == negateCents second.amount
    && abs (diffDays first.transactionDate second.transactionDate) <= transferWindowDays

-- | Money leaving a chequing or savings account with both a payment word and
-- a card word in the description, e.g. "Online Banking payment - AMEX".
looksLikeCardPayment :: EvidenceRow rowId account -> Bool
looksLikeCardPayment row =
  row.bankAccountKind /= CreditCard
    && row.amount < mempty
    && any (`Text.isInfixOf` description) ["PAYMENT", "PMT"]
    && any (`Text.isInfixOf` description) ["VISA", "MASTERCARD", "MASTER CARD", "AMEX", "AMERICAN EXPRESS", "CREDIT CARD"]
  where
    description = searchableDescription row

-- | Pairs rows under a symmetric relation, accepting a pair only when each is
-- the other's one and only candidate. Returns the pairs, and every row that
-- had candidates but no unambiguous pair (with those candidates).
pairUniquely ::
  (Ord rowId) =>
  (EvidenceRow rowId account -> EvidenceRow rowId account -> Bool) ->
  [EvidenceRow rowId account] ->
  ([(EvidenceRow rowId account, EvidenceRow rowId account)], [(EvidenceRow rowId account, [EvidenceRow rowId account])])
pairUniquely related rows = (pairs, ambiguous)
  where
    candidatesOf row = [other | other <- rows, other.rowId /= row.rowId, related row other]
    candidates = Map.fromList [(row.rowId, candidatesOf row) | row <- rows]
    onlyCandidate row = case Map.findWithDefault [] row.rowId candidates of
      [other] -> Just other
      _ -> Nothing
    isMutual row = case onlyCandidate row of
      Just other -> fmap (.rowId) (onlyCandidate other) == Just row.rowId
      Nothing -> False
    pairs =
      [ (row, other)
      | row <- rows
      , isMutual row
      , Just other <- [onlyCandidate row]
      , row.rowId < other.rowId
      ]
    ambiguous =
      [ (row, rowCandidates)
      | row <- rows
      , let rowCandidates = Map.findWithDefault [] row.rowId candidates
      , not (null rowCandidates)
      , not (isMutual row)
      ]

partitionOn :: (a -> Bool) -> [a] -> ([a], [a])
partitionOn predicate items = (filter predicate items, filter (not . predicate) items)
