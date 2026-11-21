module Reckon.ChecksSpec (spec) where

import Data.List (sortOn)
import Data.Text qualified as Text
import Data.Time (Day, diffDays, fromGregorian, gregorianMonthLength, toGregorian)
import Hedgehog (Gen, forAll, (===))
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import Reckon.Checks
import Test.Hspec
import Test.Hspec.Hedgehog (hedgehog)

day :: Integer -> Int -> Int -> Day
day = fromGregorian

account :: Maybe Day -> [Day] -> AccountFacts
account firstTransaction statementDates = AccountFacts {last4 = "1234", nickname = "RBC Chequing ending 1234", firstTransaction, statementDates}

spec :: Spec
spec = do
  describe "statements" $ do
    it "wants a statement balance for every month that has ended, since the first transaction" $
      missingStatementMonths (day 2026 6 20) (account (Just (day 2026 2 14)) [])
        `shouldBe` [(2026, 2), (2026, 3), (2026, 4), (2026, 5)]

    it "gives a month a few days' grace after it ends, and never counts the current month" $ do
      let facts = account (Just (day 2026 3 1)) []
      missingStatementMonths (day 2026 4 5) facts `shouldBe` []
      missingStatementMonths (day 2026 4 6) facts `shouldBe` [(2026, 3)]
      missingStatementMonths (day 2026 4 30) facts `shouldBe` [(2026, 3)]

    it "counts a statement balance recorded for any date in the month" $
      missingStatementMonths (day 2026 6 20) (account (Just (day 2026 2 14)) [day 2026 3 31, day 2026 5 2])
        `shouldBe` [(2026, 2), (2026, 4)]

    it "has nothing to say about an account with no transactions" $
      missingStatementMonths (day 2030 1 1) (account Nothing []) `shouldBe` []

    it "makes one reminder per account, naming the latest months first" $ do
      [reminder] <- pure (statementReminders (day 2026 8 20) [account (Just (day 2026 2 14)) []])
      (reminder.kind, reminder.subject) `shouldBe` (StatementMissing, "1234")
      Text.unpack reminder.message `shouldContain` "July 2026, June 2026, May 2026 and 3 earlier on RBC Chequing ending 1234"
      statementReminders (day 2026 8 20) [account (Just (day 2026 2 14)) [day 2026 2 28, day 2026 3 31, day 2026 4 30, day 2026 5 31, day 2026 6 30, day 2026 7 31]] `shouldBe` []

  describe "screenshots nobody confirmed" $ do
    let row last4 readOn = ProvisionalFacts {last4, nickname = "RBC Chequing ending " <> last4, readOn}

    it "waits a week for the bank's export before saying anything" $ do
      staleProvisionalReminders (day 2026 2 26) [row "1234" (day 2026 2 20)] `shouldBe` []
      map (.subject) (staleProvisionalReminders (day 2026 2 27) [row "1234" (day 2026 2 20)]) `shouldBe` ["1234"]

    it "counts the rows per account and says how long the oldest has waited" $ do
      let reminders = staleProvisionalReminders (day 2026 3 10) [row "1234" (day 2026 2 20), row "1234" (day 2026 3 1), row "5678" (day 2026 3 9)]
      map (.subject) reminders `shouldBe` ["1234"]
      case reminders of
        [reminder] -> Text.unpack reminder.message `shouldContain` "2 rows read from screenshots on RBC Chequing ending 1234 (the oldest 18 days ago) still have no matching row"
        other -> expectationFailure ("expected one reminder, got " <> show other)

  describe "due dates" $ do
    it "finds the next day, today included, that falls on the day of the month" $ do
      nextDueDate (day 2026 3 10) 15 `shouldBe` day 2026 3 15
      nextDueDate (day 2026 3 15) 15 `shouldBe` day 2026 3 15
      nextDueDate (day 2026 3 16) 15 `shouldBe` day 2026 4 15
      nextDueDate (day 2026 12 20) 5 `shouldBe` day 2027 1 5

    it "uses the last day of a month that is too short" $ do
      nextDueDate (day 2026 2 1) 31 `shouldBe` day 2026 2 28
      nextDueDate (day 2028 2 1) 31 `shouldBe` day 2028 2 29
      nextDueDate (day 2026 4 5) 31 `shouldBe` day 2026 4 30
      nextDueDate (day 2026 4 30) 31 `shouldBe` day 2026 4 30
      nextDueDate (day 2026 5 1) 31 `shouldBe` day 2026 5 31

    it "is never in the past and never more than a month ahead, and falls on the right day (property)" $ hedgehog $ do
      today <- forAll genDay
      dayOfMonth <- forAll (Gen.int (Range.linear 1 31))
      let due = nextDueDate today dayOfMonth
          (year, month, dueDay) = toGregorian due
      (due >= today) === True
      (diffDays due today <= 31) === True
      dueDay === min dayOfMonth (gregorianMonthLength year month)

    it "only reminds within the warning window, saying when" $ do
      let visa = DueDateFacts {dueDateId = 7, label = "Visa payment", dayOfMonth = 15, warnDays = 5}
      dueDateReminders (day 2026 3 9) [visa] `shouldBe` []
      map (.message) (dueDateReminders (day 2026 3 10) [visa]) `shouldBe` ["Visa payment is due in 5 days (2026-03-15)."]
      map (.message) (dueDateReminders (day 2026 3 14) [visa]) `shouldBe` ["Visa payment is due tomorrow (2026-03-15)."]
      map (.message) (dueDateReminders (day 2026 3 15) [visa]) `shouldBe` ["Visa payment is due today (2026-03-15)."]
      -- The day after, it's next month's and out of the window.
      dueDateReminders (day 2026 3 16) [visa] `shouldBe` []

    it "gives each month's reminder its own subject, so last month's resolves by itself" $ do
      let visa = DueDateFacts {dueDateId = 7, label = "Visa payment", dayOfMonth = 15, warnDays = 5}
      map (.subject) (dueDateReminders (day 2026 3 12) [visa]) `shouldBe` ["7:2026-03-15"]
      map (.subject) (dueDateReminders (day 2026 4 12) [visa]) `shouldBe` ["7:2026-04-15"]

  describe "keeping stored reminders in step with the checks" $ do
    let reminder kind subject message = Reminder {kind, subject, message}
        stored reminderId kind subject message = OpenReminder {reminderId, kind, subject, message}

    it "opens what is new, refreshes what changed, resolves what is no longer true, and leaves the rest" $ do
      let reported = [reminder DueSoon "7:2026-03-15" "in 4 days", reminder StatementMissing "1234" "same", reminder ProvisionalStale "5678" "new"]
          open = [stored 1 DueSoon "7:2026-03-15" "in 5 days", stored 2 StatementMissing "1234" "same", stored 3 DueSoon "9:2026-02-15" "gone"]
      planReminders reported open
        `shouldBe` ReminderPlan {toOpen = [reminder ProvisionalStale "5678" "new"], toRefresh = [(1, "in 4 days")], toResolve = [3]}

    it "treats the same subject under another kind as a different reminder" $
      (planReminders [reminder StatementMissing "1234" "m"] [stored 1 ProvisionalStale "1234" "m"]).toResolve `shouldBe` [1]

    it "leaves nothing to do when the checks agree with what is stored (property)" $ hedgehog $ do
      reported <- forAll genReminders
      let open = [stored (fromIntegral index) r.kind r.subject r.message | (index, r) <- zip [1 :: Int ..] reported]
      planReminders reported open === ReminderPlan {toOpen = [], toRefresh = [], toResolve = []}

    it "accounts for every reminder exactly once (property)" $ hedgehog $ do
      reported <- forAll genReminders
      stale <- forAll genReminders
      let open = [stored (fromIntegral index) r.kind r.subject r.message | (index, r) <- zip [1 :: Int ..] stale]
          plan = planReminders reported open
          keyOf r = (r.kind, r.subject)
      -- Everything reported is either opened or already open.
      sortOn keyOf (plan.toOpen <> [r | r <- reported, keyOf r `elem` map (\o -> (o.kind, o.subject)) open]) === sortOn keyOf reported
      -- Everything stored is either still reported or resolved.
      length plan.toResolve + length [o | o <- open, (o.kind, o.subject) `elem` map keyOf reported] === length open

  describe "all the checks" $
    it "run together on one snapshot" $ do
      let snapshot =
            Snapshot
              { today = day 2026 3 12
              , accounts = [account (Just (day 2026 1 5)) [day 2026 1 31]]
              , provisional = [ProvisionalFacts {last4 = "1234", nickname = "RBC", readOn = day 2026 3 1}]
              , dueDates = [DueDateFacts {dueDateId = 1, label = "Rent", dayOfMonth = 15, warnDays = 5}]
              }
      map (.kind) (runChecks snapshot) `shouldBe` [StatementMissing, ProvisionalStale, DueSoon]

-- * Generators

genDay :: Gen Day
genDay = fromGregorian <$> Gen.integral (Range.linear 2020 2035) <*> Gen.int (Range.linear 1 12) <*> Gen.int (Range.linear 1 28)

genReminders :: Gen [Reminder]
genReminders = do
  reminders <- Gen.list (Range.linear 0 8) (Reminder <$> Gen.enumBounded <*> genSubject <*> genMessage)
  -- One open reminder per (kind, subject).
  pure (dedupe reminders)
  where
    genSubject = Gen.element ["1234", "5678", "7:2026-03-15", "9:2026-04-15"]
    genMessage = Gen.element ["a", "b", "c"]
    dedupe = foldr (\r kept -> r : filter (\k -> (k.kind, k.subject) /= (r.kind, r.subject)) kept) []
