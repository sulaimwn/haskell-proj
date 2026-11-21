-- | What a rule would do to rows that already exist (Phase 7, DECISIONS D067).
--
-- Rules only ever applied to rows posted after they were written ("Rules
-- don't re-categorize the past", D044). This is the answer: 'previewRule'
-- says which existing rows a rule matches and what would happen to each,
-- changing nothing, and 'applyRule' then does it, one reversal and one new
-- entry per row, exactly as @recategorize@ and @split-row@ do.
--
-- The preview considers the rule on its own, not the other rules' priorities:
-- it answers "what would this rule do to the rows it matches", which is what
-- someone writing a rule wants to see. A row that a different rule put
-- elsewhere is shown moving from there, so nothing is hidden.
module Reckon.Rules.History
  ( HistoryRow (..)
  , PostedAs (..)
  , Effect (..)
  , PreviewRow (..)
  , previewRule
  , renderPreview
  , loadHistory
  , ApplyOutcome (..)
  , applyRule
  ) where

import Control.Monad.IO.Class (MonadIO)
import Data.Aeson qualified as Aeson
import Data.List.NonEmpty (NonEmpty)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Time (Day)
import Database.Persist.Sql (Single (..), SqlPersistT, fromSqlKey, rawSql)
import Reckon.Bank (BankAccountKind)
import Reckon.Database.Schema (RawBankRowId)
import Reckon.Import.Dedupe (normalizeDescription)
import Reckon.Messages (describeSplitRowError, describePostingError)
import Reckon.Money (Cents, renderCents)
import Reckon.Posting (recategorizeRow)
import Reckon.Rules.Eval (Candidate (..), matches)
import Reckon.Rules.Language
import Reckon.Sharing (SplitSpec (..), splitRow)

-- | An imported bank row, and where it stands in the ledger.
data HistoryRow = HistoryRow
  { rowId :: RawBankRowId
  , date :: Day
  , description :: Text
  -- ^ Both description lines, as the planner reads them.
  , amount :: Cents
  , kind :: BankAccountKind
  , postedAs :: PostedAs
  }
  deriving stock (Show, Eq)

data PostedAs
  = NotPosted
  | -- | One entry in effect, balanced by this single account.
    PostedTo Text
  | -- | An entry in effect that isn't one account (a split, or a transfer or
    -- cancelled pair through the clearing account), which a rule doesn't
    -- rewrite.
    PostedOtherwise
  deriving stock (Show, Eq)

data Effect
  = -- | The rule would move the row out of this account.
    WouldMoveFrom Text
  | -- | Already where the rule puts it.
    AlreadyThere
  | -- | Not posted yet: the next @post@ will apply the rule.
    AppliesWhenPosted
  | -- | Matches, but the rule can't be carried out. Says why.
    CannotChange Text
  deriving stock (Show, Eq)

data PreviewRow = PreviewRow
  { row :: HistoryRow
  , effect :: Effect
  }
  deriving stock (Show, Eq)

-- | The rows the rule matches, newest first as given, with what would happen
-- to each. Rows it doesn't match are left out.
previewRule :: Rule -> [HistoryRow] -> [PreviewRow]
previewRule rule rows =
  [ PreviewRow {row, effect = effectOn rule row}
  | row <- rows
  , matches rule Candidate {description = normalizeDescription row.description, amount = row.amount, kind = row.kind}
  ]

effectOn :: Rule -> HistoryRow -> Effect
effectOn rule row = case (rule.action, row.postedAs) of
  (SplitEqually _ _, _) | row.amount >= mempty -> CannotChange "only money going out can be split"
  (_, PostedOtherwise) -> CannotChange "it's part of a transfer, a cancelled pair or a split"
  (_, NotPosted) -> AppliesWhenPosted
  (Categorize account, PostedTo current)
    | current == account -> AlreadyThere
    | otherwise -> WouldMoveFrom current
  (SplitEqually _ _, PostedTo current) -> WouldMoveFrom current

