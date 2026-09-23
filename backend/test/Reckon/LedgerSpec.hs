module Reckon.LedgerSpec (spec) where

import Control.Monad (foldM, forM, forM_, unless)
import Data.Int (Int64)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (Day, fromGregorian)
import Database.Persist (Entity (..), selectList, (==.))
import Database.Persist.Sql (PersistValue (..), Single (..), SqlPersistT, fromSqlKey, rawExecute, rawSql)
import Hedgehog (Gen, PropertyT, evalEither, evalIO, forAll, (===))
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import Reckon.App (AppEnv)
import Reckon.Database.Schema
import Reckon.Ledger
import Reckon.Ledger.AccountType (AccountType (..), accountTypeToText)
import Reckon.Ledger.Entry
import Reckon.Money (Cents (..), sumCents)
import Reckon.TestSupport
import Test.Hspec
import Test.Hspec.Hedgehog (hedgehog)

spec :: Spec
spec = beforeAll makeTestEnv $ do
  describe "posting entries" $
    it "updates balances, counting only entries on or before the as-of date" $ \env -> do
      (cash, food) <- runTestDatabase env (makeAccountPair "cash" "food")
      runTestDatabase env $ do
        postEntry_ =<< entry (day 10) "Coffee" [(food, 450), (cash, -450)]
        postEntry_ =<< entry (day 20) "Groceries" [(food, 1200), (cash, -1200)]

      balances <- runTestDatabase env $
        forM [day 9, day 10, day 31] $ \asOf ->
          (,) <$> accountBalanceAsOf food asOf <*> accountBalanceAsOf cash asOf
      balances
        `shouldBe` [ (Cents 0, Cents 0)
                   , (Cents 450, Cents (-450))
                   , (Cents 1650, Cents (-1650))
                   ]

  describe "reversals" $ do
    it "return every affected balance to its value before the entry" $ \env -> do
      (cash, food) <- runTestDatabase env (makeAccountPair "cash" "food")
      runTestDatabase env $ postEntry_ =<< entry (day 1) "Opening" [(food, 1000), (cash, -1000)]
      balancesBefore <- runTestDatabase env $ (,) <$> accountBalanceAsOf food (day 31) <*> accountBalanceAsOf cash (day 31)

      mistake <- runTestDatabase env $ postEntry =<< entry (day 5) "Typo: $85 instead of $8.50" [(food, 8500), (cash, -8500)]
      reversal <- runTestDatabase env (postReversal mistake (day 6))
      reversal `shouldSatisfy` isRight

      balancesAfter <- runTestDatabase env $ (,) <$> accountBalanceAsOf food (day 31) <*> accountBalanceAsOf cash (day 31)
      balancesAfter `shouldBe` balancesBefore

    it "refuse to reverse the same entry twice" $ \env -> do
      (cash, food) <- runTestDatabase env (makeAccountPair "cash" "food")
      original <- runTestDatabase env $ postEntry =<< entry (day 1) "Lunch" [(food, 1500), (cash, -1500)]
      Right firstReversal <- runTestDatabase env (postReversal original (day 2))
      secondAttempt <- runTestDatabase env (postReversal original (day 3))
      secondAttempt `shouldBe` Left (EntryAlreadyReversed original firstReversal)

    it "refuse to reverse an entry that doesn't exist" $ \env -> do
      let missing = JournalEntryKey 999999999
      result <- runTestDatabase env (postReversal missing (day 1))
      result `shouldBe` Left (EntryNotFound missing)

  -- Each of these bypasses the Haskell layer and writes raw SQL, to show the
  -- database itself enforces the rule.
  describe "the database, even when Haskell is bypassed," $ do
    it "rejects an entry whose lines don't sum to zero (and saves nothing)" $ \env -> do
      (cash, food) <- runTestDatabase env (makeAccountPair "cash" "food")
      description <- runTestDatabase env (("unbalanced " <>) <$> uniqueSuffix)
      runTestDatabase env (rawEntry description [(food, 500), (cash, -400)])
        `shouldFailMentioning` "is unbalanced: its lines sum to 100 cents"
      saved <- runTestDatabase env (selectList [JournalEntryDescription ==. description] [])
      saved `shouldBe` []

    it "rejects an entry with a single line" $ \env -> do
      (_, food) <- runTestDatabase env (makeAccountPair "cash" "food")
      runTestDatabase env (rawEntry "one line" [(food, 500)])
        `shouldFailMentioning` "an entry needs at least 2"

    it "rejects an entry with no lines" $ \env ->
      runTestDatabase env (rawEntry "no lines" [])
        `shouldFailMentioning` "an entry needs at least 2"

    it "rejects UPDATE and DELETE on the journal" $ \env -> do
      (cash, food) <- runTestDatabase env (makeAccountPair "cash" "food")
      entryId <- runTestDatabase env $ postEntry =<< entry (day 1) "Snack" [(food, 300), (cash, -300)]
      let entryParameter = [PersistInt64 (fromSqlKey entryId)]
      runTestDatabase env (rawExecute "UPDATE journal_lines SET amount_cents = amount_cents * 2 WHERE entry_id = ?" entryParameter)
        `shouldFailMentioning` "journal_lines is append-only: UPDATE is not allowed"
      runTestDatabase env (rawExecute "DELETE FROM journal_entries WHERE id = ?" entryParameter)
        `shouldFailMentioning` "journal_entries is append-only: DELETE is not allowed"

    it "rejects adding lines to an entry committed earlier" $ \env -> do
      (cash, food) <- runTestDatabase env (makeAccountPair "cash" "food")
      entryId <- runTestDatabase env $ postEntry =<< entry (day 1) "Snack" [(food, 300), (cash, -300)]
      -- A balanced pair of extra lines: the balance check alone wouldn't catch it.
      runTestDatabase env (forM_ [(food, 5000), (cash, -5000)] (rawLine entryId))
        `shouldFailMentioning` "it was created in an earlier transaction"

    it "rejects a reversal that doesn't exactly cancel the original" $ \env -> do
      (cash, food) <- runTestDatabase env (makeAccountPair "cash" "food")
      original <- runTestDatabase env $ postEntry =<< entry (day 1) "Dinner" [(food, 4000), (cash, -4000)]
      let partialReversal = do
            [Single reversalId] <-
              rawSql
                "INSERT INTO journal_entries (occurred_on, description, reverses_entry_id) VALUES ('2026-01-02', 'bad reversal', ?) RETURNING id"
                [PersistInt64 (fromSqlKey original)]
            forM_ [(food, -3000), (cash, 3000)] (rawLine (JournalEntryKey reversalId))
      runTestDatabase env partialReversal
        `shouldFailMentioning` "does not exactly reverse entry"

  describe "random sequences of entries and reversals (property)" $
    it "keep every entry balanced, the books summing to zero, and each balance equal to a simple model" $ \env ->
      hedgehog (ledgerMatchesModel env)

