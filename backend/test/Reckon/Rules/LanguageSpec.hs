module Reckon.Rules.LanguageSpec (spec) where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Hedgehog (Gen, forAll, (===))
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import Reckon.Bank (BankAccountKind (..))
import Reckon.Import.Dedupe (normalizeDescription)
import Reckon.Money (Cents (..))
import Reckon.Rules.Eval
import Reckon.Rules.Language
import Test.Hspec
import Test.Hspec.Hedgehog (hedgehog)

-- | The problem a text has, or a failure if it parses.
problemOf :: Text -> IO RuleProblem
problemOf source = case parseRule source of
  Left problem -> pure problem
  Right rule -> expectationFailure ("expected a problem, but it parsed: " <> show rule) >> fail "parsed"

spec :: Spec
spec = do
  describe "reading rules" $ do
    it "reads a plain categorization" $
      parseRule "when description contains \"TIM HORTONS\" then categorize expense:coffee"
        `shouldBe` Right Rule {conditions = DescriptionContains "TIM HORTONS" :| [], action = Categorize "expense:coffee"}

    it "reads several conditions and every comparison" $
      parseRule "when description starts with \"UBER\" and amount <= -50.00 and amount != -75 and account is credit card then categorize expense:transport"
        `shouldBe` Right
          Rule
            { conditions = DescriptionStartsWith "UBER" :| [AmountIs AtMost (Cents (-5000)), AmountIs NotEqualTo (Cents (-7500)), AccountIs CreditCard]
            , action = Categorize "expense:transport"
            }

    it "reads a split, with names and accounts lower-cased" $
      parseRule "WHEN Description ENDS WITH \"bistro\" THEN Split Expense:Food EQUALLY WITH Alex, SAM"
        `shouldBe` Right Rule {conditions = DescriptionEndsWith "BISTRO" :| [], action = SplitEqually "expense:food" ("alex" :| ["sam"])}

    it "doesn't mind line breaks and extra spaces between words" $
      parseRule "when   description contains \"A\"\n   and amount > 0\n then   categorize income:job\n"
        `shouldBe` Right Rule {conditions = DescriptionContains "A" :| [AmountIs GreaterThan mempty], action = Categorize "income:job"}

    it "reads amounts with a dollar sign, commas and one decimal" $
      fmap (.conditions) (parseRule "when amount >= $1,234.5 then categorize income:job")
        `shouldBe` Right (AmountIs AtLeast (Cents 123450) :| [])

    it "keeps description text in the form descriptions are compared in, so case and spacing never make two rules differ" $
      fmap (.conditions) (parseRule "when description contains \"  tim    Hortons \" then categorize expense:coffee")
        `shouldBe` Right (DescriptionContains "TIM HORTONS" :| [])

    it "reads escaped quotes and backslashes in text" $
      fmap (.conditions) (parseRule "when description contains \"7\\\" PIZZA \\\\ CO\" then categorize expense:food")
        `shouldBe` Right (DescriptionContains "7\" PIZZA \\ CO" :| [])

  describe "saying what is wrong, and where" $ do
    it "points at the start of an empty rule" $ do
      problem <- problemOf ""
      (problem.line, problem.column) `shouldBe` (1, 1)
      Text.unpack problem.message `shouldContain` "when"

    it "points at the word that isn't a comparison between description and text" $ do
      problem <- problemOf "when description contain \"X\" then categorize expense:food"
      (problem.line, problem.column) `shouldBe` (1, 18)
      Text.unpack problem.message `shouldContain` "contains"

    it "refuses an amount with more than two decimals instead of rounding it" $ do
      problem <- problemOf "when amount < 1.234 then categorize expense:food"
      (problem.line, problem.column) `shouldBe` (1, 15)
      Text.unpack problem.message `shouldContain` "at most two decimals"

    it "refuses an account name with no known type" $ do
      problem <- problemOf "when amount < 0 then categorize food"
      (problem.line, problem.column) `shouldBe` (1, 33)
      Text.unpack problem.message `shouldContain` "expense:food"

    it "only splits into an expense account" $ do
      problem <- problemOf "when amount < 0 then split income:job equally with alex"
      Text.unpack problem.message `shouldContain` "expense account"

    it "refuses a friend named twice, at the second mention" $ do
      problem <- problemOf "when amount < 0 then split expense:food equally with alex, sam, alex"
      (problem.line, problem.column) `shouldBe` (1, 65)
      problem.message `shouldBe` "alex is listed twice"

    it "refuses empty quoted text" $ do
      problem <- problemOf "when description contains \"  \" then categorize expense:food"
      problem.message `shouldBe` "the quoted text can't be empty"

    it "says where anything left over starts" $ do
      problem <- problemOf "when amount < 0 then categorize expense:food and more"
      (problem.line, problem.column) `shouldBe` (1, 46)

    it "counts lines" $ do
      problem <- problemOf "when amount < 0\nthen categorize food"
      problem.line `shouldBe` 2

    it "finds a word after the fact, for problems only the database knows" $ do
      problemAt "sam" "when amount < 0\n  then split expense:food equally with alex, SAM" "x"
        `shouldBe` RuleProblem {line = 2, column = 46, message = "x"}
      problemAt "nobody" "when amount < 0 then categorize expense:food" "x"
        `shouldBe` RuleProblem {line = 1, column = 1, message = "x"}

  describe "rendering rules" $ do
    it "writes a rule the way it is read back, in one canonical form" $ do
      fmap renderRule (parseRule "WHEN  amount <  -5 AND account is CHEQUING then CATEGORIZE Expense:Fees")
        `shouldBe` Right "when amount < -5.00 and account is chequing then categorize expense:fees"

    it "gives the same rule back for any rule (property)" $ hedgehog $ do
      rule <- forAll genRule
      parseRule (renderRule rule) === Right rule

  describe "applying rules to a row" $ do
    let candidate description amount kind = Candidate {description, amount = Cents amount, kind}
        holdsFor text row = case parseRule text of
          Right rule -> matches rule row
          Left problem -> error (show problem)

    it "ignores case and runs of spaces in descriptions and in the rule" $ do
      let row = candidate "interac   purchase - Tim Hortons #12" (-250) Chequing
      holdsFor "when description contains \"TIM  hortons\" then categorize expense:coffee" row `shouldBe` True
      holdsFor "when description contains \"hortons tim\" then categorize expense:coffee" row `shouldBe` False

    it "tests the start and the end of the description" $ do
      let row = candidate "PAYROLL DEPOSIT EXAMPLE EMPLOYER" 150000 Chequing
      holdsFor "when description starts with \"payroll\" then categorize income:job" row `shouldBe` True
      holdsFor "when description starts with \"deposit\" then categorize income:job" row `shouldBe` False
      holdsFor "when description ends with \"employer\" then categorize income:job" row `shouldBe` True

    it "compares amounts as the bank shows them, with money out negative" $ do
      let row = candidate "X" (-5000) Chequing
      holdsFor "when amount < 0 then categorize expense:a" row `shouldBe` True
      holdsFor "when amount <= -50 then categorize expense:a" row `shouldBe` True
      holdsFor "when amount < -50 then categorize expense:a" row `shouldBe` False
      holdsFor "when amount = -50.00 then categorize expense:a" row `shouldBe` True
      holdsFor "when amount != -50 then categorize expense:a" row `shouldBe` False
      holdsFor "when amount > -50.01 then categorize expense:a" row `shouldBe` True

    it "needs every condition, including the kind of account" $ do
      let row = candidate "UBER TRIP" (-1200) CreditCard
      holdsFor "when description contains \"uber\" and account is credit card then categorize expense:transport" row `shouldBe` True
      holdsFor "when description contains \"uber\" and account is chequing then categorize expense:transport" row `shouldBe` False
      holdsFor "when description contains \"uber\" and amount < -50 then categorize expense:transport" row `shouldBe` False

