module Reckon.JobsSpec (spec) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (throwIO)
import Control.Monad (void)
import Control.Monad.IO.Class (liftIO)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (Day, NominalDiffTime, UTCTime (..), addUTCTime)
import Database.Persist.Sql (Single (..), rawExecute, rawSql, runSqlPool)
import Reckon.App (AppEnv (..))
import Reckon.Checks
import Reckon.Config (Config (..))
import Reckon.Database (createDatabasePool)
import Reckon.Jobs
import Reckon.Money (Cents (..))
import Reckon.Reconcile (recordCheckpoint)
import Reckon.Reminders
import Reckon.ScenarioSupport
import Reckon.TestSupport
import System.Timeout (timeout)
import Test.Hspec

-- | The queue allows one pending job, and the database is shared between
-- tests, so each queue test first finishes whatever is pending.
clearQueue :: AppEnv -> IO ()
clearQueue env =
  runTestDatabase env (rawExecute "UPDATE jobs SET status = 'succeeded', locked_at = NULL, finished_at = now() WHERE status IN ('queued', 'running')" [])

pendingCount :: AppEnv -> IO Int
pendingCount env = do
  found <- runTestDatabase env (rawSql "SELECT count(*) FROM jobs WHERE status IN ('queued', 'running')" [])
  pure (sum [total | Single total <- found])

at :: Day -> NominalDiffTime -> UTCTime
at day seconds = addUTCTime seconds (UTCTime day 0)

minutes, hours :: NominalDiffTime
minutes = 60
hours = 3600

-- | The reminders whose subject starts with this prefix.
openWith :: AppEnv -> Text -> IO [Text]
openWith env prefix = do
  open <- runTestDatabase env openReminders
  pure [reminder.message | reminder <- open, prefix `Text.isInfixOf` reminder.message]

