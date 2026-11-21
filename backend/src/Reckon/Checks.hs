-- | The recurring checks (Phase 7, DECISIONS D070): things a ledger can
-- notice on its own and a person would otherwise forget.
--
-- Pure: a check is a function from a 'Snapshot' of the facts to the
-- 'Reminder's that are true today. "Reckon.Jobs" gathers the snapshot,
-- runs the checks on a schedule, and keeps the reminders in step with what
-- the checks now say ('planReminders').
--
-- * A month has ended and no statement balance was recorded in it, so the
--   ledger hasn't been checked against the bank for that month.
-- * Rows read from screenshots have waited a week for the bank's own
--   export, which is what confirms them.
-- * A due date (the Visa payment on the 15th) is coming up.
module Reckon.Checks
  ( -- * Facts
    Snapshot (..)
  , AccountFacts (..)
  , ProvisionalFacts (..)
  , DueDateFacts (..)

    -- * Reminders
  , ReminderKind (..)
  , reminderKindText
  , reminderKindFromText
  , Reminder (..)
  , runChecks

    -- * The checks, separately (exported for tests)
  , missingStatementMonths
  , statementReminders
  , staleProvisionalReminders
  , dueDateReminders
  , nextDueDate
  , statementGraceDays
  , provisionalStaleAfterDays

    -- * Keeping reminders in step with the checks
  , OpenReminder (..)
  , ReminderPlan (..)
  , planReminders
  ) where

import Data.Int (Int64)
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (Day, addDays, diffDays, fromGregorian, gregorianMonthLength, toGregorian)

-- | Everything the checks look at, as of one day.
data Snapshot = Snapshot
  { today :: Day
  , accounts :: [AccountFacts]
  , provisional :: [ProvisionalFacts]
  , dueDates :: [DueDateFacts]
  }
  deriving stock (Show, Eq)

data AccountFacts = AccountFacts
  { last4 :: Text
  , nickname :: Text
  , firstTransaction :: Maybe Day
  -- ^ The earliest imported row, if any.
  , statementDates :: [Day]
  -- ^ The dates of the statement balances recorded for the account.
  }
  deriving stock (Show, Eq)

-- | A row read from a screenshot that no bank row has confirmed yet.
data ProvisionalFacts = ProvisionalFacts
  { last4 :: Text
  , nickname :: Text
  , readOn :: Day
  -- ^ The day the screenshot was imported.
  }
  deriving stock (Show, Eq)

data DueDateFacts = DueDateFacts
  { dueDateId :: Int64
  , label :: Text
  , dayOfMonth :: Int
  , warnDays :: Int
  }
  deriving stock (Show, Eq)

data ReminderKind = StatementMissing | ProvisionalStale | DueSoon
  deriving stock (Show, Eq, Ord, Enum, Bounded)

-- | The value stored in @reminders.kind@.
reminderKindText :: ReminderKind -> Text
reminderKindText = \case
  StatementMissing -> "statement_missing"
  ProvisionalStale -> "provisional_stale"
  DueSoon -> "due_soon"

reminderKindFromText :: Text -> Maybe ReminderKind
reminderKindFromText text = lookup text [(reminderKindText kind, kind) | kind <- [minBound .. maxBound]]

-- | Something a check wants a person to know. @subject@ says what it is
-- about and stays the same from one run to the next, so a reminder that is
-- still true is recognized as the same one (and its message refreshed).
data Reminder = Reminder
  { kind :: ReminderKind
  , subject :: Text
  , message :: Text
  }
  deriving stock (Show, Eq, Ord)

-- | Every reminder that is true in the snapshot.
runChecks :: Snapshot -> [Reminder]
runChecks snapshot =
  statementReminders snapshot.today snapshot.accounts
    <> staleProvisionalReminders snapshot.today snapshot.provisional
    <> dueDateReminders snapshot.today snapshot.dueDates

-- * Statements

-- | A statement for a month is expected this many days after it ends.
statementGraceDays :: Integer
statementGraceDays = 5

-- | The months, oldest first, that have ended (and had their grace days),
-- since the account's first transaction, in which no statement balance was
-- recorded.
missingStatementMonths :: Day -> AccountFacts -> [(Integer, Int)]
missingStatementMonths today account = case account.firstTransaction of
  Nothing -> []
  Just firstDay ->
    [ month
    | month <- takeWhile isDue (iterate nextMonth (monthOf firstDay))
    , month `notElem` map monthOf account.statementDates
    ]
  where
    -- Months run in order, so the first one that isn't due ends the list
    -- (and the infinite list of months).
    isDue month = addDays statementGraceDays (monthEnd month) < today

monthOf :: Day -> (Integer, Int)
monthOf day = let (year, month, _) = toGregorian day in (year, month)

nextMonth :: (Integer, Int) -> (Integer, Int)
nextMonth (year, month)
  | month >= 12 = (year + 1, 1)
  | otherwise = (year, month + 1)

monthEnd :: (Integer, Int) -> Day
monthEnd (year, month) = fromGregorian year month (gregorianMonthLength year month)

