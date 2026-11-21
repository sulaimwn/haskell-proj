-- | Storing the rules, and turning them into what the planner uses
-- (Phase 7, DECISIONS D067).
--
-- A rule is one line of the rule language ("Reckon.Rules.Language"). The
-- database holds the text, exactly as the parser writes it back, so the
-- same rule can't be saved twice in different spacing. Everything that reads
-- rules parses that text again: there is no second, structured copy to
-- drift out of step with it.
--
-- Checking a rule is two steps: the parser (pure) rejects text that isn't a
-- rule, and 'checkRule' then asks the database whether the friends it names
-- exist, reporting problems at the word that caused them.
module Reckon.Rules
  ( StoredRule (..)
  , RuleError (..)
  , checkRule
  , addRule
  , addContainsRule
  , deleteRule
  , loadStoredRules
  , loadRules
  ) where

import Control.Monad.IO.Class (MonadIO)
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Maybe (isNothing, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Database.Persist (Entity (..), delete, get, getBy, insert, selectList)
import Database.Persist.Sql (SqlPersistT, fromSqlKey, toSqlKey)
import Database.Persist.Types (SelectOpt (..))
import Reckon.Database.Schema
import Reckon.Ledger (accountTypeFromName, findOrCreateLedgerAccount)
import Reckon.People (findPersonByName)
import Reckon.Posting.Classify qualified as Classify
import Reckon.Rules.Language

-- | A rule as saved: its text, and what the text means today.
data StoredRule = StoredRule
  { ruleId :: Int64
  , ruleText :: Text
  , priority :: Int
  , parsed :: Either RuleProblem Rule
  -- ^ 'Left' only if the language changed since the rule was saved.
  }
  deriving stock (Show, Eq)

data RuleError
  = InvalidRule RuleProblem
  | RuleAlreadyExists Text
  | RuleNotFound
  | -- | For 'addContainsRule', the older two-part form.
    UnknownAccountPrefix Text
  | EmptyRuleText
  deriving stock (Show, Eq)

-- | The rule the text says, if it is one and every friend in it is someone
-- added with @add-person@.
checkRule :: (MonadIO m) => Text -> SqlPersistT m (Either RuleProblem Rule)
checkRule source = case parseRule source of
  Left problem -> pure (Left problem)
  Right rule -> do
    known <- traverse (\name -> (name,) <$> findPersonByName name) (ruleFriends rule)
    pure $ case [name | (name, Nothing) <- known] of
      unknown : _ -> Left (problemAt unknown source (unknown <> " isn't someone you've added (see add-person)"))
      [] -> Right rule

-- | Saves a rule, after checking it. The category account is created if it
-- doesn't exist yet (its type comes from its prefix). Posted entries are
-- not changed: the rule applies to rows posted from now on, and
-- "Reckon.Rules.History" previews and applies it to earlier ones.
addRule :: (MonadIO m) => Text -> Int -> SqlPersistT m (Either RuleError StoredRule)
addRule source priority = do
  checked <- checkRule source
  case checked of
    Left problem -> pure (Left (InvalidRule problem))
    Right rule -> do
      let canonical = renderRule rule
      existing <- getBy (UniquePostingRule canonical)
      case (existing, accountTypeFromName (ruleCategory rule)) of
        (Just _, _) -> pure (Left (RuleAlreadyExists canonical))
        -- The parser only accepts known prefixes, so this can't happen.
        (_, Nothing) -> pure (Left (UnknownAccountPrefix (ruleCategory rule)))
        (Nothing, Just accountType) -> do
          _ <- findOrCreateLedgerAccount (ruleCategory rule) accountType
          key <- insert PostingRule {postingRuleRuleText = canonical, postingRulePriority = priority}
          pure (Right StoredRule {ruleId = fromSqlKey key, ruleText = canonical, priority, parsed = Right rule})

-- | The original form of a rule, kept for the command line and for
-- anyone used to it: @description contains TEXT@, then this account. The
-- text is read back by the parser like any other, so it ends up normalized.
addContainsRule :: (MonadIO m) => Text -> Text -> Int -> SqlPersistT m (Either RuleError StoredRule)
addContainsRule rawText accountName priority
  | Text.null (Text.strip rawText) = pure (Left EmptyRuleText)
  | isNothing (accountTypeFromName lowered) = pure (Left (UnknownAccountPrefix accountName))
  | otherwise =
      addRule (renderRule Rule {conditions = DescriptionContains rawText :| [], action = Categorize lowered}) priority
  where
    lowered = Text.toLower accountName

-- | Removes a rule. Rows already posted keep the account they were given.
deleteRule :: (MonadIO m) => Int64 -> SqlPersistT m (Either RuleError ())
deleteRule ruleNumber = do
  let key = toSqlKey ruleNumber
  found <- get key
  case found of
    Nothing -> pure (Left RuleNotFound)
    Just _ -> Right <$> delete (key :: PostingRuleId)

-- | Every saved rule in the order they run.
loadStoredRules :: (MonadIO m) => SqlPersistT m [StoredRule]
loadStoredRules = do
  rules <- selectList [] [Asc PostingRulePriority, Asc PostingRuleId]
  pure
    [ StoredRule
        { ruleId = fromSqlKey key
        , ruleText = postingRuleRuleText rule
        , priority = postingRulePriority rule
        , parsed = parseRule (postingRuleRuleText rule)
        }
    | Entity key rule <- rules
    ]

-- | The rules the planner uses, in the order they run, with their accounts
-- looked up. A rule that no longer parses, or names an account that isn't
-- there, is left out rather than stopping every posting: the Rules page
-- shows it with its problem.
loadRules :: (MonadIO m) => SqlPersistT m [Classify.Rule LedgerAccountId]
loadRules = do
  stored <- loadStoredRules
  accounts <- selectList [] [Asc LedgerAccountId]
  -- The language lower-cases account names; older accounts may not be.
  let accountIds = Map.fromListWith (\_ earlier -> earlier) [(Text.toLower (ledgerAccountName account), key) | Entity key account <- accounts]
  pure (mapMaybe (resolve accountIds) stored)
  where
    resolve accountIds stored = do
      rule <- either (const Nothing) Just stored.parsed
      account <- Map.lookup (ruleCategory rule) accountIds
      pure
        Classify.Rule
          { Classify.label = stored.ruleText
          , Classify.conditions = rule.conditions
          , Classify.outcome = case rule.action of
              Categorize _ -> Classify.ToAccount account
              SplitEqually _ friends -> Classify.SplitWith account friends
          }