spec :: Spec
spec = beforeAll makeTestEnv $ do
  describe "the job queue" $ do
    it "keeps one recurring job pending however often it is queued, and the database insists" $ \env -> do
      scenario <- newScenario env
      let t0 = at (on scenario 3 1) 0
      clearQueue env
      runTestDatabase env (ensureRecurring t0 >> ensureRecurring t0 >> ensureRecurring (at (on scenario 3 2) 0))
      pendingCount env `shouldReturn` 1
      runTestDatabase env (rawExecute "INSERT INTO jobs (kind, run_at, status) VALUES ('run_checks', now(), 'queued')" [])
        `shouldFailMentioning` "jobs_one_pending_per_kind"

    it "hands a due job to one worker only, and not before it is due" $ \env -> do
      scenario <- newScenario env
      let t0 = at (on scenario 3 1) (9 * hours)
      clearQueue env
      runTestDatabase env (ensureRecurring t0)
      runTestDatabase env (claimJob (addUTCTime (negate hours) t0)) `shouldReturn` Nothing
      Just job <- runTestDatabase env (claimJob t0)
      job.attempts `shouldBe` 1
      -- While it is held, nobody else gets it.
      runTestDatabase env (claimJob t0) `shouldReturn` Nothing

    it "lets a second worker skip a job the first is claiming, instead of waiting for it" $ \env -> do
      scenario <- newScenario env
      let t0 = at (on scenario 3 1) (9 * hours)
      clearQueue env
      runTestDatabase env (ensureRecurring t0)
      -- The test environment's pool has one connection, so two workers need
      -- a pool of their own.
      pool <- createDatabasePool env.config.databaseUrl 2
      claimed <- newEmptyMVar
      release <- newEmptyMVar
      finished <- newEmptyMVar
      -- The first worker claims inside a transaction it keeps open, so its
      -- lock on the row is still held while the second worker tries.
      _ <-
        forkIO $
          runSqlPool
            ( do
                job <- claimJob t0
                liftIO (putMVar claimed job)
                liftIO (takeMVar release)
            )
            pool
            >>= putMVar finished
      first <- takeMVar claimed
      fmap (.attempts) first `shouldBe` Just 1
      -- The second worker runs on its own thread, so that a worker that
      -- (wrongly) waits for the lock fails the test instead of hanging it.
      secondDone <- newEmptyMVar
      _ <- forkIO (runSqlPool (claimJob t0) pool >>= putMVar secondDone)
      second <- timeout 5_000_000 (takeMVar secondDone)
      putMVar release ()
      takeMVar finished
      -- Answered at once with nothing to do (and did not time out waiting).
      second `shouldBe` Just Nothing

    it "queues the next run a day after one finishes" $ \env -> do
      scenario <- newScenario env
      let t0 = at (on scenario 3 1) (9 * hours)
      clearQueue env
      runTestDatabase env (ensureRecurring t0)
      Just job <- runTestDatabase env (claimJob t0)
      runTestDatabase env (completeJob t0 job)
      runTestDatabase env (claimJob (addUTCTime (23 * hours) t0)) `shouldReturn` Nothing
      next <- runTestDatabase env (claimJob (addUTCTime (24 * hours) t0))
      fmap (.attempts) next `shouldBe` Just 1

    it "retries a failure after a growing delay, gives up after three attempts, and still queues the next regular run" $ \env -> do
      scenario <- newScenario env
      let t0 = at (on scenario 3 1) (9 * hours)
      clearQueue env
      runTestDatabase env (ensureRecurring t0)
      Just first <- runTestDatabase env (claimJob t0)
      runTestDatabase env (failJob t0 first "boom")
      runTestDatabase env (claimJob (addUTCTime (4 * minutes) t0)) `shouldReturn` Nothing
      Just second <- runTestDatabase env (claimJob (addUTCTime (5 * minutes) t0))
      second.attempts `shouldBe` 2
      let t1 = addUTCTime (5 * minutes) t0
      runTestDatabase env (failJob t1 second "boom again")
      -- The wait doubles: ten minutes after the second failure.
      runTestDatabase env (claimJob (addUTCTime (9 * minutes) t1)) `shouldReturn` Nothing
      Just third <- runTestDatabase env (claimJob (addUTCTime (10 * minutes) t1))
      third.attempts `shouldBe` 3
      let t2 = addUTCTime (10 * minutes) t1
      runTestDatabase env (failJob t2 third "still broken")
      -- Given up on, but the schedule goes on.
      runTestDatabase env (claimJob (addUTCTime (23 * hours) t2)) `shouldReturn` Nothing
      next <- runTestDatabase env (claimJob (addUTCTime (24 * hours) t2))
      fmap (.attempts) next `shouldBe` Just 1

    it "takes back a job whose worker never finished" $ \env -> do
      scenario <- newScenario env
      let t0 = at (on scenario 3 1) (9 * hours)
      clearQueue env
      runTestDatabase env (ensureRecurring t0)
      void (runTestDatabase env (claimJob t0))
      runTestDatabase env (requeueStuck (addUTCTime (14 * minutes) t0)) `shouldReturn` 0
      runTestDatabase env (requeueStuck (addUTCTime (16 * minutes) t0)) `shouldReturn` 1
      Just again <- runTestDatabase env (claimJob (addUTCTime (16 * minutes) t0))
      again.attempts `shouldBe` 2

    it "records a handler that throws as a failure, and the worker carries on" $ \env -> do
      scenario <- newScenario env
      let t0 = at (on scenario 3 1) (9 * hours)
      clearQueue env
      runTestDatabase env (ensureRecurring t0)
      outcomes <- runDueJobsWith (\_ _ -> liftIO (throwIO (userError "boom"))) env.databasePool t0
      outcomes `shouldBe` [JobFailed 1 "user error (boom)"]
      -- It is waiting to be retried, not lost.
      runDueJobsWith (\_ _ -> liftIO (throwIO (userError "boom"))) env.databasePool (addUTCTime (5 * minutes) t0)
        `shouldReturn` [JobFailed 2 "user error (boom)"]

  describe "the recurring checks" $ do
    it "reminds about a month with no statement, and stops when one is recorded" $ \env -> do
      scenario <- newScenario env
      importCsv env scenario (inlineCsv [("2/3/2026", "SHOP EXAMPLE", "-8.00")])
      let march = at (on scenario 3 10) 0
      summary <- runTestDatabase env (checkNow march)
      let mine = [reminder | reminder <- summary.reported, reminder.subject == scenario.chequingLast4]
      map (.kind) mine `shouldBe` [StatementMissing]
      openWith env ("ending " <> scenario.chequingLast4) >>= (`shouldSatisfy` ((== 1) . length))

      -- Running again changes nothing.
      again <- runTestDatabase env (checkNow march)
      (again.opened, again.resolved) `shouldBe` (0, 0)

      account <- bankAccount env scenario.chequingLast4
      void (runTestDatabase env (recordCheckpoint account (on scenario 2 28) (Cents 100000)))
      resolved <- runTestDatabase env (checkNow march)
      resolved.resolved `shouldSatisfy` (>= 1)
      openWith env ("ending " <> scenario.chequingLast4) `shouldReturn` []

    it "keeps a dismissed reminder dismissed while it is still true, and never reopens it" $ \env -> do
      scenario <- newScenario env
      importCsv env scenario (inlineCsv [("2/3/2026", "SHOP EXAMPLE", "-8.00")])
      let march = at (on scenario 3 10) 0
      void (runTestDatabase env (checkNow march))
      [mine] <- filter (\reminder -> ("ending " <> scenario.chequingLast4) `Text.isInfixOf` reminder.message) <$> runTestDatabase env openReminders
      runTestDatabase env (dismissReminder march mine.reminderId) `shouldReturn` Right ()
      openWith env ("ending " <> scenario.chequingLast4) `shouldReturn` []
      again <- runTestDatabase env (checkNow (at (on scenario 3 11) 0))
      again.opened `shouldBe` 0
      openWith env ("ending " <> scenario.chequingLast4) `shouldReturn` []
      runTestDatabase env (dismissReminder march 0) `shouldReturn` Left ReminderNotFound

    it "reminds about a due date inside its warning window, with the day it falls on, and lets it go afterwards" $ \env -> do
      scenario <- newScenario env
      Right dueId <- runTestDatabase env (addDueDate ("Visa " <> scenario.tag) 15 (Just 5))
      let subject day = Text.pack (show dueId) <> ":" <> Text.pack (show day)
      early <- runTestDatabase env (checkNow (at (on scenario 6 9) 0))
      [reminder | reminder <- early.reported, reminder.subject == subject (on scenario 6 15)] `shouldBe` []
      inWindow <- runTestDatabase env (checkNow (at (on scenario 6 12) 0))
      map (.message) [reminder | reminder <- inWindow.reported, reminder.subject == subject (on scenario 6 15)]
        `shouldBe` ["Visa " <> scenario.tag <> " is due in 3 days (" <> Text.pack (show (on scenario 6 15)) <> ")."]
      -- Closer, the same reminder says so.
      closer <- runTestDatabase env (checkNow (at (on scenario 6 14) 0))
      closer.refreshed `shouldSatisfy` (>= 1)
      -- After the day, it is next month's and out of the window: resolved.
      afterTheDay <- runTestDatabase env (checkNow (at (on scenario 6 16) 0))
      afterTheDay.resolved `shouldSatisfy` (>= 1)
      runTestDatabase env (deleteDueDate dueId) `shouldReturn` Right ()

    it "validates a due date, and the database agrees" $ \env -> do
      runTestDatabase env (addDueDate "  " 15 Nothing) `shouldReturn` Left EmptyDueDateLabel
      runTestDatabase env (addDueDate "Rent" 0 Nothing) `shouldReturn` Left (DayOfMonthOutOfRange 0)
      runTestDatabase env (addDueDate "Rent" 32 Nothing) `shouldReturn` Left (DayOfMonthOutOfRange 32)
      runTestDatabase env (addDueDate "Rent" 1 (Just 40)) `shouldReturn` Left (WarnDaysOutOfRange 40)
      runTestDatabase env (rawExecute "INSERT INTO due_dates (label, day_of_month) VALUES ('Rent', 40)" [])
        `shouldFailMentioning` "due_dates_day_of_month_check"
      runTestDatabase env (deleteDueDate 0) `shouldReturn` Left DueDateNotFound

    it "runs the checks as a job, records when it last succeeded, and queues the next" $ \env -> do
      scenario <- newScenario env
      let t0 = at (on scenario 4 1) (9 * hours)
      clearQueue env
      runTestDatabase env (ensureRecurring t0)
      outcomes <- runDueJobs env.databasePool t0
      case outcomes of
        [JobSucceeded _] -> pure ()
        other -> expectationFailure ("expected one success, got " <> show other)
      checked <- runTestDatabase env lastCheckedAt
      checked `shouldSatisfy` (/= Nothing)
      pendingCount env `shouldReturn` 1
      -- Nothing more to do until tomorrow.
      runDueJobs env.databasePool (addUTCTime (hours) t0) `shouldReturn` []