-- * The property

-- | One step of a random scenario, over four accounts numbered 0 to 3.
data Operation
  = PostRandomEntry Day [(Int, Int64)]
  | -- | Reverse the Nth still-unreversed entry (modulo how many there are).
    ReverseSomeEntry Int Day
  deriving stock (Show)

-- | An entry the test has posted: its id, and its lines as (day, account, amount).
data PostedEntry = PostedEntry JournalEntryId [(Day, Int, Int64)]

ledgerMatchesModel :: AppEnv -> PropertyT IO ()
ledgerMatchesModel env = do
  operations <- forAll (Gen.list (Range.linear 1 25) genOperation)
  checkpoint <- forAll genDay

  suffix <- evalIO (runTestDatabase env uniqueSuffix)
  accounts <-
    evalIO . runTestDatabase env $
      forM (zip [0 :: Int ..] [Asset, Liability, Income, Expense]) $ \(index, accountType) ->
        createLedgerAccount (accountName accountType index suffix) accountType
  let accountAt index = accounts !! index

      -- Run each operation against the real database, one transaction each,
      -- and remember what we posted: (every entry posted, entries still reversible).
      step (posted, reversible) = \case
        PostRandomEntry occurredOn randomLines -> do
          newEntry <- evalEither (buildEntry occurredOn randomLines)
          entryId <- evalIO (runTestDatabase env (postEntry newEntry))
          let record = PostedEntry entryId [(occurredOn, index, amount) | (index, amount) <- randomLines]
          pure (record : posted, record : reversible)
        ReverseSomeEntry choice reversalDate
          | null reversible -> pure (posted, reversible)
          | otherwise -> do
              let PostedEntry targetId targetLines = reversible !! (choice `mod` length reversible)
              reversalId <- evalEither =<< evalIO (runTestDatabase env (postReversal targetId reversalDate))
              let record = PostedEntry reversalId [(reversalDate, index, negate amount) | (_, index, amount) <- targetLines]
                  stillReversible = record : filter (\(PostedEntry entryId _) -> entryId /= targetId) reversible
              pure (record : posted, stillReversible)

      buildEntry occurredOn randomLines = do
        balanced <- mkBalancedLines [EntryLine (accountAt index) (Cents amount) | (index, amount) <- randomLines]
        mkNewJournalEntry occurredOn "random entry" balanced

  (posted, _) <- foldM step ([], []) operations

  -- The model: an account's balance is the sum of the amounts posted to it.
  let modelLines = concat [entryLines | PostedEntry _ entryLines <- posted]
      modelBalanceAsOf asOf =
        Map.fromListWith (+) ([(index, 0) | index <- [0 .. 3]] <> [(index, amount) | (occurredOn, index, amount) <- modelLines, occurredOn <= asOf])

  forM_ [checkpoint, farFuture] $ \asOf -> do
    databaseBalances <- evalIO . runTestDatabase env $ forM accounts (`accountBalanceAsOf` asOf)
    -- Each balance matches the model...
    databaseBalances === map Cents (Map.elems (modelBalanceAsOf asOf))
    -- ...and the books balance: every debit has an equal credit.
    sumCents databaseBalances === Cents 0

  -- Every entry, as stored, has at least two lines summing to zero.
  forM_ posted $ \(PostedEntry entryId _) -> do
    storedLines <- evalIO (runTestDatabase env (selectList [JournalLineEntryId ==. entryId] []))
    let amounts = [journalLineAmountCents line | Entity _ line <- storedLines]
    unless (length amounts >= 2) (fail ("entry has fewer than 2 lines: " <> show entryId))
    sumCents amounts === Cents 0

