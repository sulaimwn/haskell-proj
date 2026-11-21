module Reckon.ScreenshotSpec (spec) where

import Control.Monad (forM_)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as ByteString.Char8
import Data.IORef (atomicModifyIORef', modifyIORef', newIORef, readIORef)
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (Day, toGregorian)
import Database.Persist (Entity (..))
import Database.Persist.Sql (PersistValue (..), Single (..), rawExecute, rawSql, toSqlKey)
import Reckon.Anthropic (ClientError (..), Extractor)
import Reckon.App (AppEnv (..))
import Reckon.Bank (mkLast4)
import Reckon.Database.Schema
import Reckon.Ledger (accountBalanceAsOf)
import Reckon.Money (Cents (..))
import Reckon.Posting (PostingSummary (..))
import Reckon.Reconcile (ReconciliationReport (..), recordOpeningBalance, reconcileAccount)
import Reckon.Reconcile.Explain (EvidenceSummary (..), Finding (..), ReconciliationInputs (..))
import Reckon.ScenarioSupport
import Reckon.Screenshot.Align (AlignWarning (..))
import Reckon.Screenshot.Extraction (ExtractionError (..), RowProblem (..))
import Reckon.Screenshot.Import
import Reckon.Screenshot.Store
import Reckon.TestSupport
import Test.Hspec

fixture :: FilePath -> IO ByteString
fixture name = ByteString.readFile ("../fixtures/screenshots/" <> name)

-- | A file the importer takes for a PNG, unique to the scenario so its hash
-- is too.
imageFile :: Scenario -> Text -> ScreenshotFile
imageFile scenario name =
  ScreenshotFile
    { fileName = name
    , content = "\137PNG\r\n\26\nfake image for " <> ByteString.Char8.pack (Text.unpack (scenario.tag <> name))
    }

-- | Hands out the given replies in order, and counts how often it's called.
scripted :: [ByteString] -> IO (Extractor, IO Int)
scripted replies = do
  remaining <- newIORef replies
  calls <- newIORef (0 :: Int)
  let extractor _ = do
        modifyIORef' calls (+ 1)
        atomicModifyIORef' remaining $ \case
          reply : rest -> (rest, Right reply)
          [] -> ([], Left (UnexpectedResponse "no more scripted replies"))
  pure (extractor, readIORef calls)

failing :: ClientError -> Extractor
failing problem _ = pure (Left problem)

-- | Imports the screenshots for the scenario's chequing account.
readScreenshots :: AppEnv -> Scenario -> Day -> Extractor -> [ScreenshotFile] -> IO (Either ImportScreenshotsError ImportScreenshotsOutcome)
readScreenshots env scenario takenOn extractor files = do
  last4 <- maybe (fail "bad last4") pure (mkLast4 scenario.chequingLast4)
  importScreenshots env.databasePool extractor "test-model" last4 takenOn files

imported :: Either ImportScreenshotsError ImportScreenshotsOutcome -> IO StoreSummary
imported = \case
  Right (Imported found) -> pure found.summary
  other -> fail ("expected an import, got " <> show other)

-- | A chequing account with one old, posted $100.00 deposit, so it exists
-- (screenshots are read for an account a CSV has registered) without
-- touching the dates the tests use.
registerAccount :: AppEnv -> Scenario -> IO ()
registerAccount env scenario = do
  importCsv env scenario (header <> "Chequing,00000-0001234,1/5/2026,,\"Opening deposit\",\"\",100.00,\n")
  _ <- post env
  pure ()

-- | What registering the account put in the ledger.
deposit :: Int64
deposit = 10000

