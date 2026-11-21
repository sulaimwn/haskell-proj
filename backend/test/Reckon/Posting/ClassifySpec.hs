module Reckon.Posting.ClassifySpec (spec) where

import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List (sort, sortOn)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Time (Day, fromGregorian)
import Hedgehog (Gen, forAll, (===))
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import Reckon.Bank (BankAccountKind (..))
import Reckon.Money (Cents (..), sumCents)
import Reckon.Posting.Classify
import Reckon.Rules.Language (Comparison (..), Condition (..))
import Test.Hspec
import Test.Hspec.Hedgehog (hedgehog)

-- Accounts are plain Text in these tests: the planner doesn't care what
-- identifies them.
wellKnown :: WellKnownAccounts Text
wellKnown =
  WellKnownAccounts
    { clearing = "asset:clearing"
    , untrackedCards = "liability:untracked-cards"
    , uncategorizedExpense = "expense:uncategorized"
    , uncategorizedIncome = "income:uncategorized"
    }

spec :: Spec
spec = do
  describe "single rows" $ do
    it "uses the first matching rule, in priority order" $ do
      let rules = [containsRule "TIM HORTONS" "expense:coffee", containsRule "TIM" "expense:other"]
          plan = planPosting wellKnown rules [] [chequing 1 (day 3) "Interac purchase" "Tim Hortons #12" (-250)]
      map (.counterAccount) plan.postings `shouldBe` ["expense:coffee"]

    it "sends a payment to an untracked card to liability:untracked-cards, not spending" $ do
      let plan = planPosting wellKnown [] [] [chequing 1 (day 3) "Online Banking payment - 4321" "AMEX CREDIT CARD" (-12000)]
      map (.classification) plan.postings `shouldBe` [UntrackedCardPayment]
      map (.counterAccount) plan.postings `shouldBe` ["liability:untracked-cards"]

    it "lets a rule override the card-payment guess" $ do
      let plan = planPosting wellKnown [containsRule "AMEX" "expense:gifts"] [] [chequing 1 (day 3) "Online Banking payment" "AMEX CREDIT CARD" (-12000)]
      map (.counterAccount) plan.postings `shouldBe` ["expense:gifts"]

    it "falls back to uncategorized expense or income by sign" $ do
      let plan = planPosting wellKnown [] [] [chequing 1 (day 3) "Interac purchase" "SHOP" (-999), chequing 2 (day 4) "Deposit" "" 5000]
      map (.counterAccount) plan.postings `shouldBe` ["expense:uncategorized", "income:uncategorized"]

    it "leaves a zero-amount row for review" $
      (planPosting wellKnown [] [] [chequing 1 (day 3) "Fee waived" "" 0]).leftForReview
        `shouldBe` [(chequing 1 (day 3) "Fee waived" "" 0, ZeroAmount)]

  describe "rules in the rule language" $ do
    let dinner = chequing 1 (day 3) "Interac purchase" "TASTY BISTRO" (-9001)
        splitRule = Rule {label = "split dinner", conditions = DescriptionContains "BISTRO" :| [], outcome = SplitWith "expense:food" ("alex" :| ["sam"])}

    it "applies a rule only when every condition holds" $ do
      let rule = Rule {label = "big uber", conditions = DescriptionContains "UBER" :| [AmountIs LessThan (Cents (-5000))], outcome = ToAccount "expense:travel"}
          small = chequing 1 (day 3) "UBER TRIP" "" (-1200)
          big = chequing 2 (day 4) "UBER TRIP" "" (-8000)
          plan = planPosting wellKnown [rule] [] [small, big]
      sortOn fst [(posting.row.rowId, posting.counterAccount) | posting <- plan.postings]
        `shouldBe` [(1, "expense:uncategorized"), (2, "expense:travel")]

    it "splits a payment as the rule says: my share to the category, the rest to what friends owe" $ do
      let plan = planPosting wellKnown [splitRule] alexAndSam [dinner]
      [posting.classification | posting <- plan.postings]
        `shouldBe` [SplitByRule "split dinner" [("expense:food", Cents 3001), ("receivable:alex", Cents 3000), ("receivable:sam", Cents 3000)]]

    it "splits so that the parts add up to the payment exactly, odd cents to me first" $ hedgehog $ do
      -- Three ways, so at least 3 cents: everyone gets one.
      cents <- forAll (Gen.int64 (Range.linear 3 100_000))
      let plan = planPosting wellKnown [splitRule] alexAndSam [chequing 1 (day 3) "TASTY BISTRO" "" (negate cents)]
      case [parts | PlannedPosting {classification = SplitByRule _ parts} <- plan.postings] of
        [parts] -> sumCents (map snd parts) === Cents cents
        other -> fail ("expected one split posting, got " <> show other)

    it "passes over a split too small to give every friend a cent" $ do
      let plan = planPosting wellKnown [splitRule] alexAndSam [chequing 1 (day 3) "TASTY BISTRO" "" (-2)]
      map (.classification) plan.postings `shouldBe` [Uncategorized]

    it "passes over a split of money coming in and lets the next rule or the guess decide" $ do
      let refund = chequing 1 (day 3) "REFUND" "TASTY BISTRO" 4000
          plan = planPosting wellKnown [splitRule] alexAndSam [refund]
      map (.classification) plan.postings `shouldBe` [Uncategorized]

    it "passes over a split with someone who isn't known" $ do
      let plan = planPosting wellKnown [splitRule] [alex] [dinner]
      map (.classification) plan.postings `shouldBe` [Uncategorized]

    it "falls through to a later rule when an earlier split can't apply" $ do
      let plan = planPosting wellKnown [splitRule, containsRule "BISTRO" "expense:restaurants"] [alex] [dinner]
      map (.counterAccount) plan.postings `shouldBe` ["expense:restaurants"]

  describe "transfers between my accounts" $ do
    it "pairs opposite amounts in two accounts within 5 days, both via clearing" $ do
      let payment = chequing 1 (day 3) "Online Banking payment - 9876" "RBC VISA" (-50000)
          received = visa 2 (day 5) "PAYMENT - THANK YOU" "" 50000
          plan = planPosting wellKnown [] [] [payment, received]
      sortOn fst [(posting.row.rowId, posting.classification) | posting <- plan.postings]
        `shouldBe` [(1, TransferWith 2), (2, TransferWith 1)]
      map (.counterAccount) plan.postings `shouldBe` ["asset:clearing", "asset:clearing"]

    it "doesn't pair rows more than 5 days apart" $ do
      let plan = planPosting wellKnown [] [] [chequing 1 (day 3) "Payment" "" (-50000), visa 2 (day 9) "PAYMENT" "" 50000]
      map (.classification) plan.postings `shouldBe` [Uncategorized, Uncategorized]

    it "leaves every row of an ambiguous transfer for review instead of guessing" $ do
      let rows = [chequing 1 (day 14) "Transfer" "" (-20000), visa 2 (day 15) "PAYMENT" "" 20000, visa 3 (day 16) "RETURN - BOOKSHOP" "" 20000]
          plan = planPosting wellKnown [] [] rows
      plan.postings `shouldBe` []
      sort (map (\(row, _) -> row.rowId) plan.leftForReview) `shouldBe` [1, 2, 3]

    it "re-posts an earlier uncategorized row when its other half arrives later" $ do
      let earlier = (chequing 1 (day 3) "Payment" "" (-30000)) {alreadyPosted = True}
          arriving = visa 2 (day 4) "PAYMENT" "" 30000
          plan = planPosting wellKnown [] [] [earlier, arriving]
      sort [(posting.row.rowId, posting.replacesExistingEntry) | posting <- plan.postings] `shouldBe` [(1, True), (2, False)]

    it "never re-posts two already-posted rows on their own" $ do
      let first = (chequing 1 (day 3) "Payment" "" (-30000)) {alreadyPosted = True}
          second = (visa 2 (day 4) "PAYMENT" "" 30000) {alreadyPosted = True}
      planPosting wellKnown [] [] [first, second] `shouldBe` PostingPlan [] []

  describe "cancelled and refunded pairs" $
    it "pairs a sent e-Transfer with its cancellation in the same account" $ do
      let sent = chequing 1 (day 4) "e-Transfer sent" "ALEX EXAMPLE" (-3000)
          cancelled = chequing 2 (day 6) "e-Transfer cancelled" "ALEX EXAMPLE" 3000
          plan = planPosting wellKnown [] [] [sent, cancelled]
      sortOn fst [(posting.row.rowId, posting.classification) | posting <- plan.postings]
        `shouldBe` [(1, CancelledPairWith 2), (2, CancelledPairWith 1)]

  describe "repayments from people I share expenses with" $ do
    let deposit = chequing 1 (day 6) "e-Transfer received" "ALEX EXAMPLE" 3000

    it "leaves money in from a known person for review instead of calling it income" $ do
      let plan = planPosting wellKnown [] alexAndSam [deposit]
      plan.postings `shouldBe` []
      map snd plan.leftForReview `shouldBe` [PossibleRepayment ["alex"]]

    it "names every person the description could be" $ do
      let plan = planPosting wellKnown [] [alex, KnownPerson "alexander" "ALEX EXAMPLE" "receivable:alexander"] [deposit]
      map snd plan.leftForReview `shouldBe` [PossibleRepayment ["alex", "alexander"]]

    it "lets a rule override the repayment suggestion" $ do
      let plan = planPosting wellKnown [containsRule "ALEX" "income:other"] alexAndSam [deposit]
      map (.counterAccount) plan.postings `shouldBe` ["income:other"]

    it "only suggests repayments for money coming in" $ do
      let sent = chequing 1 (day 6) "e-Transfer sent" "ALEX EXAMPLE" (-3000)
      map (.counterAccount) (planPosting wellKnown [] alexAndSam [sent]).postings `shouldBe` ["expense:uncategorized"]

    it "doesn't treat a credit on a credit card as a repayment" $ do
      let credit = visa 1 (day 6) "REFUND" "ALEX EXAMPLE" 3000
      map (.counterAccount) (planPosting wellKnown [] alexAndSam [credit]).postings `shouldBe` ["income:uncategorized"]

  describe "any mix of rows (property)" $ do
    it "posts each new row exactly once or leaves it for review, and pairs always net to zero" $ hedgehog $ do
      rows <- forAll genRows
      let plan = planPosting wellKnown [containsRule "GROCERY" "expense:groceries"] [alex] rows
          newRows = sort [row.rowId | row <- rows, not row.alreadyPosted]
          handled = sort (map (.row.rowId) (filter (not . (.replacesExistingEntry)) plan.postings) <> map (\(row, _) -> row.rowId) plan.leftForReview)
      -- Every new row is either posted or waiting for review, exactly once.
      handled === newRows
      -- Already-posted rows only come back as the re-posted half of a pair.
      [posting.row.rowId | posting <- plan.postings, posting.row.alreadyPosted, not (isPair posting.classification)] === []
      -- Pairs are mutual: if A is paired with B, B is paired with A.
      let partners = Map.fromList [(posting.row.rowId, partnerOf posting.classification) | posting <- plan.postings]
      [ rowId | (rowId, Just partner) <- Map.toList partners, Map.lookup partner partners /= Just (Just rowId)] === []
      -- So everything sent through the clearing account nets to zero.
      sumCents [posting.row.amount | posting <- plan.postings, posting.counterAccount == wellKnown.clearing] === Cents 0