-- | One reminder per account, however many months are missing, so a long
-- history with no statements is one line and not forty.
statementReminders :: Day -> [AccountFacts] -> [Reminder]
statementReminders today accounts =
  [ Reminder {kind = StatementMissing, subject = account.last4, message = describeMissing account.nickname months}
  | account <- accounts
  , months@(_ : _) <- [missingStatementMonths today account]
  ]

describeMissing :: Text -> [(Integer, Int)] -> Text
describeMissing nickname months =
  "No statement balance recorded for "
    <> Text.intercalate ", " (map monthName (take 3 (reverse months)))
    <> (if length months > 3 then " and " <> Text.pack (show (length months - 3)) <> " earlier" else "")
    <> " on "
    <> nickname
    <> ". Record the closing balance from the statement to check the ledger against the bank."

monthName :: (Integer, Int) -> Text
monthName (year, month) = names !! (month - 1) <> " " <> Text.pack (show year)
  where
    names = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]

-- * Screenshots nobody confirmed

-- | A screenshot's rows are confirmed by the bank's CSV. After this many
-- days without one, the bank's export is overdue.
provisionalStaleAfterDays :: Integer
provisionalStaleAfterDays = 7

-- | One reminder per account with rows that have waited that long.
staleProvisionalReminders :: Day -> [ProvisionalFacts] -> [Reminder]
staleProvisionalReminders today rows =
  [ Reminder
      { kind = ProvisionalStale
      , subject = account
      , message =
          Text.pack (show (length waiting))
            <> (if length waiting == 1 then " row" else " rows")
            <> " read from screenshots on "
            <> nickname
            <> " (the oldest "
            <> Text.pack (show (diffDays today (minimum (map (.readOn) waiting))))
            <> " days ago) still "
            <> (if length waiting == 1 then "has" else "have")
            <> " no matching row in a bank export. Import a newer export, or release the ones that never posted."
      }
  | (account, waiting@(first : _)) <- Map.toList byAccount
  , let nickname = first.nickname
  ]
  where
    byAccount = Map.fromListWith (flip (<>)) [(row.last4, [row]) | row <- rows, diffDays today row.readOn >= provisionalStaleAfterDays]

-- * Due dates

-- | The next day, today included, that falls on this day of the month. A
-- month too short for it (the 31st in April) uses its last day.
nextDueDate :: Day -> Int -> Day
nextDueDate today dayOfMonth
  | thisMonth >= today = thisMonth
  | otherwise = inMonth (nextMonth (year, month))
  where
    (year, month, _) = toGregorian today
    thisMonth = inMonth (year, month)
    inMonth (y, m) = fromGregorian y m (min dayOfMonth (gregorianMonthLength y m))

-- | A due date within its warning window. The subject includes the day it
-- falls on, so each month's is its own reminder and last month's resolves
-- by itself once it has passed.
dueDateReminders :: Day -> [DueDateFacts] -> [Reminder]
dueDateReminders today dueDates =
  sortOn (.subject)
    [ Reminder
        { kind = DueSoon
        , subject = Text.pack (show due.dueDateId) <> ":" <> Text.pack (show date)
        , message = due.label <> " is due " <> when' (diffDays date today) <> " (" <> Text.pack (show date) <> ")."
        }
    | due <- dueDates
    , let date = nextDueDate today due.dayOfMonth
    , diffDays date today <= toInteger due.warnDays
    ]
  where
    when' 0 = "today"
    when' 1 = "tomorrow"
    when' days = "in " <> Text.pack (show days) <> " days"

-- * Keeping reminders in step

-- | A reminder as stored, still open.
data OpenReminder = OpenReminder
  { reminderId :: Int64
  , kind :: ReminderKind
  , subject :: Text
  , message :: Text
  }
  deriving stock (Show, Eq)

-- | What to do to the stored reminders so they match what the checks now
-- say.
data ReminderPlan = ReminderPlan
  { toOpen :: [Reminder]
  -- ^ New: not open yet.
  , toRefresh :: [(Int64, Text)]
  -- ^ Still true, with a message that has changed (days until a due date).
  , toResolve :: [Int64]
  -- ^ No longer true.
  }
  deriving stock (Show, Eq)

-- | Compares what the checks report with the open reminders by (kind,
-- subject). Dismissing a reminder is a separate fact, left alone: a
-- dismissed reminder that is still true stays dismissed.
planReminders :: [Reminder] -> [OpenReminder] -> ReminderPlan
planReminders reported open =
  ReminderPlan
    { toOpen = [reminder | reminder <- reported, Map.notMember (key reminder.kind reminder.subject) openByKey]
    , toRefresh = [(stored.reminderId, reminder.message) | reminder <- reported, Just stored <- [Map.lookup (key reminder.kind reminder.subject) openByKey], stored.message /= reminder.message]
    , toResolve = [stored.reminderId | stored <- open, Map.notMember (key stored.kind stored.subject) reportedByKey]
    }
  where
    key kind subject = (kind, subject)
    openByKey = Map.fromList [(key stored.kind stored.subject, stored) | stored <- open]
    reportedByKey = Map.fromList [(key reminder.kind reminder.subject, reminder) | reminder <- reported]
