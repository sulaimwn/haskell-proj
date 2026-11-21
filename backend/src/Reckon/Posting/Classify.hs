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
-- 3. The first rule (in the rule language, "Reckon.Rules.Language") whose
--    conditions all hold: it either picks an account or splits the payment
--    with friends.
-- 4. Money coming in that mentions a person I share expenses with is
--    probably their repayment. It's left for review with a suggestion, not
--    posted: counting it as income would be wrong, and applying it to their
--    receivable on a guess would be a silent error (DECISIONS D050).
-- 5. A payment to a credit card reckon doesn't track goes to
--    @liability:untracked-cards@, not to spending.
-- 6. Otherwise @expense:uncategorized@ (money out) or @income:uncategorized@
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
  , Outcome (..)
  , containsRule
  , ruleAccount
  , KnownPerson (..)
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

import Data.Either (partitionEithers)
import Data.List (find)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (Day, diffDays)
import Reckon.Bank (BankAccountKind (..))
import Reckon.Import.Dedupe (normalizeDescription)
import Reckon.Money (Cents (..), negateCents)
import Reckon.Posting.Split (Participant (..), equalSplit, splitParts)
import Reckon.Rules.Eval (Candidate (..), allHold)
import Reckon.Rules.Language (Condition (..))

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

-- | A rule from the rule language, with its accounts looked up
-- (@Reckon.Posting.loadRules@ does that). The conditions are the
-- language's; what the rule does is an 'Outcome'.
data Rule account = Rule
  { label :: Text
  -- ^ The rule as text, shown in messages.
  , conditions :: NonEmpty Condition
  , outcome :: Outcome account
  }
  deriving stock (Show, Eq)

data Outcome account
  = -- | Post the row against this account.
    ToAccount account
  | -- | Split a payment equally with these friends (by name). My share goes
    -- to the account.
    SplitWith account (NonEmpty Text)
  deriving stock (Show, Eq)

-- | The account a rule puts my own money in.
ruleAccount :: Rule account -> account
ruleAccount rule = case rule.outcome of
  ToAccount account -> account
  SplitWith account _ -> account

-- | The simplest rule: @description contains TEXT@, then this account.
containsRule :: Text -> account -> Rule account
containsRule text account =
  Rule {label = text, conditions = DescriptionContains text :| [], outcome = ToAccount account}

-- | Someone I share expenses with, as the planner needs to know them.
data KnownPerson account = KnownPerson
  { name :: Text
  , matchText :: Text
  -- ^ Upper-case, as stored: appears in the description of their e-Transfers.
  , account :: account
  -- ^ Their receivable account.
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
  | -- | A rule split the payment: the rule's text, and each non-bank line
    -- of the entry (my share, then each friend's).
    SplitByRule Text [(account, Cents)]
  | UntrackedCardPayment
  | Uncategorized
  deriving stock (Show, Eq)

data ReviewReason rowId
  = -- | More than one row could be the other side of this transfer or
    -- cancellation.
    AmbiguousPair [rowId]
  | -- | A zero amount can't be a journal line.
    ZeroAmount
  | -- | Money in that mentions these people (by name). If it's a repayment,
    -- post it against that person's receivable account.
    PossibleRepayment [Text]
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

-- | The facts about a row that rules can look at.
candidateOf :: EvidenceRow rowId account -> Candidate
candidateOf row = Candidate {description = searchableDescription row, amount = row.amount, kind = row.bankAccountKind}

-- | The first rule (in the given priority order) whose conditions all hold
-- for the row.
matchingRule :: [Rule account] -> EvidenceRow rowId account -> Maybe (Rule account)
matchingRule rules row = find (\rule -> allHold rule.conditions (candidateOf row)) rules

planPosting ::
  (Ord rowId, Eq account) =>
  WellKnownAccounts account ->
  [Rule account] ->
  [KnownPerson account] ->
  -- | Unposted rows, plus rows posted on a guess (marked 'alreadyPosted')
  -- that may pair with them.
  [EvidenceRow rowId account] ->
  PostingPlan rowId account
planPosting wellKnown rules people rows =
  PostingPlan
    { postings = pairPostings <> singlePostings
    , leftForReview = zeroAmountRows <> ambiguousRows <> repaymentRows
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

    singles =
      [ row
      | row <- nonZeroRows
      , not row.alreadyPosted
      , not (Set.member row.rowId claimedByPairing)
      ]
    -- A rule the owner wrote wins over the guess that money in from a
    -- friend is a repayment.
    (repaymentRows, singlePostings) = partitionEithers (map classifySingle singles)

    classifySingle row = case mapMaybe (applyRule row) rules of
      planned : _ -> Right planned
      [] -> case peopleMentioned row of
        [] -> Right (classifyByGuess row)
        names -> Left (row, PossibleRepayment names)
    -- A matching rule that can't be carried out for this row (a split of
    -- money coming in, or with someone who isn't known) is passed over,
    -- not half-applied, so the next rule, or the guess, decides.
    applyRule row rule
      | not (allHold rule.conditions (candidateOf row)) = Nothing
      | otherwise = case rule.outcome of
          ToAccount account -> Just (posting row (CategorizedByRule rule.label account) account)
          SplitWith account friends -> do
            let friendList = NonEmpty.toList friends
            friendAccounts <- Map.fromList . zip friendList <$> traverse (`Map.lookup` receivableOf) friendList
            split <- either (const Nothing) Just (equalSplit row.amount friendList)
            let accountFor = \case
                  Me -> Just account
                  Friend name -> Map.lookup name friendAccounts
                counterLines = [(counter, amount) | (participant, amount) <- splitParts split, Just counter <- [accountFor participant]]
            Just (posting row (SplitByRule rule.label counterLines) account)
    receivableOf = Map.fromList [(person.name, person.account) | person <- people]
    classifyByGuess row
      | looksLikeCardPayment row = posting row UntrackedCardPayment wellKnown.untrackedCards
      | row.amount < mempty = posting row Uncategorized wellKnown.uncategorizedExpense
      | otherwise = posting row Uncategorized wellKnown.uncategorizedIncome
    -- Money arriving in a chequing or savings account whose description
    -- mentions someone I share expenses with.
    peopleMentioned row
      | row.amount > mempty && row.bankAccountKind /= CreditCard =
          [person.name | person <- people, person.matchText `Text.isInfixOf` searchableDescription row]
      | otherwise = []
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
