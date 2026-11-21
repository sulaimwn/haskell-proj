module Reckon.RulesSpec (spec) where

import Control.Monad (forM_, void)
import Data.Text (Text)
import Data.Text qualified as Text
import Database.Persist (Entity (..), getBy)
import Database.Persist.Sql (rawExecute)
import Reckon.App (AppEnv)
import Reckon.Database.Schema
import Reckon.Ledger (accountBalanceAsOf)
import Reckon.Money (Cents (..))
import Reckon.People (addPerson)
import Reckon.Rules
import Reckon.Rules.History
import Reckon.Rules.Language
import Reckon.ScenarioSupport
import Reckon.TestSupport
import Test.Hspec

-- | Text that appears only in this scenario's rows.
bistro :: Scenario -> Text
bistro scenario = "BISTRO EXAMPLE" <> scenario.tag

categoryFor :: Scenario -> Text
categoryFor scenario = "expense:bistro-" <> Text.toLower scenario.tag

friendNamed :: Scenario -> Text -> Text
friendNamed scenario name = name <> "-" <> Text.toLower scenario.tag

-- | The history rows that belong to this scenario.
historyOf :: AppEnv -> Scenario -> IO [HistoryRow]
historyOf env scenario = filter (\row -> scenario.tag `Text.isInfixOf` Text.toUpper row.description) <$> runTestDatabase env loadHistory

checked :: AppEnv -> Text -> IO Rule
checked env source = runTestDatabase env (checkRule source) >>= either (\problem -> fail (Text.unpack (renderProblem problem))) pure

