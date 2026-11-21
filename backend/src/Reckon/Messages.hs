-- | What the app says when it refuses something, in words (Phase 6).
--
-- The command line and the HTTP API both refuse the same things for the
-- same reasons, so the wording lives in one place and both use it.
module Reckon.Messages
  ( describePostingError
  , describeSplitRowError
  , describeSplitError
  , describePersonError
  , describeRuleError
  , describeDueDateError
  , describeReminderError
  , describeOpeningBalanceError
  , describeCheckpointError
  , describeReleaseError
  ) where

import Data.Text (Text)
import Data.Text qualified as Text
import Reckon.Money (renderCents)
import Reckon.People (PersonError (..))
import Reckon.Posting (ManualPostingError (..))
import Reckon.Reminders (DueDateError (..), ReminderError (..))
import Reckon.Rules (RuleError (..))
import Reckon.Rules.Language (renderProblem)
import Reckon.Posting.Split (SplitError (..))
import Reckon.Reconcile (CheckpointError (..), OpeningBalanceError (..))
import Reckon.Screenshot.Store (ReleaseError (..))
import Reckon.Sharing (SplitRowError (..))

-- | @describePostingError rowNumber error@. The row number is the one shown
-- in the review list.
describePostingError :: Text -> ManualPostingError -> Text
describePostingError rowText = \case
  RowNotFound -> "There's no imported row #" <> rowText <> "."
  RowAlreadyPosted -> "Row #" <> rowText <> " is already posted. To move it to another account, recategorize it."
  ZeroAmountRow -> "A zero-amount row can't be posted."
  UnknownAccount name -> "\"" <> name <> "\" must start with expense:, income:, asset:, liability:, receivable: or equity:"
  RowIsPartOfPair ->
    "Row #" <> rowText <> " is one leg of a transfer or a cancelled pair. Moving one leg on its own would leave asset:clearing out of balance."
  EntryRejected entryError -> "The entry was rejected: " <> Text.pack (show entryError)

describeSplitRowError :: Text -> SplitRowError -> Text
describeSplitRowError rowText = \case
  CouldNotPost problem -> describePostingError rowText problem
  UnknownPerson name -> "There's no one called " <> name <> ". Add them first, with the text their e-Transfers contain."
  InvalidSplit problem -> describeSplitError problem

describeSplitError :: SplitError -> Text
describeSplitError = \case
  OnlyMoneyOutCanBeSplit -> "Only a payment out of an account can be split, and this row is money coming in."
  NoOneToSplitWith -> "Name at least one person to split with."
  NonPositiveShare name -> name <> "'s share must be more than zero."
  PersonListedTwice name -> name <> " is listed twice."
  SharesExceedAmount shares amount ->
    "The shares add up to " <> renderCents shares <> ", which is more than the payment of " <> renderCents amount <> "."

describePersonError :: PersonError -> Text
describePersonError = \case
  InvalidPersonName invalid -> "\"" <> invalid <> "\" isn't a valid name: use lower-case letters, digits and hyphens, e.g. alex."
  EmptyMatchText -> "The text to match is empty."
  PersonAlreadyExists existing -> existing <> " has already been added."
  MatchTextAlreadyUsed existing -> "Someone else already matches \"" <> existing <> "\"."

describeRuleError :: RuleError -> Text
describeRuleError = \case
  EmptyRuleText -> "The rule text is empty."
  RuleAlreadyExists existing -> "That rule already exists: " <> existing
  RuleNotFound -> "There is no rule with that number."
  InvalidRule problem -> "That isn't a rule. " <> renderProblem problem
  UnknownAccountPrefix name -> "\"" <> name <> "\" must start with expense:, income:, asset:, liability:, receivable: or equity:"

describeDueDateError :: DueDateError -> Text
describeDueDateError = \case
  EmptyDueDateLabel -> "A due date needs a label, like \"Visa payment\"."
  DayOfMonthOutOfRange day -> "The day of the month must be from 1 to 31, not " <> Text.pack (show day) <> "."
  WarnDaysOutOfRange days -> "The warning must be from 0 to 28 days ahead, not " <> Text.pack (show days) <> "."
  DueDateNotFound -> "There is no due date with that number."

describeReminderError :: ReminderError -> Text
describeReminderError = \case
  ReminderNotFound -> "There is no reminder with that number."
  ReminderNotOpen -> "That reminder is no longer open."

describeOpeningBalanceError :: OpeningBalanceError -> Text
describeOpeningBalanceError = \case
  OpeningBalanceNotBeforeFirstTransaction firstDate ->
    "The opening balance must be from before your first imported transaction ("
      <> Text.pack (show firstDate)
      <> "), or that transaction would be counted twice. Use a statement balance from an earlier date."
  ZeroOpeningBalance -> "A zero opening balance doesn't need recording."

describeCheckpointError :: CheckpointError -> Text
describeCheckpointError (CheckpointAlreadyRecorded existingDate) =
  "A statement balance for " <> Text.pack (show existingDate) <> " is already recorded."

describeReleaseError :: Text -> ReleaseError -> Text
describeReleaseError rowText = \case
  NoSuchScreenshotRow -> "There's no screenshot row #" <> rowText <> "."
  AlreadyResolved -> "#" <> rowText <> " has already been confirmed, replaced or released."
