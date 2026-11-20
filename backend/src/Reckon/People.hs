-- | The people I share expenses with, and what each of them owes me
-- (Phase 4).
--
-- Each person has a receivable account, @receivable:<name>@. A friend's
-- share of a split payment is debited there, and a repayment credits it, so
-- its balance is exactly what they currently owe.
module Reckon.People
  ( addPerson
  , PersonError (..)
  , isValidPersonName
  , loadKnownPeople
  , findPersonByName
  , PersonOwes (..)
  , whoOwesWhat
  , renderOwed
  ) where

import Control.Monad (forM)
import Control.Monad.IO.Class (MonadIO)
import Data.Char (isAsciiLower, isDigit)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (Day)
import Database.Persist (Entity (..), getBy, insert, selectList)
import Database.Persist.Sql (SqlPersistT)
import Database.Persist.Types (SelectOpt (..))
import Reckon.Database.Schema
import Reckon.Import.Dedupe (normalizeDescription)
import Reckon.Ledger (accountBalanceAsOf, findOrCreateLedgerAccount)
import Reckon.Ledger.AccountType (AccountType (..), naturalBalance)
import Reckon.Money (Cents (..), renderCents, sumCents)
import Reckon.Posting.Classify (KnownPerson (..))

data PersonError
  = -- | Lower-case letters, digits and hyphens only: the name becomes part
    -- of an account name.
    InvalidPersonName Text
  | EmptyMatchText
  | PersonAlreadyExists Text
  | -- | Another person already has this text. Carries the text, normalized.
    MatchTextAlreadyUsed Text
  deriving stock (Show, Eq)

isValidPersonName :: Text -> Bool
isValidPersonName name = case Text.uncons name of
  Just (first, rest) -> startsOk first && Text.all (\character -> startsOk character || character == '-') rest
  Nothing -> False
  where
    startsOk character = isAsciiLower character || isDigit character

-- | Adds a person and their @receivable:<name>@ account (reusing the account
-- if it already exists). @matchText@ is the text their e-Transfers show in
-- the description, e.g. their name as the bank writes it. It's matched
-- against the upper-cased description, so case doesn't matter.
addPerson :: (MonadIO m) => Text -> Text -> SqlPersistT m (Either PersonError PersonId)
addPerson name rawMatchText
  | not (isValidPersonName name) = pure (Left (InvalidPersonName name))
  | Text.null matchText = pure (Left EmptyMatchText)
  | otherwise = do
      sameName <- getBy (UniquePersonName name)
      sameText <- getBy (UniquePersonMatchText matchText)
      case (sameName, sameText) of
        (Just _, _) -> pure (Left (PersonAlreadyExists name))
        (_, Just _) -> pure (Left (MatchTextAlreadyUsed matchText))
        _ -> do
          receivable <- findOrCreateLedgerAccount ("receivable:" <> name) Asset
          Right <$> insert Person {personName = name, personMatchText = matchText, personLedgerAccountId = receivable}
  where
    matchText = normalizeDescription rawMatchText

findPersonByName :: (MonadIO m) => Text -> SqlPersistT m (Maybe (Entity Person))
findPersonByName name = getBy (UniquePersonName name)

-- | Everyone, as the posting planner wants them.
loadKnownPeople :: (MonadIO m) => SqlPersistT m [KnownPerson LedgerAccountId]
loadKnownPeople = do
  people <- selectList [] [Asc PersonId]
  pure
    [ KnownPerson {name = personName person, matchText = personMatchText person, account = personLedgerAccountId person}
    | Entity _ person <- people
    ]

data PersonOwes = PersonOwes
  { name :: Text
  , owes :: Cents
  -- ^ Negative if they've paid me more than they owed.
  }
  deriving stock (Show, Eq)

-- | What each person owes me at the end of the given day.
whoOwesWhat :: (MonadIO m) => Day -> SqlPersistT m [PersonOwes]
whoOwesWhat asOf = do
  people <- selectList [] [Asc PersonName]
  forM people $ \(Entity _ person) -> do
    rawBalance <- accountBalanceAsOf (personLedgerAccountId person) asOf
    -- A receivable is an asset: its natural balance is its raw one.
    pure PersonOwes {name = personName person, owes = naturalBalance Asset rawBalance}

renderOwed :: Day -> [PersonOwes] -> Text
renderOwed _ [] = "Nobody added yet. Add someone with: scripts/reckon.sh add-person NAME MATCH_TEXT\n"
renderOwed asOf people =
  Text.unlines $
    ("Owed to you as of " <> Text.pack (show asOf) <> ":")
      : [ "  " <> Text.justifyLeft width ' ' person.name <> "  " <> renderCents person.owes <> overpaidNote person.owes
        | person <- people
        ]
      <> ["  " <> Text.justifyLeft width ' ' "total" <> "  " <> renderCents (sumCents (map (.owes) people))]
  where
    width = maximum (5 : map (Text.length . (.name)) people)
    overpaidNote owed
      | owed < mempty = "  (they've paid you more than they owed)"
      | otherwise = ""
