module Reckon.ImportSpec (spec) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Time (Day, fromGregorian)
import Database.Persist (Entity (..), count, getBy, selectList, (==.))
import Database.Persist.Sql (PersistValue (..), Single (..), fromSqlKey, rawExecute, rawSql)
import Reckon.App (AppEnv)
import Reckon.Database.Schema
import Reckon.Import
import Reckon.Import.Dedupe (ReviewItemKind (..))
import Reckon.Ledger.AccountType (AccountType (..))
import Reckon.TestSupport
import Test.Hspec

spec :: Spec
spec = beforeAll makeTestEnv $ do
  describe "importRbcCsv" $ do
    it "imports a new export, registering the bank account and its ledger account" $ \env -> do
      last4 <- runTestDatabase env uniqueLast4
      summaries <- importFixture env last4 "january.csv"
      map summaryCounts summaries `shouldBe` [("RBC Chequing ending " <> last4, True, 10, 10, 0, 0, 0)]
      ledgerAccount <- runTestDatabase env (getBy (UniqueLedgerAccountName ("asset:rbc-chequing-" <> last4)))
      fmap (ledgerAccountAccountType . entityVal) ledgerAccount `shouldBe` Just Asset

    it "does nothing when the exact same file is imported again" $ \env -> do
      last4 <- runTestDatabase env uniqueLast4
      bytes <- fixtureFor last4 "january.csv"
      _ <- importFixture env last4 "january.csv"
      again <- runTestDatabase env (importRbcCsv "january (copy).csv" bytes)
      again `shouldSatisfy` either (const False) isAlreadyImported
      storedRows <- rowsFor env last4
      length storedRows `shouldBe` 10

    it "imports an overlapping export, adding only what's new and flagging what's unclear" $ \env -> do
      last4 <- runTestDatabase env uniqueLast4
      _ <- importFixture env last4 "january.csv"
      summaries <- importFixture env last4 "mid-january-to-mid-february.csv"
      -- 9 rows: 4 already stored, 5 new (the renamed grocery row, the second
      -- Jan 31 coffee, three February rows). One possible duplicate (the
      -- renamed row), one missing (the Jan 25 bookshop row).
      map summaryCounts summaries `shouldBe` [("RBC Chequing ending " <> last4, False, 9, 5, 4, 1, 1)]

      storedRows <- rowsFor env last4
      length storedRows `shouldBe` 15
      coffeesOn storedRows (fromGregorian 2026 1 20) `shouldBe` 2
      coffeesOn storedRows (fromGregorian 2026 1 31) `shouldBe` 2

      reviewItems <- reviewItemsFor env last4
      let describeRow rowId = maybe "?" (\row -> rawBankRowDescription1 row <> "|" <> rawBankRowDescription2 row) (lookup rowId [(rowKey, row) | Entity rowKey row <- storedRows])
      sort [(importReviewItemKind item, describeRow (importReviewItemRawBankRowId item), fmap describeRow (importReviewItemRelatedRawBankRowId item)) | item <- reviewItems]
        `shouldBe` [ (MissingFromNewerExportKind, "Interac purchase|BOOKSHOP", Nothing)
                   , (PossibleDuplicateKind, "Interac purchase - GROCERY STORE #12|", Just "Interac purchase - GROCERY STORE #0012|")
                   ]

    it "rejects a malformed file and saves nothing" $ \env -> do
      last4 <- runTestDatabase env uniqueLast4
      bytes <- fixtureFor last4 "malformed.csv"
      result <- runTestDatabase env (importRbcCsv "malformed.csv" bytes)
      case result of
        Left (CsvProblems problems) -> length problems `shouldBe` 4
        Right outcome -> expectationFailure ("expected rejection, got " <> show outcome)
      batches <- runTestDatabase env (count [ImportBatchFileSha256 ==. sha256Hex bytes])
      batches `shouldBe` 0

  describe "the database, even when Haskell is bypassed," $ do
    it "refuses a second copy of a row (same account, date, fingerprint and occurrence)" $ \env -> do
      last4 <- runTestDatabase env uniqueLast4
      _ <- importFixture env last4 "january.csv"
      Entity someRowId _ : _ <- rowsFor env last4
      runTestDatabase
        env
        ( rawExecute
            "INSERT INTO raw_bank_rows (bank_account_id, first_seen_batch_id, transaction_date, description_1, description_2, cheque_number, amount_cents, fingerprint, occurrence) \
            \SELECT bank_account_id, first_seen_batch_id, transaction_date, description_1, description_2, cheque_number, amount_cents, fingerprint, occurrence \
            \FROM raw_bank_rows WHERE id = ?"
            [PersistInt64 (fromSqlKey someRowId)]
        )
        `shouldFailMentioning` "duplicate key value violates unique constraint"

    it "refuses to change or delete imported evidence" $ \env -> do
      last4 <- runTestDatabase env uniqueLast4
      _ <- importFixture env last4 "january.csv"
      Entity someRowId _ : _ <- rowsFor env last4
      let rowParameter = [PersistInt64 (fromSqlKey someRowId)]
      runTestDatabase env (rawExecute "UPDATE raw_bank_rows SET amount_cents = 0 WHERE id = ?" rowParameter)
        `shouldFailMentioning` "raw_bank_rows is append-only: UPDATE is not allowed"
      runTestDatabase env (rawExecute "DELETE FROM raw_bank_rows WHERE id = ?" rowParameter)
        `shouldFailMentioning` "raw_bank_rows is append-only: DELETE is not allowed"

    it "never stores more than the last 4 digits of the account number" $ \env -> do
      last4 <- runTestDatabase env uniqueLast4
      _ <- importFixture env last4 "january.csv"
      everything <-
        runTestDatabase env $
          rawSql
            "SELECT row_to_json(stored)::text FROM (\
            \  SELECT bank_accounts.*, raw_bank_rows.* FROM bank_accounts \
            \  JOIN raw_bank_rows ON raw_bank_rows.bank_account_id = bank_accounts.id \
            \  WHERE bank_accounts.last4 = ?) AS stored"
            [PersistText last4]
      let storedText = [text | Single text <- everything]
      length storedText `shouldBe` 10
      storedText `shouldSatisfy` all (\text -> not (fullAccountNumber last4 `Text.isInfixOf` text || fullAccountDigits last4 `Text.isInfixOf` text))

