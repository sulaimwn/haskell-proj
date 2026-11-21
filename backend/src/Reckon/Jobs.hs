-- | A small job queue in Postgres, and the worker that runs it (Phase 7,
-- DECISIONS D070).
--
-- One kind of job exists so far: @run_checks@ ("Reckon.Reminders.checkNow"),
-- which re-runs the recurring checks. It is recurring: finishing one queues
-- the next, a day later.
--
-- * **Claiming** is a single @UPDATE ... WHERE id = (SELECT ... FOR UPDATE
--   SKIP LOCKED)@, so two workers (two servers, or two threads) never take
--   the same job, and neither waits for the other.
-- * **At most one pending job per kind** is a database rule (a partial unique
--   index), so a recurring job can't pile up however often it is queued.
-- * **Failure** is recorded and retried with a growing delay, three attempts
--   in all, and then the next regular run is queued anyway: a broken check
--   doesn't stop the schedule.
-- * **A crashed worker** leaves its job @running@; after 15 minutes it is
--   assumed dead and the job goes back in the queue.
--
-- Every function takes the time as an argument, so tests control the clock.
module Reckon.Jobs
  ( JobKind (..)
  , ClaimedJob (..)
  , ensureRecurring
  , claimJob
  , completeJob
  , failJob
  , requeueStuck
  , JobOutcome (..)
  , runDueJobs
  , runDueJobsWith
  , workerLoop
  , recurringInterval
  , maxAttempts
  , retryDelay
  , stuckAfter
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, try)
import Control.Monad (forever)
import Control.Monad.IO.Class (MonadIO)
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (NominalDiffTime, UTCTime, addUTCTime, getCurrentTime)
import Database.Persist.Sql (ConnectionPool, PersistValue (..), Single (..), SqlPersistT, rawExecute, rawSql, runSqlPool)
import Reckon.Reminders (CheckSummary (..), checkNow)
import System.IO (hPutStrLn, stderr)

data JobKind = RunChecks
  deriving stock (Show, Eq)

-- | A job this worker now holds.
data ClaimedJob = ClaimedJob
  { jobId :: Int64
  , kind :: JobKind
  , attempts :: Int
  -- ^ Including this one.
  }
  deriving stock (Show, Eq)

-- | How long after one run the next is due.
recurringInterval :: NominalDiffTime
recurringInterval = 24 * 60 * 60

-- | Attempts before a failing job is given up on (until its next regular run).
maxAttempts :: Int
maxAttempts = 3

-- | The wait before retrying a job that has now failed this many times.
retryDelay :: Int -> NominalDiffTime
retryDelay failedAttempts = fromIntegral failedAttempts * 5 * 60

-- | How long a job can be held before its worker is presumed dead.
stuckAfter :: NominalDiffTime
stuckAfter = 15 * 60

kindText :: JobKind -> Text
kindText RunChecks = "run_checks"

-- | Queues a @run_checks@ job for this time, unless one is already waiting
-- or running (the database allows only one).
ensureRecurring :: (MonadIO m) => UTCTime -> SqlPersistT m ()
ensureRecurring runAt =
  rawExecute "INSERT INTO jobs (kind, run_at, status) VALUES ('run_checks', ?, 'queued') ON CONFLICT DO NOTHING" [PersistUTCTime runAt]

-- | Puts jobs held for too long back in the queue. Returns how many.
requeueStuck :: (MonadIO m) => UTCTime -> SqlPersistT m Int
requeueStuck now = do
  moved <-
    rawSql
      "UPDATE jobs SET status = 'queued', locked_at = NULL, last_error = 'the worker did not finish' \
      \WHERE status = 'running' AND locked_at < ? RETURNING id"
      [PersistUTCTime (addUTCTime (negate stuckAfter) now)]
  pure (length (moved :: [Single Int64]))

-- | Takes the oldest job that is due, if any. Other workers skip a job this
-- one holds instead of waiting for it.
claimJob :: (MonadIO m) => UTCTime -> SqlPersistT m (Maybe ClaimedJob)
claimJob now = do
  claimed <-
    rawSql
      "UPDATE jobs SET status = 'running', locked_at = ?, attempts = attempts + 1 \
      \WHERE id = (SELECT id FROM jobs WHERE status = 'queued' AND run_at <= ? ORDER BY run_at, id LIMIT 1 FOR UPDATE SKIP LOCKED) \
      \RETURNING id, kind, attempts"
      [PersistUTCTime now, PersistUTCTime now]
  pure $ case claimed of
    (Single jobId, Single (kind :: Text), Single attempts) : _ | kind == kindText RunChecks -> Just ClaimedJob {jobId, kind = RunChecks, attempts}
    _ -> Nothing

