-- | Test scaffolding shared by the specs that import fixtures and post them.
--
-- Posting looks at every unposted row in the database and rules are global,
-- so each test works in its own /scenario/ (DECISIONS D047).
module Reckon.ScenarioSupport
  ( Scenario (..)
  , newScenario
  , on
  , forScenario
  , importCsv
  , header
  , post
  , postedRows
  , entryLinesForRow
  , rowIdsLeftUnposted
  , allRowNumbers
  , bankAccount
  , postedSum
  , entryCount
  , isRight
  ) where

import Data.ByteString (ByteString)
import Data.Int (Int64)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Time (Day, fromGregorian)
import Database.Persist (Entity (..))
import Database.Persist.Sql (PersistValue (..), Single (..), fromSqlKey, rawSql, toSqlKey)
import Reckon.App (AppEnv)
import Reckon.Bank (mkLast4)
import Reckon.Database.Schema
import Reckon.Import (ImportOutcome (..), importRbcCsv)
import Reckon.Money (Cents (..))
import Reckon.Posting (PostingSummary, postPendingRows)
import Reckon.Reconcile (findBankAccountByLast4)
import Reckon.TestSupport
import Test.Hspec (expectationFailure)

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

-- | The lines of the row's entry in effect, other than its bank line:
-- account name and amount, in a stable order. A split row has several.
entryLinesForRow :: AppEnv -> Int64 -> IO [(Text, Int64)]
entryLinesForRow env rowNumber = do
  found <-
    runTestDatabase env $
      rawSql
        "SELECT a.name, l.amount_cents FROM journal_entry_evidence ev \
        \JOIN journal_lines l ON l.entry_id = ev.entry_id \
        \JOIN ledger_accounts a ON a.id = l.ledger_account_id \
        \JOIN raw_bank_rows r ON r.id = ev.raw_bank_row_id \
        \JOIN bank_accounts b ON b.id = r.bank_account_id \
        \WHERE ev.raw_bank_row_id = ? AND l.ledger_account_id <> b.ledger_account_id \
        \  AND NOT EXISTS (SELECT 1 FROM journal_entries rev WHERE rev.reverses_entry_id = ev.entry_id) \
        \ORDER BY a.name"
        [PersistInt64 rowNumber]
  pure [(name, amount) | (Single name, Single amount) <- found]

-- | Every row of the scenario, in date order, as the numbers `make post` prints.
allRowNumbers :: AppEnv -> Scenario -> IO [Int64]
allRowNumbers env scenario = do
  found <-
    runTestDatabase env $
      rawSql
        "SELECT r.id FROM raw_bank_rows r JOIN bank_accounts b ON b.id = r.bank_account_id \
        \WHERE b.last4 IN (?, ?) ORDER BY r.transaction_date, r.id"
        [PersistText scenario.chequingLast4, PersistText scenario.visaLast4]
  pure [rowNumber | Single rowNumber <- found]

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

header :: Text
header = "\"Account Type\",\"Account Number\",\"Transaction Date\",\"Cheque Number\",\"Description 1\",\"Description 2\",\"CAD$\",\"USD$\"\n"

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