genOperation :: Gen Operation
genOperation =
  Gen.frequency
    [ (3, PostRandomEntry <$> genDay <*> genRandomLines)
    , (1, ReverseSomeEntry <$> Gen.int (Range.linear 0 50) <*> genDay)
    ]

-- | 2 to 6 non-zero amounts that sum to zero, each on a random account.
genRandomLines :: Gen [(Int, Int64)]
genRandomLines = do
  leading <- Gen.list (Range.linear 1 5) (Gen.filter (/= 0) (Gen.int64 (Range.linearFrom 0 (-1000000) 1000000)))
  let amounts = leading <> [negate (sum leading)]
  if 0 `elem` amounts
    then genRandomLines
    else forM amounts $ \amount -> (,amount) <$> Gen.int (Range.constant 0 3)

genDay :: Gen Day
genDay = day <$> Gen.int (Range.constant 1 28)

farFuture :: Day
farFuture = fromGregorian 2100 1 1

-- | e.g. "liability:property-3f2a…-1"
accountName :: AccountType -> Int -> Text -> Text
accountName accountType index suffix =
  accountTypeToText accountType <> ":property-" <> suffix <> "-" <> Text.pack (show index)

-- * Helpers

day :: Int -> Day
day = fromGregorian 2026 1

-- | Two fresh accounts, an asset and an expense.
makeAccountPair :: Text -> Text -> SqlPersistT IO (LedgerAccountId, LedgerAccountId)
makeAccountPair assetDetail expenseDetail = do
  suffix <- uniqueSuffix
  asset <- createLedgerAccount ("asset:" <> assetDetail <> "-" <> suffix) Asset
  expense <- createLedgerAccount ("expense:" <> expenseDetail <> "-" <> suffix) Expense
  pure (asset, expense)

-- | Builds a valid entry, failing the test if the lines don't balance.
entry :: Day -> Text -> [(LedgerAccountId, Int64)] -> SqlPersistT IO NewJournalEntry
entry occurredOn description entryLines =
  either (fail . show) pure $
    mkBalancedLines [EntryLine account (Cents amount) | (account, amount) <- entryLines]
      >>= mkNewJournalEntry occurredOn description

-- | Inserts an entry and its lines with raw SQL, skipping every Haskell check.
rawEntry :: Text -> [(LedgerAccountId, Int64)] -> SqlPersistT IO ()
rawEntry description entryLines = do
  [Single entryId] <-
    rawSql "INSERT INTO journal_entries (occurred_on, description) VALUES ('2026-01-01', ?) RETURNING id" [PersistText description]
  forM_ entryLines (rawLine (JournalEntryKey entryId))

rawLine :: JournalEntryId -> (LedgerAccountId, Int64) -> SqlPersistT IO ()
rawLine entryId (account, amount) =
  rawExecute
    "INSERT INTO journal_lines (entry_id, ledger_account_id, amount_cents) VALUES (?, ?, ?)"
    [PersistInt64 (fromSqlKey entryId), PersistInt64 (fromSqlKey account), PersistInt64 amount]

postEntry_ :: NewJournalEntry -> SqlPersistT IO ()
postEntry_ newEntry = () <$ postEntry newEntry

isRight :: Either a b -> Bool
isRight = either (const False) (const True)
