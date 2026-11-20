-- | Splitting a bank row between me and my friends (Phase 4, DECISIONS
-- D049).
--
-- The row's entry is replaced by one with several lines on the non-bank
-- side: my share in a category, and each friend's share in their
-- @receivable:<name>@ account. The pure rules are in "Reckon.Posting.Split".
module Reckon.Sharing
  ( SplitSpec (..)
  , splitRow
  , SplitRowError (..)
  ) where

import Control.Monad.IO.Class (MonadIO)
import Data.Bifunctor (first)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Database.Persist (Entity (..))
import Database.Persist.Sql (SqlPersistT)
import Reckon.Database.Schema
import Reckon.Ledger (accountTypeFromName, findOrCreateLedgerAccount)
import Reckon.Money (Cents)
import Reckon.People (findPersonByName)
import Reckon.Posting (ManualPostingError (..), loadEvidenceRow, manualErrorFromRepost, repostRow)
import Reckon.Posting.Classify (EvidenceRow (..))
import Reckon.Posting.Split

-- | How the money is shared among the friends named.
data SplitSpec
  = -- | Everyone, me included, pays the same (odd cents to me first).
    EqualWith [Text]
  | -- | Each friend owes exactly this much. I keep the rest.
    ExactShares [(Text, Cents)]
  deriving stock (Show, Eq)

data SplitRowError
  = InvalidSplit SplitError
  | -- | Not one of the people added with @add-person@.
    UnknownPerson Text
  | -- | The row couldn't be (re)posted: see 'ManualPostingError'.
    CouldNotPost ManualPostingError
  deriving stock (Show, Eq)

-- | @splitRow rowId category spec@. If the row is already posted, its entry
-- is reversed and replaced (see 'Reckon.Posting.repostRow'). Nothing is
-- written if the split is invalid.
splitRow :: (MonadIO m) => RawBankRowId -> Text -> SplitSpec -> SqlPersistT m (Either SplitRowError ())
splitRow rowId categoryName spec = do
  found <- loadEvidenceRow rowId
  case (found, accountTypeFromName categoryName) of
    (Nothing, _) -> pure (Left (CouldNotPost RowNotFound))
    (_, Nothing) -> pure (Left (CouldNotPost (UnknownAccount categoryName)))
    (Just row, Just categoryType) -> do
      people <- traverse (\name -> (name,) <$> findPersonByName name) (friendNames spec)
      case ([name | (name, Nothing) <- people], planSplit row.amount spec) of
        (unknown : _, _) -> pure (Left (UnknownPerson unknown))
        ([], Left problem) -> pure (Left (InvalidSplit problem))
        ([], Right split) -> do
          let parts = splitParts split
              receivables = Map.fromList [(name, personLedgerAccountId person) | (name, Just (Entity _ person)) <- people]
          -- Only create the category account if some of the money is mine.
          categoryAccount <-
            if any ((== Me) . fst) parts
              then Just <$> findOrCreateLedgerAccount categoryName categoryType
              else pure Nothing
          let accountFor = \case
                Me -> categoryAccount
                Friend name -> Map.lookup name receivables
              counterLines = [(account, amount) | (participant, amount) <- parts, Just account <- [accountFor participant]]
          first (CouldNotPost . manualErrorFromRepost) <$> repostRow row counterLines
  where
    friendNames = \case
      EqualWith names -> names
      ExactShares shares -> map fst shares
    planSplit amount = \case
      EqualWith names -> equalSplit amount names
      ExactShares shares -> mkSplit amount shares