-- * Generators and helpers

alex :: KnownPerson Text
alex = KnownPerson "alex" "ALEX" "receivable:alex"

alexAndSam :: [KnownPerson Text]
alexAndSam = [alex, KnownPerson "sam" "SAM" "receivable:sam"]

genRows :: Gen [EvidenceRow Int Text]
genRows = do
  count <- Gen.int (Range.linear 0 25)
  mapM genRow [1 .. count]
  where
    genRow rowId = do
      account <- Gen.element [("chequing", Chequing), ("visa", CreditCard)]
      date <- day <$> Gen.int (Range.constant 1 28)
      (description1, description2) <-
        Gen.element
          [ ("Interac purchase", "GROCERY")
          , ("e-Transfer sent", "ALEX")
          , ("e-Transfer cancelled", "ALEX")
          , ("PAYMENT - THANK YOU", "")
          , ("Online Banking payment", "AMEX CREDIT CARD")
          , ("Deposit", "")
          ]
      amount <- Gen.element [-5000, 5000, -2000, 2000, 0, -1234]
      alreadyPosted <- Gen.frequency [(4, pure False), (1, pure True)]
      pure
        EvidenceRow
          { rowId
          , bankAccount = fst account
          , bankAccountKind = snd account
          , transactionDate = date
          , description1
          , description2
          , amount = Cents amount
          , alreadyPosted
          }

isPair :: Classification rowId account -> Bool
isPair = \case
  TransferWith _ -> True
  CancelledPairWith _ -> True
  _ -> False

partnerOf :: Classification rowId account -> Maybe rowId
partnerOf = \case
  TransferWith partner -> Just partner
  CancelledPairWith partner -> Just partner
  _ -> Nothing

chequing :: Int -> Day -> Text -> Text -> Int64 -> EvidenceRow Int Text
chequing rowId date description1 description2 amount =
  EvidenceRow {rowId, bankAccount = "chequing", bankAccountKind = Chequing, transactionDate = date, description1, description2, amount = Cents amount, alreadyPosted = False}

visa :: Int -> Day -> Text -> Text -> Int64 -> EvidenceRow Int Text
visa rowId date description1 description2 amount =
  EvidenceRow {rowId, bankAccount = "visa", bankAccountKind = CreditCard, transactionDate = date, description1, description2, amount = Cents amount, alreadyPosted = False}

day :: Int -> Day
day = fromGregorian 2026 2
