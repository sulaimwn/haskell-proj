-- | The database side of the recurring checks (Phase 7, DECISIONS D070):
-- gathering what the checks look at, keeping the stored reminders in step
-- with what they say, and the due dates a person configures.
--
-- The checks themselves are pure ("Reckon.Checks"); this module is the
-- plumbing around them, and "Reckon.Jobs" is what runs it on a schedule.
module Reckon.Reminders
  ( -- * Running the checks
    loadSnapshot
  , CheckSummary (..)
  , checkNow
  , recordManualRun
  , renderCheckSummary

    -- * Reminders
  , openReminders
  , ReminderItem (..)
  , dismissReminder
  , ReminderError (..)
  , lastCheckedAt

    -- * Due dates
  , DueDateError (..)
  , addDueDate
  , loadDueDates
  , deleteDueDate
  ) where

import Control.Monad (forM_)
import Control.Monad.IO.Class (MonadIO)
import Data.Aeson qualified as Aeson
import Data.Int (Int64)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Time (UTCTime, utctDay)
import Database.Persist (Entity (..), delete, get, insert, selectList, update, (=.), (==.))
import Database.Persist.Sql (PersistValue (..), Single (..), SqlPersistT, fromSqlKey, rawExecute, rawSql, toSqlKey)
import Database.Persist.Types (SelectOpt (..))
import Reckon.Checks
import Reckon.Database.Schema

-- | What the checks look at, as of the day of @now@.
loadSnapshot :: (MonadIO m) => UTCTime -> SqlPersistT m Snapshot
loadSnapshot now = do
  accountRows <-
    rawSql
      "SELECT b.last4, b.nickname, \
      \  (SELECT min(r.transaction_date) FROM raw_bank_rows r WHERE r.bank_account_id = b.id), \
      \  (SELECT coalesce(json_agg(c.as_of_date ORDER BY c.as_of_date), '[]'::json)::text \
      \     FROM statement_checkpoints c WHERE c.bank_account_id = b.id) \
      \FROM bank_accounts b ORDER BY b.id"
      []
  provisionalRows <-
    rawSql
      "SELECT b.last4, b.nickname, (u.created_at AT TIME ZONE 'UTC')::date \
      \FROM screenshot_rows s \
      \JOIN screenshot_uploads u ON u.id = s.upload_id \
      \JOIN bank_accounts b ON b.id = s.bank_account_id \
      \WHERE NOT EXISTS (SELECT 1 FROM provisional_resolutions p WHERE p.screenshot_row_id = s.id) \
      \ORDER BY s.id"
      []
  dueDates <- loadDueDates
  pure
    Snapshot
      { today = utctDay now
      , accounts =
          [ AccountFacts {last4, nickname, firstTransaction, statementDates = fromMaybe [] (Aeson.decodeStrict (Text.encodeUtf8 datesJson))}
          | (Single last4, Single nickname, Single firstTransaction, Single datesJson) <- accountRows
          ]
      , provisional = [ProvisionalFacts {last4, nickname, readOn} | (Single last4, Single nickname, Single readOn) <- provisionalRows]
      , dueDates
      }

data CheckSummary = CheckSummary
  { reported :: [Reminder]
  -- ^ Everything the checks say is true now.
  , opened :: Int
  , refreshed :: Int
  , resolved :: Int
  }
  deriving stock (Show, Eq)

-- | Runs every check and brings the stored reminders in step: new ones are
-- opened, ones still true get their message refreshed, ones no longer true are
-- resolved. A dismissed reminder that is still true stays dismissed.
checkNow :: (MonadIO m) => UTCTime -> SqlPersistT m CheckSummary
checkNow now = do
  snapshot <- loadSnapshot now
  let reported = runChecks snapshot
  open <- selectList [StoredReminderResolvedAt ==. Nothing] [Asc StoredReminderId]
  let plan =
        planReminders
          reported
          [ OpenReminder {reminderId = fromSqlKey key, kind, subject = storedReminderSubject stored, message = storedReminderMessage stored}
          | Entity key stored <- open
          , Just kind <- [reminderKindFromText (storedReminderKind stored)]
          ]
  forM_ plan.toOpen $ \reminder ->
    insert
      StoredReminder
        { storedReminderKind = reminderKindText reminder.kind
        , storedReminderSubject = reminder.subject
        , storedReminderMessage = reminder.message
        , storedReminderDetectedAt = now
        , storedReminderResolvedAt = Nothing
        , storedReminderDismissedAt = Nothing
        }
  forM_ plan.toRefresh $ \(reminderNumber, message) -> update (toSqlKey reminderNumber) [StoredReminderMessage =. message]
  forM_ plan.toResolve $ \reminderNumber -> update (toSqlKey reminderNumber) [StoredReminderResolvedAt =. Just now]
  pure CheckSummary {reported, opened = length plan.toOpen, refreshed = length plan.toRefresh, resolved = length plan.toResolve}