spec :: Spec
spec = beforeAll makeTestEnv $ do
  describe "saving rules" $ do
    it "keeps a rule in its canonical form, creates its account, and recognizes the same rule written differently" $ \env -> do
      scenario <- newScenario env
      let source = "WHEN description  CONTAINS \"" <> bistro scenario <> "\" then Categorize " <> categoryFor scenario
      Right saved <- runTestDatabase env (addRule source 100)
      saved.ruleText `shouldBe` "when description contains \"" <> bistro scenario <> "\" then categorize " <> categoryFor scenario
      runTestDatabase env (addRule (Text.toLower source) 50) `shouldReturn` Left (RuleAlreadyExists saved.ruleText)
      stored <- runTestDatabase env loadStoredRules
      map (.ruleText) (filter (\rule -> rule.ruleId == saved.ruleId) stored) `shouldBe` [saved.ruleText]
      created <- runTestDatabase env (getBy (UniqueLedgerAccountName (categoryFor scenario)))
      fmap (ledgerAccountName . entityVal) created `shouldBe` Just (categoryFor scenario)

    it "refuses text that isn't a rule, saying where" $ \env -> do
      Left (InvalidRule problem) <- runTestDatabase env (addRule "when amount < 1.234 then categorize expense:x" 100)
      (problem.line, problem.column) `shouldBe` (1, 15)

    it "refuses a split with someone who hasn't been added, at their name" $ \env -> do
      scenario <- newScenario env
      let source = "when description contains \"X\" then split expense:food equally with " <> friendNamed scenario "nobody"
      Left (InvalidRule problem) <- runTestDatabase env (addRule source 100)
      problem.column `shouldBe` Text.length "when description contains \"X\" then split expense:food equally with " + 1
      Text.unpack problem.message `shouldContain` "isn't someone you've added"

    it "still takes the original TEXT ACCOUNT form" $ \env -> do
      scenario <- newScenario env
      Right saved <- runTestDatabase env (addContainsRule ("Corner " <> scenario.tag) ("EXPENSE:Corner-" <> scenario.tag) 100)
      saved.ruleText `shouldBe` "when description contains \"CORNER " <> scenario.tag <> "\" then categorize expense:corner-" <> Text.toLower scenario.tag
      runTestDatabase env (addContainsRule "   " "expense:x" 100) `shouldReturn` Left EmptyRuleText
      runTestDatabase env (addContainsRule "X" "food" 100) `shouldReturn` Left (UnknownAccountPrefix "food")

    it "deletes a rule, and says so when there is none" $ \env -> do
      scenario <- newScenario env
      Right saved <- runTestDatabase env (addContainsRule ("Delete " <> scenario.tag) "expense:gone" 100)
      runTestDatabase env (deleteRule saved.ruleId) `shouldReturn` Right ()
      runTestDatabase env (deleteRule saved.ruleId) `shouldReturn` Left RuleNotFound

    it "is refused by the database when Haskell is bypassed" $ \env -> do
      runTestDatabase env (rawExecute "INSERT INTO posting_rules (rule_text) VALUES ('   ')" [])
        `shouldFailMentioning` "posting_rules_rule_text_check"

    it "leaves a rule that no longer reads out of posting, and shows its problem" $ \env -> do
      runTestDatabase env (rawExecute "INSERT INTO posting_rules (rule_text) VALUES ('when the moon is full')" [])
      stored <- runTestDatabase env loadStoredRules
      let broken = [rule | rule <- stored, rule.ruleText == "when the moon is full"]
      map (either (const True) (const False) . (.parsed)) broken `shouldBe` [True]
      rules <- runTestDatabase env loadRules
      length rules `shouldSatisfy` (< length stored)
      forM_ broken $ \rule -> runTestDatabase env (deleteRule rule.ruleId) `shouldReturn` Right ()

  describe "posting with rules" $ do
    it "splits a payment as a rule says, in one entry" $ \env -> do
      scenario <- newScenario env
      runTestDatabase env $ do
        void (addPerson (friendNamed scenario "alex") ("ALEX EXAMPLE" <> scenario.tag))
        void (addPerson (friendNamed scenario "sam") ("SAM EXAMPLE" <> scenario.tag))
      void $
        runTestDatabase env $
          addRule
            ("when description contains \"" <> bistro scenario <> "\" and amount < 0 then split " <> categoryFor scenario <> " equally with " <> friendNamed scenario "alex" <> ", " <> friendNamed scenario "sam")
            100
      importCsv env scenario (inlineCsv [("2/3/2026", "TASTY " <> bistro scenario <> "X", "-90.01"), ("2/4/2026", "TASTY " <> bistro scenario <> "X", "4.00")])
      void (post env)
      [dinner, refund] <- allRowNumbers env scenario
      -- Odd cents go to me; each friend owes a third.
      entryLinesForRow env dinner
        `shouldReturn` [(categoryFor scenario, 3001), ("receivable:" <> friendNamed scenario "alex", 3000), ("receivable:" <> friendNamed scenario "sam", 3000)]
      -- Money coming in can't be split, so the rule passes it over.
      entryLinesForRow env refund `shouldReturn` [("income:uncategorized", -400)]

  describe "applying a rule to rows already posted" $ do
    it "previews, then moves only the rows it matches, without changing any balance on any date" $ \env -> do
      scenario <- newScenario env
      importCsv env scenario (inlineCsv [("2/3/2026", bistro scenario, "-30.01"), ("2/5/2026", bistro scenario, "-12.00"), ("2/6/2026", bistro scenario, "5.00"), ("2/7/2026", "CORNER EXAMPLE" <> scenario.tag, "-8.00")])
      void (post env)
      [first, second, _refund, shop] <- allRowNumbers env scenario
      account <- bankAccount env scenario.chequingLast4
      let balancesOn = traverse (\day -> runTestDatabase env (accountBalanceAsOf (bankAccountLedgerAccountId (entityVal account)) day)) [on scenario 2 d | d <- [1 .. 28]]
      balancesBefore <- balancesOn

      rule <- checked env ("when description contains \"" <> bistro scenario <> "\" and amount < 0 then categorize " <> categoryFor scenario)
      history <- historyOf env scenario
      -- Newest first; the refund (money in) and the other shop don't match.
      map (.effect) (previewRule rule history) `shouldBe` replicate 2 (WouldMoveFrom "expense:uncategorized")
      map (\preview -> preview.row.amount) (previewRule rule history) `shouldBe` [Cents (-1200), Cents (-3001)]

      outcome <- runTestDatabase env (applyRule rule)
      outcome `shouldBe` ApplyOutcome {moved = 2, refused = []}
      entryLinesForRow env first `shouldReturn` [(categoryFor scenario, 3001)]
      entryLinesForRow env second `shouldReturn` [(categoryFor scenario, 1200)]
      entryLinesForRow env shop `shouldReturn` [("expense:uncategorized", 800)]
      balancesAfter <- balancesOn
      balancesAfter `shouldBe` balancesBefore

      -- Nothing is left to move, so applying again changes nothing.
      historyAgain <- historyOf env scenario
      map (.effect) (previewRule rule historyAgain) `shouldBe` replicate 2 AlreadyThere
      runTestDatabase env (applyRule rule) `shouldReturn` ApplyOutcome {moved = 0, refused = []}

    it "says a row not posted yet will get the rule at the next post" $ \env -> do
      scenario <- newScenario env
      importCsv env scenario (inlineCsv [("2/3/2026", bistro scenario, "-30.01")])
      let source = "when description contains \"" <> bistro scenario <> "\" then categorize " <> categoryFor scenario
      rule <- checked env source
      history <- historyOf env scenario
      map (.effect) (previewRule rule history) `shouldBe` [AppliesWhenPosted]
      -- Saving the rule is what makes the next post use it.
      void (runTestDatabase env (addRule source 100))
      void (post env)
      [rowNumber] <- allRowNumbers env scenario
      entryLinesForRow env rowNumber `shouldReturn` [(categoryFor scenario, 3001)]

    it "can't split money coming in, and says so" $ \env -> do
      scenario <- newScenario env
      runTestDatabase env (void (addPerson (friendNamed scenario "alex") ("ALEX EXAMPLE" <> scenario.tag)))
      importCsv env scenario (inlineCsv [("2/3/2026", bistro scenario, "40.00")])
      void (post env)
      rule <- checked env ("when description contains \"" <> bistro scenario <> "\" then split expense:food equally with " <> friendNamed scenario "alex")
      history <- historyOf env scenario
      map (.effect) (previewRule rule history) `shouldBe` [CannotChange "only money going out can be split"]
      runTestDatabase env (applyRule rule) `shouldReturn` ApplyOutcome {moved = 0, refused = []}
