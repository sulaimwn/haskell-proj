-- | Reports over the journal (Phase 4). Read-only.
module Reckon.Report
  ( spendingByAccount
  , renderSpending
  ) where

import Control.Monad.IO.Class (MonadIO)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (Day)
import Database.Persist.Sql (PersistValue (..), Single (..), SqlPersistT, rawSql)
import Reckon.Money (Cents (..), renderCents, sumCents)

-- | What I spent per expense account between two dates (inclusive), largest
-- first. Only expense accounts count: a friend's share of a split payment is
-- in their receivable account, and transfers go through the clearing account,
-- so neither shows up as spending. Reversed entries cancel out.
spendingByAccount :: (MonadIO m) => Day -> Day -> SqlPersistT m [(Text, Cents)]
spendingByAccount from to = do
  found <-
    rawSql
      "SELECT a.name, sum(l.amount_cents)::bigint \
      \FROM journal_lines l \
      \JOIN journal_entries e ON e.id = l.entry_id \
      \JOIN ledger_accounts a ON a.id = l.ledger_account_id \
      \WHERE a.account_type = 'expense' AND e.occurred_on BETWEEN ? AND ? \
      \GROUP BY a.name HAVING sum(l.amount_cents) <> 0 \
      \ORDER BY sum(l.amount_cents) DESC, a.name"
      [PersistDay from, PersistDay to]
  pure [(name, Cents total) | (Single name, Single total) <- found]

renderSpending :: Day -> Day -> [(Text, Cents)] -> Text
renderSpending from to [] = "No spending from " <> Text.pack (show from) <> " to " <> Text.pack (show to) <> ".\n"
renderSpending from to accounts =
  Text.unlines $
    ("Spending from " <> Text.pack (show from) <> " to " <> Text.pack (show to) <> " (my share only):")
      : [ "  " <> Text.justifyLeft width ' ' name <> "  " <> renderCents amount
        | (name, amount) <- accounts
        ]
      <> ["  " <> Text.justifyLeft width ' ' "total" <> "  " <> renderCents (sumCents (map snd accounts))]
  where
    width = maximum (5 : map (Text.length . fst) accounts)