-- | Notes that the checks were run by hand (not by the schedule), so
-- "last checked" tells the truth. Succeeded jobs aren't limited to one, unlike
-- pending ones.
recordManualRun :: (MonadIO m) => UTCTime -> SqlPersistT m ()
recordManualRun now =
  rawExecute "INSERT INTO jobs (kind, run_at, status, attempts, finished_at) VALUES ('run_checks', ?, 'succeeded', 1, ?)" [PersistUTCTime now, PersistUTCTime now]

renderCheckSummary :: CheckSummary -> Text
renderCheckSummary summary =
  Text.unlines $
    [ if null summary.reported then "Nothing needs your attention." else Text.pack (show (length summary.reported)) <> " thing(s) need your attention:" ]
      <> ["  " <> reminder.message | reminder <- summary.reported]
      <> [ "(" <> Text.pack (show summary.opened) <> " new, " <> Text.pack (show summary.resolved) <> " no longer true.)"
         | summary.opened > 0 || summary.resolved > 0
         ]

-- | A reminder as the screens show it.
data ReminderItem = ReminderItem
  { reminderId :: Int64
  , kind :: ReminderKind
  , message :: Text
  , detectedAt :: UTCTime
  }
  deriving stock (Show, Eq)

-- | Open reminders a person hasn't dismissed, oldest first.
openReminders :: (MonadIO m) => SqlPersistT m [ReminderItem]
openReminders = do
  open <- selectList [StoredReminderResolvedAt ==. Nothing, StoredReminderDismissedAt ==. Nothing] [Asc StoredReminderDetectedAt, Asc StoredReminderId]
  pure
    [ ReminderItem {reminderId = fromSqlKey key, kind, message = storedReminderMessage stored, detectedAt = storedReminderDetectedAt stored}
    | Entity key stored <- open
    , Just kind <- [reminderKindFromText (storedReminderKind stored)]
    ]

data ReminderError = ReminderNotFound | ReminderNotOpen
  deriving stock (Show, Eq)

-- | Hides an open reminder. It stays hidden while it is still true, and goes
-- away on its own when it isn't.
dismissReminder :: (MonadIO m) => UTCTime -> Int64 -> SqlPersistT m (Either ReminderError ())
dismissReminder now reminderNumber = do
  let key = toSqlKey reminderNumber
  found <- get key
  case found of
    Nothing -> pure (Left ReminderNotFound)
    Just stored
      | storedReminderResolvedAt stored /= Nothing -> pure (Left ReminderNotOpen)
      | otherwise -> Right <$> update key [StoredReminderDismissedAt =. Just now]

-- | When the checks last ran successfully.
lastCheckedAt :: (MonadIO m) => SqlPersistT m (Maybe UTCTime)
lastCheckedAt = do
  found <- rawSql "SELECT max(finished_at) FROM jobs WHERE kind = 'run_checks' AND status = 'succeeded'" []
  pure (case found of [Single latest] -> latest; _ -> Nothing)

data DueDateError
  = EmptyDueDateLabel
  | -- | Days of the month run from 1 to 31.
    DayOfMonthOutOfRange Int
  | -- | A warning of 0 to 28 days ahead.
    WarnDaysOutOfRange Int
  | DueDateNotFound
  deriving stock (Show, Eq)

-- | Saves a monthly due date, warning five days ahead unless said otherwise.
addDueDate :: (MonadIO m) => Text -> Int -> Maybe Int -> SqlPersistT m (Either DueDateError Int64)
addDueDate rawLabel dayOfMonth maybeWarn = case (Text.strip rawLabel, dayOfMonth, fromMaybe 5 maybeWarn) of
  (label, _, _) | Text.null label -> pure (Left EmptyDueDateLabel)
  (_, day, _) | day < 1 || day > 31 -> pure (Left (DayOfMonthOutOfRange day))
  (_, _, warn) | warn < 0 || warn > 28 -> pure (Left (WarnDaysOutOfRange warn))
  (label, day, warn) -> Right . fromSqlKey <$> insert DueDate {dueDateLabel = label, dueDateDayOfMonth = day, dueDateWarnDays = warn}

-- | Every due date, in the order they were added.
loadDueDates :: (MonadIO m) => SqlPersistT m [DueDateFacts]
loadDueDates = do
  found <- selectList [] [Asc DueDateId]
  pure [DueDateFacts {dueDateId = fromSqlKey key, label = dueDateLabel due, dayOfMonth = dueDateDayOfMonth due, warnDays = dueDateWarnDays due} | Entity key due <- found]

deleteDueDate :: (MonadIO m) => Int64 -> SqlPersistT m (Either DueDateError ())
deleteDueDate dueDateNumber = do
  let key = toSqlKey dueDateNumber
  found <- get key
  case found of
    Nothing -> pure (Left DueDateNotFound)
    Just _ -> Right <$> delete (key :: DueDateId)
