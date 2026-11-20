module Reckon.SharingSpec (spec) where

import Control.Monad (forM_, void)
import Data.ByteString qualified as ByteString
import Data.Int (Int64)
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Database.Persist (Entity (..))
import Database.Persist.Sql (PersistValue (..), fromSqlKey, rawExecute, toSqlKey)
import Hedgehog (PropertyT, evalIO, forAll, (===))
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import Reckon.App (AppEnv)
import Reckon.Database.Schema
import Reckon.Ledger (accountBalanceAsOf)
import Reckon.Money (Cents (..))
import Reckon.People
import Reckon.Posting
import Reckon.Posting.Classify (ReviewReason (..))
import Reckon.Posting.Split (SplitError (..))
import Reckon.Report (spendingByAccount)
import Reckon.ScenarioSupport
import Reckon.Sharing
import Reckon.TestSupport
import Test.Hspec
import Test.Hspec.Hedgehog (hedgehog)

-- | Names are global, so each scenario's people carry its tag.
alexName, samName, joName :: Scenario -> Text
alexName scenario = "alex-" <> Text.toLower scenario.tag
samName scenario = "sam-" <> Text.toLower scenario.tag
joName scenario = "jo-" <> Text.toLower scenario.tag

-- | alex and sam are matched by their e-Transfer names in the fixture.
addScenarioPeople :: AppEnv -> Scenario -> IO ()
addScenarioPeople env scenario = runTestDatabase env $ do
  void (addPerson (alexName scenario) ("ALEX EXAMPLE" <> scenario.tag))
  void (addPerson (samName scenario) ("SAM EXAMPLE" <> scenario.tag))
  void (addPerson (joName scenario) ("JO EXAMPLE" <> scenario.tag))

importSharedDinner :: AppEnv -> Scenario -> IO ()
importSharedDinner env scenario = do
  bytes <- ByteString.readFile "../fixtures/rbc/shared-dinner.csv"
  importCsv env scenario (Text.decodeUtf8 bytes)

receivable :: Text -> Text
receivable name = "receivable:" <> name

split' :: AppEnv -> Int64 -> Text -> SplitSpec -> IO (Either SplitRowError ())
split' env rowNumber category how = runTestDatabase env (splitRow (toSqlKey rowNumber) category how)

