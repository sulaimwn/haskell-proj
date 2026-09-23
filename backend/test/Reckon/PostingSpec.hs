module Reckon.PostingSpec (spec) where

import Control.Monad (forM_, void)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.Int (Int64)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Time (Day, fromGregorian)
import Database.Persist (Entity (..))
import Database.Persist.Sql (PersistValue (..), Single (..), fromSqlKey, rawExecute, rawSql, toSqlKey)
import Hedgehog (Gen, PropertyT, evalIO, forAll, (===))
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import Reckon.App (AppEnv)
import Reckon.Bank (mkLast4)
import Reckon.Database.Schema
import Reckon.Import (ImportOutcome (..), importRbcCsv)
import Reckon.Ledger (accountBalanceAsOf)
import Reckon.Money (Cents (..))
import Reckon.Posting
import Reckon.Reconcile
import Reckon.Reconcile.Explain (EvidenceSummary (..), Finding (..), ReconciliationInputs (..))
import Reckon.TestSupport
import Test.Hspec
import Test.Hspec.Hedgehog (hedgehog)

-- | Each test gets its own chequing and Visa account numbers, its own year
-- (so its rows can never pair with another test's), and its own tag in
-- descriptions (so its rules only match its own rows).
data Scenario = Scenario
  { chequingLast4 :: Text
  , visaLast4 :: Text
  , year :: Integer
  , tag :: Text
  }

newScenario :: AppEnv -> IO Scenario
newScenario env = do
  chequingLast4 <- runTestDatabase env uniqueLast4
  visaLast4 <- runTestDatabase env uniqueLast4
  pure Scenario {chequingLast4, visaLast4, year = 3000 + read (Text.unpack chequingLast4), tag = "T" <> chequingLast4}

-- | A date in the scenario's year.
on :: Scenario -> Int -> Int -> Day
on scenario month = fromGregorian scenario.year month

-- | A CSV (fixture or inline) rewritten for the scenario.
forScenario :: Scenario -> Text -> ByteString
forScenario scenario =
  Text.encodeUtf8
    . Text.replace "00000-0001234" ("00000-000" <> scenario.chequingLast4)
    . Text.replace "4500000000009876" ("450000000000" <> scenario.visaLast4)
    . Text.replace "/2026," ("/" <> Text.pack (show scenario.year) <> ",")
    . Text.replace "EXAMPLE" ("EXAMPLE" <> scenario.tag)

importCsv :: AppEnv -> Scenario -> Text -> IO ()
importCsv env scenario csv = do
  result <- runTestDatabase env (importRbcCsv "test.csv" (forScenario scenario csv))
  case result of
    Right (Imported _ _) -> pure ()
    other -> expectationFailure ("import failed: " <> show other)

importFixture :: AppEnv -> Scenario -> IO ()
importFixture env scenario = do
  bytes <- ByteString.readFile "../fixtures/rbc/february-two-accounts.csv"
  importCsv env scenario (Text.decodeUtf8 bytes)

-- | The two rules the fixture tests use, scoped to the scenario's tag.
addFixtureRules :: AppEnv -> Scenario -> IO ()
addFixtureRules env scenario = runTestDatabase env $ do
  void (addCategorizationRule ("EXAMPLE" <> scenario.tag <> " EMPLOYER") "income:job" 100)
  void (addCategorizationRule ("EXAMPLE" <> scenario.tag <> " HYDRO") "expense:utilities" 100)

post :: AppEnv -> IO PostingSummary
post env = runTestDatabase env postPendingRows

-- | Each of the scenario's rows, in date order: description, amount, and the
-- account its entry in effect was posted against (Nothing if unposted).
postedRows :: AppEnv -> Scenario -> IO [(Text, Int64, Maybe Text)]
postedRows env scenario = do
  found <-
    runTestDatabase env $
      rawSql
        "SELECT r.id, r.description_1 || ' | ' || r.description_2, r.amount_cents, \
        \  (SELECT a.name FROM journal_entry_evidence ev \
        \     JOIN journal_lines l ON l.entry_id = ev.entry_id \
        \     JOIN ledger_accounts a ON a.id = l.ledger_account_id \
        \   WHERE ev.raw_bank_row_id = r.id AND l.ledger_account_id <> b.ledger_account_id \
        \     AND NOT EXISTS (SELECT 1 FROM journal_entries rev WHERE rev.reverses_entry_id = ev.entry_id)) \
        \FROM raw_bank_rows r JOIN bank_accounts b ON b.id = r.bank_account_id \
        \WHERE b.last4 IN (?, ?) ORDER BY r.transaction_date, r.id"
        [PersistText scenario.chequingLast4, PersistText scenario.visaLast4]
  pure [(description, amount, counter) | (Single (_ :: Int64), Single description, Single amount, Single counter) <- found]

rowIdsLeftUnposted :: AppEnv -> Scenario -> IO [RawBankRowId]
rowIdsLeftUnposted env scenario = do
  found <-
    runTestDatabase env $
      rawSql
        "SELECT r.id FROM raw_bank_rows r JOIN bank_accounts b ON b.id = r.bank_account_id \
        \WHERE b.last4 IN (?, ?) AND NOT EXISTS ( \
        \  SELECT 1 FROM journal_entry_evidence ev WHERE ev.raw_bank_row_id = r.id \
        \    AND NOT EXISTS (SELECT 1 FROM journal_entries rev WHERE rev.reverses_entry_id = ev.entry_id)) \
        \ORDER BY r.transaction_date, r.id"
        [PersistText scenario.chequingLast4, PersistText scenario.visaLast4]
  pure [toSqlKey rowId | Single rowId <- found]

bankAccount :: AppEnv -> Text -> IO (Entity BankAccount)
bankAccount env last4Text = do
  last4 <- maybe (fail "bad last4") pure (mkLast4 last4Text)
  runTestDatabase env (findBankAccountByLast4 last4) >>= either (fail . Text.unpack) pure

spec :: Spec
spec = beforeAll makeTestEnv $ do
  describe "postPendingRows" $ do
    it "posts every row of a two-account export against the right account" $ \env -> do
      scenario <- newScenario env
      importFixture env scenario
      addFixtureRules env scenario
      _ <- post env
      rows <- postedRows env scenario
      rows
        `shouldBe` [ ("PAYROLL DEPOSIT | EXAMPLE" <> scenario.tag <> " EMPLOYER INC", 150000, Just "income:job")
                   , ("Online Banking payment - 9876 | RBC VISA", -50000, Just "asset:clearing")
                   , ("e-Transfer sent | ALEX EXAMPLE" <> scenario.tag, -3000, Just "asset:clearing")
                   , ("PAYMENT - THANK YOU | ", 50000, Just "asset:clearing")
                   , ("e-Transfer cancelled | ALEX EXAMPLE" <> scenario.tag, 3000, Just "asset:clearing")
                   , ("COFFEE CO | ", -450, Just "expense:uncategorized")
                   , ("Online Banking payment - 4321 | AMEX CREDIT CARD", -12000, Just "liability:untracked-cards")
                   , ("Online Banking payment - 1111 | EXAMPLE" <> scenario.tag <> " HYDRO", -8540, Just "expense:utilities")
                   , ("Online Banking transfer - 5555 | ", -20000, Nothing)
                   , ("PAYMENT - THANK YOU | ", 20000, Nothing)
                   , ("RETURN - BOOKSHOP | ", 20000, Nothing)
                   , ("Interac purchase | CORNER GROCERY", -4217, Just "expense:uncategorized")
                   ]

    it "changes nothing when run again" $ \env -> do
      scenario <- newScenario env
      importFixture env scenario
      _ <- post env
      rowsBefore <- postedRows env scenario
      entriesBefore <- entryCount env
      _ <- post env
      rowsAfter <- postedRows env scenario
      entriesAfter <- entryCount env
      rowsAfter `shouldBe` rowsBefore
      entriesAfter `shouldBe` entriesBefore

    it "keeps each account's ledger balance equal to the sum of its posted rows, on every date" $ \env -> do
      scenario <- newScenario env
      importFixture env scenario
      _ <- post env
      forM_ [scenario.chequingLast4, scenario.visaLast4] $ \last4 -> do
        Entity accountId account <- bankAccount env last4
        forM_ [on scenario 2 dayOfMonth | dayOfMonth <- [1 .. 28]] $ \date -> do
          ledger <- runTestDatabase env (accountBalanceAsOf (bankAccountLedgerAccountId account) date)
          posted <- postedSum env accountId date
          ledger `shouldBe` posted

    it "re-posts a guessed row as a transfer when the other account's export arrives later" $ \env -> do
      scenario <- newScenario env
      importCsv env scenario (header <> "Chequing,00000-0001234,3/3/2026,,\"Online Banking payment - 9876\",\"RBC VISA\",-300.00,\n")
      _ <- post env
      postedRows env scenario `shouldReturn` [("Online Banking payment - 9876 | RBC VISA", -30000, Just "liability:untracked-cards")]
      Entity _ chequingAccount <- bankAccount env scenario.chequingLast4
      balanceBefore <- runTestDatabase env (accountBalanceAsOf (bankAccountLedgerAccountId chequingAccount) (on scenario 3 3))

      importCsv env scenario (header <> "Visa,4500000000009876,3/4/2026,,\"PAYMENT - THANK YOU\",\"\",300.00,\n")
      summary <- post env
      summary.reposted `shouldBe` 1
      postedRows env scenario
        `shouldReturn` [ ("Online Banking payment - 9876 | RBC VISA", -30000, Just "asset:clearing")
                       , ("PAYMENT - THANK YOU | ", 30000, Just "asset:clearing")
                       ]
      -- The old entry was reversed on its own date, so the balance on that
      -- date is unchanged.
      runTestDatabase env (accountBalanceAsOf (bankAccountLedgerAccountId chequingAccount) (on scenario 3 3))
        `shouldReturn` balanceBefore

  describe "reconciliation" $ do
    it "explains the gap, then reconciles once the ambiguous rows are settled by hand" $ \env -> do
      scenario <- newScenario env
      importFixture env scenario
      _ <- post env
      chequing <- bankAccount env scenario.chequingLast4
      runTestDatabase env (recordOpeningBalance chequing (on scenario 1 31) (Cents 100000)) >>= (`shouldSatisfy` isRight)

      report <- runTestDatabase env (reconcileAccount chequing (on scenario 2 28) (Cents 155243))
      report.inputs.ledgerBalance `shouldBe` Cents 175243
      take 1 report.findings
        `shouldBe` [UnpostedRowsExplainGap [EvidenceSummary (on scenario 2 14) "Online Banking transfer - 5555" (Cents (-20000))]]

      [transfer, payment, bookshopReturn] <- rowIdsLeftUnposted env scenario
      forM_ [(transfer, "asset:clearing"), (payment, "asset:clearing"), (bookshopReturn, "income:refunds")] $ \(rowId, account) ->
        runTestDatabase env (postRowManually rowId account) `shouldReturn` Right ()
      runTestDatabase env (postRowManually transfer "asset:clearing") `shouldReturn` Left RowAlreadyPosted

      reconciled <- runTestDatabase env (reconcileAccount chequing (on scenario 2 28) (Cents 155243))
      reconciled.findings `shouldBe` [Reconciled]

    it "only accepts an opening balance dated before the first transaction, and replaces rather than adds" $ \env -> do
      scenario <- newScenario env
      importFixture env scenario
      chequing@(Entity _ account) <- bankAccount env scenario.chequingLast4
      runTestDatabase env (recordOpeningBalance chequing (on scenario 2 5) (Cents 100000))
        `shouldReturn` Left (OpeningBalanceNotBeforeFirstTransaction (on scenario 2 2))
      runTestDatabase env (recordOpeningBalance chequing (on scenario 1 31) (Cents 100000)) >>= (`shouldSatisfy` isRight)
      runTestDatabase env (recordOpeningBalance chequing (on scenario 1 30) (Cents 90000)) >>= (`shouldSatisfy` isRight)
      runTestDatabase env (accountBalanceAsOf (bankAccountLedgerAccountId account) (on scenario 1 31)) `shouldReturn` Cents 90000

    it "takes a credit card's opening balance as the amount owed" $ \env -> do
      scenario <- newScenario env
      importFixture env scenario
      visa@(Entity _ account) <- bankAccount env scenario.visaLast4
      runTestDatabase env (recordOpeningBalance visa (on scenario 1 31) (Cents 25000)) >>= (`shouldSatisfy` isRight)
      -- Owing $250 is a credit balance on a liability: -25000 raw.
      runTestDatabase env (accountBalanceAsOf (bankAccountLedgerAccountId account) (on scenario 1 31)) `shouldReturn` Cents (-25000)

  describe "the database, even when Haskell is bypassed," $ do
    it "refuses to change which row an entry was posted from" $ \env -> do
      scenario <- newScenario env
      importFixture env scenario
      _ <- post env
      runTestDatabase env (rawExecute "UPDATE journal_entry_evidence SET raw_bank_row_id = raw_bank_row_id WHERE entry_id IN (SELECT max(entry_id) FROM journal_entry_evidence)" [])
        `shouldFailMentioning` "journal_entry_evidence is append-only"

    it "refuses to change a recorded statement balance" $ \env -> do
      scenario <- newScenario env
      importFixture env scenario
      chequing <- bankAccount env scenario.chequingLast4
      Right checkpointId <- runTestDatabase env (recordCheckpoint chequing (on scenario 2 28) (Cents 155243))
      runTestDatabase env (rawExecute "UPDATE statement_checkpoints SET statement_balance_cents = 0 WHERE id = ?" [PersistInt64 (fromSqlKey checkpointId)])
        `shouldFailMentioning` "statement_checkpoints is append-only"

  describe "any export (property)" $
    it "leaves every account's ledger balance equal to its posted rows on every date, with transfers netting to zero" $ \env ->
      hedgehog (postingPreservesBalances env)

-- * The property

postingPreservesBalances :: AppEnv -> PropertyT IO ()
postingPreservesBalances env = do
  rows <- forAll (Gen.list (Range.linear 1 20) genCsvRow)
  scenario <- evalIO (newScenario env)
  evalIO (importCsv env scenario (header <> Text.concat rows))
  _ <- evalIO (post env)

  -- The reconciliation identity: an account's ledger balance on any date is
  -- exactly the sum of its rows posted up to that date.
  forM_ [scenario.chequingLast4, scenario.visaLast4] $ \last4 -> do
    accounts <- evalIO (runTestDatabase env (rawSql "SELECT id FROM bank_accounts WHERE last4 = ?" [PersistText last4]))
    forM_ [accountId | Single accountId <- accounts] $ \accountId -> do
      Entity _ account <- evalIO (bankAccountById env accountId)
      forM_ [on scenario 2 dayOfMonth | dayOfMonth <- [1, 7, 14, 21, 28]] $ \date -> do
        ledger <- evalIO (runTestDatabase env (accountBalanceAsOf (bankAccountLedgerAccountId account) date))
        posted <- evalIO (postedSum env accountId date)
        ledger === posted

  -- Everything routed through the clearing account nets to zero: every
  -- transfer and cancellation was posted as a complete pair.
  posted <- evalIO (postedRows env scenario)
  sum [amount | (_, amount, Just "asset:clearing") <- posted] === 0

genCsvRow :: Gen Text
genCsvRow = do
  (account, number) <- Gen.element [("Chequing", "00000-0001234"), ("Visa", "4500000000009876")]
  dayOfMonth <- Gen.int (Range.constant 1 28)
  (description1, description2) <-
    Gen.element
      [ ("Interac purchase", "GROCERY")
      , ("e-Transfer sent", "ALEX")
      , ("e-Transfer cancelled", "ALEX")
      , ("PAYMENT - THANK YOU", "")
      , ("Online Banking payment", "RBC VISA")
      , ("Deposit", "")
      ]
  amount <- Gen.element ["-50.00", "50.00", "-20.00", "20.00", "-12.34"]
  pure (Text.intercalate "," [account, number, "2/" <> Text.pack (show dayOfMonth) <> "/2026", "", quoted description1, quoted description2, amount, ""] <> "\n")
  where
    quoted text = "\"" <> text <> "\""

-- * Helpers

header :: Text
header = "\"Account Type\",\"Account Number\",\"Transaction Date\",\"Cheque Number\",\"Description 1\",\"Description 2\",\"CAD$\",\"USD$\"\n"

bankAccountById :: AppEnv -> BankAccountId -> IO (Entity BankAccount)
bankAccountById env accountId = do
  found <- runTestDatabase env (rawSql "SELECT last4 FROM bank_accounts WHERE id = ?" [PersistInt64 (fromSqlKey accountId)])
  case found of
    [Single last4] -> bankAccount env last4
    _ -> fail "no such bank account"

-- | The sum of an account's rows that have an entry in effect, up to a date.
postedSum :: AppEnv -> BankAccountId -> Day -> IO Cents
postedSum env accountId date = do
  found <-
    runTestDatabase env $
      rawSql
        "SELECT coalesce(sum(r.amount_cents), 0)::bigint FROM raw_bank_rows r \
        \WHERE r.bank_account_id = ? AND r.transaction_date <= ? AND EXISTS ( \
        \  SELECT 1 FROM journal_entry_evidence ev WHERE ev.raw_bank_row_id = r.id \
        \    AND NOT EXISTS (SELECT 1 FROM journal_entries rev WHERE rev.reverses_entry_id = ev.entry_id))"
        [PersistInt64 (fromSqlKey accountId), PersistDay date]
  pure (Cents (sum [total | Single total <- found]))

entryCount :: AppEnv -> IO Int64
entryCount env = do
  found <- runTestDatabase env (rawSql "SELECT count(*) FROM journal_entries" [])
  pure (fromMaybe 0 (case found of [Single total] -> Just total; _ -> Nothing))

isRight :: Either a b -> Bool
isRight = either (const False) (const True)