-- | The bank's own rows for what the two fake screenshots show, with the
-- gas hold posting for $43.20 instead of $100.00, and the rent row the model
-- wasn't sure of.
bankRows :: Text
bankRows =
  Text.concat
    [ "Chequing,00000-0001234,2/19/2026,,\"PAYROLL DEPOSIT\",\"EXAMPLE EMPLOYER\",1500.00,\n"
    , "Chequing,00000-0001234,2/18/2026,,\"Interac purchase\",\"COFFEE CO\",-4.50,\n"
    , "Chequing,00000-0001234,2/18/2026,,\"Interac purchase\",\"COFFEE CO\",-4.50,\n"
    , "Chequing,00000-0001234,2/17/2026,,\"Interac purchase\",\"CORNER GROCERY\",-42.17,\n"
    , "Chequing,00000-0001234,2/21/2026,,\"Interac purchase\",\"SHELL GAS STATION\",-43.20,\n"
    , "Chequing,00000-0001234,2/16/2026,,\"Online Banking payment - 1111\",\"EXAMPLE HYDRO\",-85.40,\n"
    , "Chequing,00000-0001234,2/15/2026,,\"e-Transfer sent\",\"ALEX EXAMPLE\",-30.00,\n"
    , "Chequing,00000-0001234,2/14/2026,,\"Online Banking payment\",\"RENT TRANSFER\",-1200.00,\n"
    ]

-- | What the bank's rows add up to: 1500.00 - 9.00 - 42.17 - 43.20 - 85.40
-- - 30.00 - 1200.00.
bankRowsTotal :: Int64
bankRowsTotal = 9023

-- | What the screenshots add up to once posted provisionally: payroll, the
-- $100.00 hold, two coffees, grocery, hydro and the e-Transfer. The rent row
-- the model wasn't sure of isn't posted.
provisionalTotal :: Int64
provisionalTotal = 123343

chequingBalance :: AppEnv -> Scenario -> Day -> IO Cents
chequingBalance env scenario date = do
  Entity _ account <- bankAccount env scenario.chequingLast4
  runTestDatabase env (accountBalanceAsOf (bankAccountLedgerAccountId account) date)

-- | Rows read from screenshots that are still unresolved, in the scenario's year.
openInYear :: AppEnv -> Scenario -> IO [OpenProvisional]
openInYear env scenario = do
  everything <- runTestDatabase env openProvisionalRows
  pure [row | row <- everything, yearOf row.date == scenario.year]
  where
    yearOf date = let (year, _, _) = toGregorian date in year

resolutionKinds :: AppEnv -> Scenario -> IO [(Text, Int64)]
resolutionKinds env scenario = do
  found <-
    runTestDatabase env $
      rawSql
        "SELECT p.kind, count(*) FROM provisional_resolutions p \
        \JOIN screenshot_rows s ON s.id = p.screenshot_row_id \
        \JOIN bank_accounts b ON b.id = s.bank_account_id \
        \WHERE b.last4 = ? GROUP BY p.kind ORDER BY p.kind"
        [PersistText scenario.chequingLast4]
  pure [(kind, total) | (Single kind, Single total) <- found]

screenshotRowCount :: AppEnv -> Scenario -> IO Int64
screenshotRowCount env scenario = do
  found <-
    runTestDatabase env $
      rawSql
        "SELECT count(*) FROM screenshot_rows s JOIN bank_accounts b ON b.id = s.bank_account_id WHERE b.last4 = ?"
        [PersistText scenario.chequingLast4]
  pure (sum [total | Single total <- found])