spec :: Spec
spec = beforeAll makeTestEnv $ do
  describe "people" $ do
    it "creates each person's receivable account, and refuses names and texts already in use" $ \env -> do
      scenario <- newScenario env
      runTestDatabase env (addPerson (alexName scenario) ("ALEX  example " <> scenario.tag)) >>= (`shouldSatisfy` isRight)
      runTestDatabase env (addPerson (alexName scenario) "SOMETHING ELSE") `shouldReturn` Left (PersonAlreadyExists (alexName scenario))
      -- The text is compared the way descriptions are: upper case, one space between words.
      runTestDatabase env (addPerson (samName scenario) ("alex example " <> scenario.tag))
        `shouldReturn` Left (MatchTextAlreadyUsed ("ALEX EXAMPLE " <> scenario.tag))
      runTestDatabase env (addPerson "Alex Smith" "ALEX") `shouldReturn` Left (InvalidPersonName "Alex Smith")
      runTestDatabase env (addPerson (samName scenario) "   ") `shouldReturn` Left EmptyMatchText

    it "is refused by the database even when Haskell is bypassed" $ \env -> do
      scenario <- newScenario env
      runTestDatabase env (addPerson (alexName scenario) ("ALEX " <> scenario.tag)) >>= (`shouldSatisfy` isRight)
      Just (Entity _ person) <- runTestDatabase env (findPersonByName (alexName scenario))
      runTestDatabase
        env
        ( rawExecute
            "INSERT INTO people (name, match_text, ledger_account_id) VALUES ('raw-insert', 'lower case', ?)"
            [PersistInt64 (fromSqlKey (personLedgerAccountId person))]
        )
        `shouldFailMentioning` "people_match_text_check"

  describe "splitting a shared payment" $ do
    it "keeps only my share as spending, and records what each friend owes" $ \env -> do
      scenario <- newScenario env
      importSharedDinner env scenario
      addScenarioPeople env scenario
      [dinner, groceries, alexRepayment, samRepayment] <- allRowNumbers env scenario
      summary <- post env

      -- Money in from a known person is suggested as a repayment, not
      -- counted as income. (Posting covers every unposted row in the
      -- database, so look only at this scenario's.)
      [(alexRow, alexReason), (samRow, samReason)] <-
        pure [(fromSqlKey rowId, reason) | (rowId, _, _, _, reason) <- summary.leftForReview, fromSqlKey rowId `elem` [dinner, groceries, alexRepayment, samRepayment]]
      (alexRow, alexReason) `shouldBe` (alexRepayment, PossibleRepayment [alexName scenario])
      (samRow, samReason) `shouldBe` (samRepayment, PossibleRepayment [samName scenario])

      split' env dinner "expense:food" (EqualWith [alexName scenario, samName scenario, joName scenario]) `shouldReturn` Right ()
      entryLinesForRow env dinner
        `shouldReturn` [ ("expense:food", 3000)
                       , (receivable (alexName scenario), 3000)
                       , (receivable (joName scenario), 3000)
                       , (receivable (samName scenario), 3000)
                       ]

      -- Spending counts my $30 of the dinner and the whole grocery run,
      -- not the $90 I'm owed.
      runTestDatabase env (spendingByAccount (on scenario 1 1) (on scenario 12 31))
        `shouldReturn` [("expense:uncategorized", Cents 10000), ("expense:food", Cents 3000)]
      entryLinesForRow env groceries `shouldReturn` [("expense:uncategorized", 10000)]

      owedBy scenario env >>= (`shouldBe` [(alexName scenario, 3000), (joName scenario, 3000), (samName scenario, 3000)])

      -- The repayments settle the receivables: Alex in full, Sam $25 of $30.
      runTestDatabase env (postRowManually (toSqlKey alexRepayment) (receivable (alexName scenario))) `shouldReturn` Right ()
      runTestDatabase env (postRowManually (toSqlKey samRepayment) (receivable (samName scenario))) `shouldReturn` Right ()
      owedBy scenario env >>= (`shouldBe` [(alexName scenario, 0), (joName scenario, 3000), (samName scenario, 500)])

      -- Replacing the dinner's entry didn't change the bank account's
      -- balance on any date: it still equals the rows posted so far.
      Entity bankId account <- bankAccount env scenario.chequingLast4
      forM_ [on scenario 3 dayOfMonth | dayOfMonth <- [1 .. 31]] $ \date -> do
        ledger <- runTestDatabase env (accountBalanceAsOf (bankAccountLedgerAccountId account) date)
        posted <- postedSum env bankId date
        ledger `shouldBe` posted

    it "splits by exact amounts and keeps the rest" $ \env -> do
      scenario <- newScenario env
      importSharedDinner env scenario
      addScenarioPeople env scenario
      _ <- post env
      [dinner, _, _, _] <- allRowNumbers env scenario
      split' env dinner "expense:food" (ExactShares [(alexName scenario, Cents 4500), (samName scenario, Cents 2500)]) `shouldReturn` Right ()
      entryLinesForRow env dinner
        `shouldReturn` [("expense:food", 5000), (receivable (alexName scenario), 4500), (receivable (samName scenario), 2500)]

    it "changes nothing when the split is invalid or names someone unknown" $ \env -> do
      scenario <- newScenario env
      importSharedDinner env scenario
      addScenarioPeople env scenario
      _ <- post env
      [dinner, _, alexRepayment, _] <- allRowNumbers env scenario
      entriesBefore <- entryCount env

      split' env dinner "expense:food" (ExactShares [(alexName scenario, Cents 12001)])
        `shouldReturn` Left (InvalidSplit (SharesExceedAmount (Cents 12001) (Cents 12000)))
      split' env dinner "expense:food" (EqualWith ["nobody-" <> scenario.tag]) `shouldReturn` Left (UnknownPerson ("nobody-" <> scenario.tag))
      split' env dinner "food" (EqualWith [alexName scenario]) `shouldReturn` Left (CouldNotPost (UnknownAccount "food"))
      split' env alexRepayment "expense:food" (EqualWith [alexName scenario]) `shouldReturn` Left (InvalidSplit OnlyMoneyOutCanBeSplit)

      entryLinesForRow env dinner `shouldReturn` [("expense:uncategorized", 12000)]
      entryCount env `shouldReturn` entriesBefore

    it "refuses to move one leg of a transfer on its own" $ \env -> do
      scenario <- newScenario env
      importCsv
        env
        scenario
        ( header
            <> "Chequing,00000-0001234,3/3/2026,,\"Online Banking payment - 9876\",\"RBC VISA\",-300.00,\n"
            <> "Visa,4500000000009876,3/4/2026,,\"PAYMENT - THANK YOU\",\"\",300.00,\n"
        )
      addScenarioPeople env scenario
      _ <- post env
      [payment, _] <- allRowNumbers env scenario
      entriesBefore <- entryCount env
      split' env payment "expense:food" (EqualWith [alexName scenario]) `shouldReturn` Left (CouldNotPost RowIsPartOfPair)
      runTestDatabase env (recategorizeRow (toSqlKey payment) "expense:food") `shouldReturn` Left RowIsPartOfPair
      entryCount env `shouldReturn` entriesBefore

  describe "recategorizing a posted row" $
    it "moves it to another account without changing any balance on any date" $ \env -> do
      scenario <- newScenario env
      importSharedDinner env scenario
      _ <- post env
      [dinner, _, _, _] <- allRowNumbers env scenario
      entryLinesForRow env dinner `shouldReturn` [("expense:uncategorized", 12000)]

      runTestDatabase env (recategorizeRow (toSqlKey dinner) "expense:restaurants") `shouldReturn` Right ()
      entryLinesForRow env dinner `shouldReturn` [("expense:restaurants", 12000)]
      runTestDatabase env (recategorizeRow (toSqlKey dinner) "restaurants") `shouldReturn` Left (UnknownAccount "restaurants")
      runTestDatabase env (recategorizeRow (toSqlKey 0) "expense:food") `shouldReturn` Left RowNotFound

      Entity bankId account <- bankAccount env scenario.chequingLast4
      forM_ [on scenario 3 dayOfMonth | dayOfMonth <- [1 .. 31]] $ \date -> do
        ledger <- runTestDatabase env (accountBalanceAsOf (bankAccountLedgerAccountId account) date)
        posted <- postedSum env bankId date
        ledger `shouldBe` posted

  describe "any split (property)" $
    it "records exactly what each friend owes and what I keep, and the entry balances" $ \env ->
      hedgehog (splitIsExact env)

owedBy :: Scenario -> AppEnv -> IO [(Text, Int64)]
owedBy scenario env = do
  everyone <- runTestDatabase env (whoOwesWhat (on scenario 12 31))
  pure [(person.name, cents) | person <- everyone, Cents cents <- [person.owes], Text.toLower scenario.tag `Text.isSuffixOf` person.name]

-- * The property

splitIsExact :: AppEnv -> PropertyT IO ()
splitIsExact env = do
  friendCount <- forAll (Gen.int (Range.linear 1 3))
  shares <- forAll (Gen.list (Range.singleton friendCount) (Gen.int64 (Range.linear 1 20000)))
  mine <- forAll (Gen.int64 (Range.linear 0 20000))
  let spent = sum shares + mine
  scenario <- evalIO (newScenario env)
  let names = [Text.pack ("f" <> show index) <> "-" <> Text.toLower scenario.tag | index <- [1 .. friendCount]]
  evalIO $
    forM_ (zip [1 :: Int ..] names) $ \(index, name) ->
      runTestDatabase env (addPerson name (Text.pack ("FRIEND" <> show index) <> " EXAMPLE" <> scenario.tag))
  evalIO (importCsv env scenario (header <> "Chequing,00000-0001234,3/3/2026,,\"Interac purchase\",\"SHOP EXAMPLE\",-" <> plainAmount spent <> ",\n"))
  _ <- evalIO (post env)
  [rowNumber] <- evalIO (allRowNumbers env scenario)
  result <- evalIO (split' env rowNumber "expense:shared" (ExactShares (zip names (map Cents shares))))
  result === Right ()
  actual <- evalIO (entryLinesForRow env rowNumber)
  let expected = [("expense:shared", mine) | mine > 0] <> [(receivable name, share) | (name, share) <- zip names shares]
  sort actual === sort expected
  -- Everything that left the bank is accounted for.
  sum (map snd actual) === spent

-- | Cents as plain dollars and cents, e.g. 12345 -> "123.45".
plainAmount :: Int64 -> Text
plainAmount cents = Text.pack (show (cents `div` 100) <> "." <> (if remainder < 10 then "0" else "") <> show remainder)
  where
    remainder = cents `mod` 100