-- * Generators

genRule :: Gen Rule
genRule = do
  conditions <- Gen.nonEmpty (Range.linear 1 4) genCondition
  Rule conditions <$> genAction

-- | Description text with the characters that need escaping, spaces, and some
-- non-ASCII, and always something visible (blank text is refused).
genText :: Gen Text
genText = do
  visible <- Gen.element (['a' .. 'z'] <> ['0' .. '9'] <> "\"\\é")
  rest <- Gen.text (Range.linear 0 12) (Gen.element (['a' .. 'z'] <> ['0' .. '9'] <> " \"\\#-é"))
  -- Rules keep description text the way descriptions are compared.
  pure (normalizeDescription (Text.singleton visible <> rest))

genCondition :: Gen Condition
genCondition =
  Gen.choice
    [ DescriptionContains <$> genText
    , DescriptionStartsWith <$> genText
    , DescriptionEndsWith <$> genText
    , AmountIs <$> Gen.enumBounded <*> (Cents <$> Gen.int64 (Range.linearFrom 0 (-1_000_000_000_000) 1_000_000_000_000))
    , AccountIs <$> Gen.element [Chequing, Savings, CreditCard]
    ]

genAction :: Gen Action
genAction =
  Gen.choice
    [ Categorize <$> genAccountName ["expense", "income", "asset", "liability", "equity", "receivable"]
    , do
        category <- genAccountName ["expense"]
        friends <- Gen.nonEmpty (Range.linear 1 4) (Gen.text (Range.linear 1 8) (Gen.element (['a' .. 'z'] <> ['0' .. '9'] <> "-_")))
        -- A friend can only be listed once.
        pure (SplitEqually category (uniqueBy friends))
    ]
  where
    uniqueBy (first :| rest) = first :| filter (/= first) (dedupe rest)
    dedupe = foldr (\item kept -> item : filter (/= item) kept) []

genAccountName :: [Text] -> Gen Text
genAccountName prefixes = do
  prefix <- Gen.element prefixes
  rest <- Gen.text (Range.linear 1 10) (Gen.element (['a' .. 'z'] <> ['0' .. '9'] <> "-_"))
  pure (prefix <> ":" <> rest)