-- * Helpers

-- | The fixture's fake account number, 00000-0001234, rewritten to end in
-- this test's own last 4 digits.
fixtureFor :: Text -> FilePath -> IO ByteString
fixtureFor last4 name = do
  bytes <- ByteString.readFile ("../fixtures/rbc/" <> name)
  pure (Text.encodeUtf8 (Text.replace "00000-0001234" (fullAccountNumber last4) (Text.decodeUtf8 bytes)))

fullAccountNumber :: Text -> Text
fullAccountNumber last4 = "00000-000" <> last4

fullAccountDigits :: Text -> Text
fullAccountDigits last4 = "00000000" <> last4

importFixture :: AppEnv -> Text -> FilePath -> IO [AccountImportSummary]
importFixture env last4 name = do
  bytes <- fixtureFor last4 name
  result <- runTestDatabase env (importRbcCsv (Text.pack name) bytes)
  case result of
    Right (Imported _ summaries) -> pure summaries
    other -> expectationFailure ("expected a fresh import, got " <> show other) >> pure []

isAlreadyImported :: ImportOutcome -> Bool
isAlreadyImported = \case
  AlreadyImported _ -> True
  Imported _ _ -> False

-- | (nickname, newly registered, rows in file, added, already present,
-- possible duplicates, missing from newer export)
summaryCounts :: AccountImportSummary -> (Text, Bool, Int, Int, Int, Int, Int)
summaryCounts summary =
  ( summary.nickname
  , summary.newlyRegistered
  , summary.rowsInFile
  , summary.rowsAdded
  , summary.rowsAlreadyPresent
  , summary.possibleDuplicates
  , summary.missingFromNewerExport
  )

bankAccountFor :: AppEnv -> Text -> IO BankAccountId
bankAccountFor env last4 = do
  [Single bankAccountId] <- runTestDatabase env (rawSql "SELECT id FROM bank_accounts WHERE last4 = ?" [PersistText last4])
  pure bankAccountId

rowsFor :: AppEnv -> Text -> IO [Entity RawBankRow]
rowsFor env last4 = do
  bankAccountId <- bankAccountFor env last4
  runTestDatabase env (selectList [RawBankRowBankAccountId ==. bankAccountId] [])

reviewItemsFor :: AppEnv -> Text -> IO [ImportReviewItem]
reviewItemsFor env last4 = do
  bankAccountId <- bankAccountFor env last4
  map entityVal <$> runTestDatabase env (selectList [ImportReviewItemBankAccountId ==. bankAccountId] [])

coffeesOn :: [Entity RawBankRow] -> Day -> Int
coffeesOn storedRows date =
  length [() | Entity _ row <- storedRows, rawBankRowTransactionDate row == date, rawBankRowDescription2 row == "COFFEE CO"]