-- | Every imported row, newest first, with the account its entry in effect
-- balances against (if it has one).
loadHistory :: (MonadIO m) => SqlPersistT m [HistoryRow]
loadHistory = do
  found <-
    rawSql
      "SELECT r.id, r.transaction_date, r.description_1, r.description_2, r.amount_cents, b.account_kind, \
      \  (cur.entry_id IS NOT NULL), \
      \  (SELECT coalesce(json_agg(a.name ORDER BY a.name), '[]'::json)::text \
      \     FROM journal_lines l JOIN ledger_accounts a ON a.id = l.ledger_account_id \
      \    WHERE l.entry_id = cur.entry_id AND l.ledger_account_id <> b.ledger_account_id) \
      \FROM raw_bank_rows r \
      \JOIN bank_accounts b ON b.id = r.bank_account_id \
      \LEFT JOIN LATERAL ( \
      \  SELECT ev.entry_id FROM journal_entry_evidence ev \
      \   WHERE ev.raw_bank_row_id = r.id \
      \     AND NOT EXISTS (SELECT 1 FROM journal_entries rev WHERE rev.reverses_entry_id = ev.entry_id) \
      \   LIMIT 1) cur ON true \
      \ORDER BY r.transaction_date DESC, r.id DESC"
      []
  pure
    [ HistoryRow
        { rowId
        , date
        , description = Text.strip (description1 <> " " <> description2)
        , amount
        , kind
        , postedAs = postedAs isPosted (fromMaybe [] (Aeson.decodeStrict (Text.encodeUtf8 countersJson)))
        }
    | (Single rowId, Single date, Single description1, Single description2, Single amount, Single kind, Single isPosted, Single countersJson) <- found
    ]
  where
    postedAs :: Bool -> [Text] -> PostedAs
    postedAs isPosted counters = case (isPosted, counters) of
      (False, _) -> NotPosted
      (True, [one]) | one /= "asset:clearing" -> PostedTo one
      _ -> PostedOtherwise

data ApplyOutcome = ApplyOutcome
  { moved :: Int
  , refused :: [(Day, Text, Text)]
  -- ^ A row the ledger wouldn't change: its date, description and why.
  }
  deriving stock (Show, Eq)

-- | Moves every row the rule would move. Each row is reversed (dated like
-- the original, so no balance on any date changes) and posted again. A row
-- the ledger refuses to change is reported and the rest carry on.
applyRule :: (MonadIO m) => Rule -> SqlPersistT m ApplyOutcome
applyRule rule = do
  history <- loadHistory
  let moving = [row | PreviewRow {row, effect = WouldMoveFrom _} <- previewRule rule history]
  results <- traverse change moving
  pure
    ApplyOutcome
      { moved = length [() | (_, Nothing) <- results]
      , refused = [(row.date, row.description, why) | (row, Just why) <- results]
      }
  where
    change row = do
      let rowNumber = Text.pack (show (fromSqlKey row.rowId))
      result <- case rule.action of
        Categorize account -> either (Just . describePostingError rowNumber) (const Nothing) <$> recategorizeRow row.rowId account
        SplitEqually account friends -> either (Just . describeSplitRowError rowNumber) (const Nothing) <$> splitRow row.rowId account (EqualWith (friendList friends))
      pure (row, result)
    friendList :: NonEmpty Text -> [Text]
    friendList = foldr (:) []

-- | The preview as text for the command line: one line per row, newest
-- first, then a summary.
renderPreview :: [PreviewRow] -> Text
renderPreview [] = "This rule matches none of the rows imported so far.\n"
renderPreview previewed =
  Text.unlines $
    [ "  " <> Text.pack (show preview.row.date) <> "  " <> renderCents preview.row.amount <> "  " <> preview.row.description <> "  (" <> describeEffect preview.effect <> ")"
    | preview <- previewed
    ]
      <> [ ""
         , Text.pack (show (length previewed)) <> " row(s) match; "
             <> Text.pack (show (length [() | PreviewRow {effect = WouldMoveFrom _} <- previewed]))
             <> " would move."
         ]

describeEffect :: Effect -> Text
describeEffect = \case
  WouldMoveFrom current -> "would move from " <> current
  AlreadyThere -> "already there"
  AppliesWhenPosted -> "not posted yet: applies at the next post"
  CannotChange why -> "can't change: " <> why