-- | Marks the job done and queues the next regular run.
completeJob :: (MonadIO m) => UTCTime -> ClaimedJob -> SqlPersistT m ()
completeJob now job = do
  rawExecute "UPDATE jobs SET status = 'succeeded', locked_at = NULL, finished_at = ?, last_error = NULL WHERE id = ?" [PersistUTCTime now, PersistInt64 job.jobId]
  ensureRecurring (addUTCTime recurringInterval now)

-- | Records a failure. The job is retried after a growing delay until it
-- has been tried 'maxAttempts' times; then it is given up on and the next
-- regular run is queued.
failJob :: (MonadIO m) => UTCTime -> ClaimedJob -> Text -> SqlPersistT m ()
failJob now job reason
  | job.attempts < maxAttempts =
      rawExecute
        "UPDATE jobs SET status = 'queued', locked_at = NULL, last_error = ?, run_at = ? WHERE id = ?"
        [PersistText reason, PersistUTCTime (addUTCTime (retryDelay job.attempts) now), PersistInt64 job.jobId]
  | otherwise = do
      rawExecute
        "UPDATE jobs SET status = 'failed', locked_at = NULL, finished_at = ?, last_error = ? WHERE id = ?"
        [PersistUTCTime now, PersistText reason, PersistInt64 job.jobId]
      ensureRecurring (addUTCTime recurringInterval now)

data JobOutcome
  = JobSucceeded CheckSummary
  | -- | The attempt that failed, and why.
    JobFailed Int Text
  deriving stock (Show, Eq)

-- | Runs every job that is due, one at a time, each in its own transactions:
-- claim, run, then record the result. A job that throws is recorded as
-- failed; it never stops the others or the worker.
runDueJobs :: ConnectionPool -> UTCTime -> IO [JobOutcome]
runDueJobs = runDueJobsWith runJob

-- | 'runDueJobs' with the job handler given, so tests can make one fail.
runDueJobsWith :: (UTCTime -> ClaimedJob -> SqlPersistT IO CheckSummary) -> ConnectionPool -> UTCTime -> IO [JobOutcome]
runDueJobsWith handler pool now = do
  claimed <- runSqlPool (requeueStuck now >> claimJob now) pool
  case claimed of
    Nothing -> pure []
    Just job -> do
      result <- try (runSqlPool (handler now job) pool)
      outcome <- case result of
        Right summary -> do
          runSqlPool (completeJob now job) pool
          pure (JobSucceeded summary)
        Left (exception :: SomeException) -> do
          let reason = Text.pack (takeWhile (/= '\n') (show exception))
          runSqlPool (failJob now job reason) pool
          pure (JobFailed job.attempts reason)
      (outcome :) <$> runDueJobsWith handler pool now

runJob :: (MonadIO m) => UTCTime -> ClaimedJob -> SqlPersistT m CheckSummary
runJob now job = case job.kind of
  RunChecks -> checkNow now

-- | The worker: once a minute, make sure the recurring job is queued and run
-- whatever is due. Runs until the program ends, and survives any error.
workerLoop :: ConnectionPool -> IO ()
workerLoop pool = forever $ do
  step <- try $ do
    now <- getCurrentTime
    runSqlPool (ensureRecurring now) pool
    outcomes <- runDueJobs pool now
    mapM_ report outcomes
  case step of
    Left (exception :: SomeException) -> hPutStrLn stderr ("job worker: " <> takeWhile (/= '\n') (show exception))
    Right () -> pure ()
  threadDelay (60 * 1_000_000)
  where
    report = \case
      JobSucceeded summary -> putStrLn ("job run_checks: " <> show (length summary.reported) <> " reminder(s)")
      JobFailed attempt reason -> hPutStrLn stderr ("job run_checks failed (attempt " <> show attempt <> "): " <> Text.unpack reason)