spec :: Spec
spec = beforeAll makeTestEnv $ do
  describe "reading a scroll of screenshots" $ do
    it "joins them, keeps both identical coffees, and posts what it read as provisional entries" $ \env -> do
      scenario <- newScenario env
      registerAccount env scenario
      first <- fixture "scroll-1.json"
      second <- fixture "scroll-2.json"
      (extractor, calls) <- scripted [first, second]

      summary <-
        readScreenshots env scenario (on scenario 2 20) extractor [imageFile scenario "top.png", imageFile scenario "next.png"]
          >>= imported
      calls `shouldReturn` 2
      summary.warnings `shouldBe` []
      (summary.uploadsStored, summary.rowsAdded, summary.rowsAlreadyStored) `shouldBe` (2, 8, 0)
      -- Seven read with confidence are in the ledger; the rent row the model
      -- wasn't sure of is kept but not posted; one partial row was skipped.
      (summary.provisionalPosted, summary.uncertainNotPosted, summary.partialRowsDropped) `shouldBe` (7, 1, 1)
      screenshotRowCount env scenario `shouldReturn` 8

      -- The ledger now shows them: payroll, a $100 hold, two $4.50 coffees,
      -- grocery, hydro and the e-Transfer.
      chequingBalance env scenario (on scenario 2 28) `shouldReturn` Cents (deposit + provisionalTotal)
      open <- openInYear env scenario
      length open `shouldBe` 8
      length [() | row <- open, row.pending] `shouldBe` 1
      length [() | row <- open, not row.posted] `shouldBe` 1

    it "reads nothing twice: the same images again, or the same rows in new images" $ \env -> do
      scenario <- newScenario env
      registerAccount env scenario
      first <- fixture "scroll-1.json"
      second <- fixture "scroll-2.json"
      (extractor, calls) <- scripted [first, second]
      _ <- readScreenshots env scenario (on scenario 2 20) extractor [imageFile scenario "top.png", imageFile scenario "next.png"] >>= imported
      entriesBefore <- entryCount env

      -- The same two files: recognized by their hash, without calling the model.
      readScreenshots env scenario (on scenario 2 20) extractor [imageFile scenario "top.png", imageFile scenario "next.png"]
        `shouldReturn` Right (NothingNew ["top.png", "next.png"])
      calls `shouldReturn` 2

      -- The same transactions in a new image: read, but nothing new is stored or posted.
      (again, _) <- scripted [first]
      summary <- readScreenshots env scenario (on scenario 2 20) again [imageFile scenario "retaken.png"] >>= imported
      (summary.rowsAdded, summary.provisionalPosted) `shouldBe` (0, 0)
      -- The partial row at the bottom of the first screenshot isn't kept, so only 5 are "already known".
      summary.rowsAlreadyStored `shouldBe` 5
      entryCount env `shouldReturn` entriesBefore

  describe "when the bank's CSV arrives" $ do
    it "confirms what was read: the provisional entries give way to the bank's rows, on every date" $ \env -> do
      scenario <- newScenario env
      registerAccount env scenario
      first <- fixture "scroll-1.json"
      second <- fixture "scroll-2.json"
      (extractor, _) <- scripted [first, second]
      _ <- readScreenshots env scenario (on scenario 2 20) extractor [imageFile scenario "top.png", imageFile scenario "next.png"] >>= imported

      importCsv env scenario (header <> bankRows)
      summary <- post env
      -- All eight rows resolve: seven that had entries, and the uncertain one
      -- the model wasn't sure of, which just gets its answer.
      summary.confirmedProvisional `shouldSatisfy` (>= 8)
      resolutionKinds env scenario `shouldReturn` [("confirmed_by_csv", 8)]
      openInYear env scenario `shouldReturn` []

      -- The ledger is exactly the bank's rows, including the hold that posted for less.
      Entity bankId _ <- bankAccount env scenario.chequingLast4
      chequingBalance env scenario (on scenario 2 28) `shouldReturn` Cents (deposit + bankRowsTotal)
      forM_ [on scenario 2 dayOfMonth | dayOfMonth <- [1 .. 28]] $ \date -> do
        ledger <- chequingBalance env scenario date
        posted <- postedSum env bankId date
        ledger `shouldBe` posted

    it "doesn't post what the CSV already has, when the CSV came first" $ \env -> do
      scenario <- newScenario env
      registerAccount env scenario
      importCsv env scenario (header <> bankRows)
      entriesBefore <- entryCount env
      first <- fixture "scroll-1.json"
      second <- fixture "scroll-2.json"
      (extractor, _) <- scripted [first, second]

      summary <- readScreenshots env scenario (on scenario 2 20) extractor [imageFile scenario "top.png", imageFile scenario "next.png"] >>= imported
      (summary.alreadyInCsv, summary.provisionalPosted, summary.uncertainNotPosted) `shouldBe` (8, 0, 0)
      entryCount env `shouldReturn` entriesBefore
      openInYear env scenario `shouldReturn` []

      _ <- post env
      chequingBalance env scenario (on scenario 2 28) `shouldReturn` Cents (deposit + bankRowsTotal)

  describe "a pending hold" $ do
    it "is replaced by its posted version when a later screenshot shows it posted" $ \env -> do
      scenario <- newScenario env
      registerAccount env scenario
      holdPending <- fixture "hold-pending.json"
      posted <- fixture "hold-posted.json"
      (extractor, _) <- scripted [holdPending, posted]

      held <- readScreenshots env scenario (on scenario 3 1) extractor [imageFile scenario "monday.png"] >>= imported
      held.provisionalPosted `shouldBe` 2
      -- The $100 hold and the $12 grocery row are both in the ledger.
      chequingBalance env scenario (on scenario 3 31) `shouldReturn` Cents (deposit - 10000 - 1200)

      replaced <- readScreenshots env scenario (on scenario 3 5) extractor [imageFile scenario "friday.png"] >>= imported
      (replaced.rowsAdded, replaced.supersededHolds, replaced.provisionalPosted) `shouldBe` (1, 1, 1)
      -- Now the $43.20 that really posted counts, and the hold doesn't.
      chequingBalance env scenario (on scenario 3 31) `shouldReturn` Cents (deposit - 4320 - 1200)
      resolutionKinds env scenario `shouldReturn` [("superseded_by_screenshot", 1)]
      -- The reversed hold is dated like the hold, so on March 1 nothing of it remains.
      chequingBalance env scenario (on scenario 3 1) `shouldReturn` Cents (deposit - 1200)

    it "can be released by hand when it never posts, and only once" $ \env -> do
      scenario <- newScenario env
      registerAccount env scenario
      holdPending <- fixture "hold-pending.json"
      (extractor, _) <- scripted [holdPending]
      _ <- readScreenshots env scenario (on scenario 3 1) extractor [imageFile scenario "monday.png"] >>= imported
      open <- openInYear env scenario
      [hold] <- pure [row | row <- open, row.pending]

      runTestDatabase env (releaseProvisional hold.screenshotRowId) `shouldReturn` Right ()
      chequingBalance env scenario (on scenario 3 31) `shouldReturn` Cents (deposit - 1200)
      resolutionKinds env scenario `shouldReturn` [("released", 1)]
      runTestDatabase env (releaseProvisional hold.screenshotRowId) `shouldReturn` Left AlreadyResolved
      runTestDatabase env (releaseProvisional (toSqlKey 0)) `shouldReturn` Left NoSuchScreenshotRow

  describe "a reading that can't be used" $ do
    it "stores nothing and posts nothing, and lists every problem" $ \env -> do
      scenario <- newScenario env
      registerAccount env scenario
      bad <- fixture "bad-rows.json"
      (extractor, _) <- scripted [bad]
      entriesBefore <- entryCount env

      result <- readScreenshots env scenario (on scenario 2 20) extractor [imageFile scenario "bad.png"]
      case result of
        Left (UnusableReply "bad.png" problems) -> do
          length problems `shouldBe` 8
          problems `shouldSatisfy` elem (BadRow 4 ZeroAmount)
        other -> expectationFailure ("expected UnusableReply, got " <> show other)
      screenshotRowCount env scenario `shouldReturn` 0
      entryCount env `shouldReturn` entriesBefore
      -- ...and the image can be tried again, because it was never recorded.
      good <- fixture "hold-posted.json"
      (retry, _) <- scripted [good]
      readScreenshots env scenario (on scenario 3 5) retry [imageFile scenario "bad.png"] >>= imported >>= (\summary -> summary.rowsAdded `shouldBe` 2)

    it "stops before reading anything else when one file fails" $ \env -> do
      scenario <- newScenario env
      registerAccount env scenario
      readScreenshots env scenario (on scenario 2 20) (failing (ApiError 500 "api_error" "overloaded")) [imageFile scenario "one.png"]
        `shouldReturn` Left (CouldNotRead "one.png" (ApiError 500 "api_error" "overloaded"))
      screenshotRowCount env scenario `shouldReturn` 0

    it "refuses a file that isn't an image, or an account that isn't there, without calling the model" $ \env -> do
      scenario <- newScenario env
      registerAccount env scenario
      (extractor, calls) <- scripted []
      readScreenshots env scenario (on scenario 2 20) extractor [ScreenshotFile "notes.txt" "just some text"]
        `shouldReturn` Left (NotAnImage "notes.txt")
      stranger <- newScenario env
      readScreenshots env stranger (on stranger 2 20) extractor [imageFile stranger "x.png"] >>= \case
        Left (AccountProblem _) -> pure ()
        other -> expectationFailure ("expected AccountProblem, got " <> show other)
      calls `shouldReturn` 0

    it "warns when two screenshots share no rows" $ \env -> do
      scenario <- newScenario env
      registerAccount env scenario
      top <- fixture "scroll-1.json"
      unrelated <- fixture "hold-pending.json"
      (extractor, _) <- scripted [top, unrelated]
      summary <- readScreenshots env scenario (on scenario 2 20) extractor [imageFile scenario "a.png", imageFile scenario "b.png"] >>= imported
      summary.warnings `shouldBe` [NoOverlap 1]

  describe "reconciliation with provisional rows" $
    it "names the provisional rows as the reason the ledger is ahead of the statement" $ \env -> do
      scenario <- newScenario env
      registerAccount env scenario
      first <- fixture "scroll-1.json"
      second <- fixture "scroll-2.json"
      (extractor, _) <- scripted [first, second]
      chequing <- bankAccount env scenario.chequingLast4
      runTestDatabase env (recordOpeningBalance chequing (on scenario 1 1) (Cents 5000)) >>= (`shouldSatisfy` isRight)
      _ <- readScreenshots env scenario (on scenario 2 20) extractor [imageFile scenario "top.png", imageFile scenario "next.png"] >>= imported

      -- The bank's statement knows the 50.00 opening balance and the 100.00
      -- deposit only: 150.00. The ledger also has what was read provisionally.
      report <- runTestDatabase env (reconcileAccount chequing (on scenario 2 28) (Cents 15000))
      report.inputs.ledgerBalance `shouldBe` Cents (15000 + provisionalTotal)
      case report.findings of
        ProvisionalRowsExplainGap rows : _ -> do
          length rows `shouldBe` 7
          sum [amount | EvidenceSummary {naturalAmount = Cents amount} <- rows] `shouldBe` 123343
        other -> expectationFailure ("expected the provisional rows to explain the gap, got " <> show other)

  describe "the database, even when Haskell is bypassed," $ do
    it "never changes what was read from a screenshot" $ \env -> do
      scenario <- newScenario env
      registerAccount env scenario
      holdPending <- fixture "hold-pending.json"
      (extractor, _) <- scripted [holdPending]
      _ <- readScreenshots env scenario (on scenario 3 1) extractor [imageFile scenario "monday.png"] >>= imported
      runTestDatabase env (rawExecute "UPDATE screenshot_rows SET amount_cents = 1 WHERE bank_account_id IN (SELECT id FROM bank_accounts WHERE last4 = ?)" [PersistText scenario.chequingLast4])
        `shouldFailMentioning` "screenshot_rows is append-only"
      runTestDatabase env (rawExecute "DELETE FROM screenshot_uploads WHERE file_name = 'monday.png'" [])
        `shouldFailMentioning` "screenshot_uploads is append-only"

    it "refuses a resolution that contradicts its kind" $ \env -> do
      scenario <- newScenario env
      registerAccount env scenario
      holdPending <- fixture "hold-pending.json"
      (extractor, _) <- scripted [holdPending]
      _ <- readScreenshots env scenario (on scenario 3 1) extractor [imageFile scenario "monday.png"] >>= imported
      -- "released" means no bank row and no later screenshot row. Claiming a
      -- bank row as well is nonsense.
      runTestDatabase
        env
        ( rawExecute
            "INSERT INTO provisional_resolutions (screenshot_row_id, kind, raw_bank_row_id) \
            \SELECT s.id, 'released', (SELECT min(id) FROM raw_bank_rows) FROM screenshot_rows s \
            \JOIN bank_accounts b ON b.id = s.bank_account_id WHERE b.last4 = ? LIMIT 1"
            [PersistText scenario.chequingLast4]
        )
        `shouldFailMentioning` "provisional_resolutions_check"
