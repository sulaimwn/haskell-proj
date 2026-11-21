-- | Does a rule apply to a bank row? (Phase 7, DECISIONS D067.)
--
-- Pure and tiny on purpose: the language ("Reckon.Rules.Language") says what
-- a rule means, this says whether it holds for one row, and the planner
-- ("Reckon.Posting.Classify") decides what to do about it.
module Reckon.Rules.Eval
  ( Candidate (..)
  , holds
  , allHold
  , matches
  ) where

import Data.List.NonEmpty (NonEmpty)
import Data.Text (Text)
import Data.Text qualified as Text
import Reckon.Bank (BankAccountKind)
import Reckon.Import.Dedupe (normalizeDescription)
import Reckon.Money (Cents)
import Reckon.Rules.Language

-- | The facts about a bank row that a rule can look at.
data Candidate = Candidate
  { description :: Text
  -- ^ Both description lines, however they're spaced or cased: matching
  -- ignores case and runs of spaces, on both sides.
  , amount :: Cents
  -- ^ As the bank shows it: negative is money out.
  , kind :: BankAccountKind
  }
  deriving stock (Show, Eq)

holds :: Candidate -> Condition -> Bool
holds candidate = \case
  DescriptionContains text -> normalizeDescription text `Text.isInfixOf` description
  DescriptionStartsWith text -> normalizeDescription text `Text.isPrefixOf` description
  DescriptionEndsWith text -> normalizeDescription text `Text.isSuffixOf` description
  AmountIs comparison cents -> compareWith comparison candidate.amount cents
  AccountIs wanted -> candidate.kind == wanted
  where
    description = normalizeDescription candidate.description

compareWith :: (Ord a) => Comparison -> a -> a -> Bool
compareWith = \case
  LessThan -> (<)
  AtMost -> (<=)
  GreaterThan -> (>)
  AtLeast -> (>=)
  EqualTo -> (==)
  NotEqualTo -> (/=)

-- | Every condition holds.
allHold :: NonEmpty Condition -> Candidate -> Bool
allHold conditionList candidate = all (holds candidate) conditionList

matches :: Rule -> Candidate -> Bool
matches rule = allHold rule.conditions
