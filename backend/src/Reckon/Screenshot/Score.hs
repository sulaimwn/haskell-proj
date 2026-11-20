-- | Scoring an extraction against a hand-labelled answer (Phase 5). Pure.
--
-- Used by @reckon-cli eval-screenshots@: the labelled screenshots live in
-- @private/eval@ and are never committed, but the scoring is ordinary code
-- with ordinary tests.
module Reckon.Screenshot.Score
  ( Score (..)
  , scoreExtraction
  , renderScore
  ) where

import Data.List (partition)
import Data.Text (Text)
import Data.Text qualified as Text
import Reckon.Import.Dedupe (normalizeDescription)
import Reckon.Screenshot.Extraction (ExtractedRow (..))

data Score = Score
  { expectedCount :: Int
  , extractedCount :: Int
  , foundCount :: Int
  -- ^ Expected rows the extraction has, by date and amount.
  , missed :: [ExtractedRow]
  -- ^ Expected rows the extraction doesn't have.
  , invented :: [ExtractedRow]
  -- ^ Extracted rows that aren't in the expected answer.
  , descriptionsRight :: Int
  , sectionsRight :: Int
  , balancesRight :: Int
  -- ^ The last three count among the found rows.
  }
  deriving stock (Show, Eq)

-- | @scoreExtraction expected extracted@. Rows are paired by date and amount
-- (preferring one with the same description), each extracted row used at
-- most once, so a duplicated or dropped row is counted as such.
scoreExtraction :: [ExtractedRow] -> [ExtractedRow] -> Score
scoreExtraction expected extracted =
  Score
    { expectedCount = length expected
    , extractedCount = length extracted
    , foundCount = length pairs
    , missed = [row | (row, Nothing) <- paired]
    , invented = leftover
    , descriptionsRight = length [() | (wanted, got) <- pairs, normalizeDescription wanted.description == normalizeDescription got.description]
    , sectionsRight = length [() | (wanted, got) <- pairs, wanted.section == got.section]
    , balancesRight = length [() | (wanted, got) <- pairs, wanted.runningBalance == got.runningBalance]
    }
  where
    (paired, leftover) = foldl pairOff ([], extracted) expected
    pairs = [(wanted, got) | (wanted, Just got) <- paired]

    pairOff (done, available) wanted =
      case pick wanted available of
        Nothing -> (done <> [(wanted, Nothing)], available)
        Just (got, remaining) -> (done <> [(wanted, Just got)], remaining)

    pick wanted available =
      let sameKey = [row | row <- available, row.transactionDate == wanted.transactionDate, row.amount == wanted.amount]
          sameDescription = [row | row <- sameKey, normalizeDescription row.description == normalizeDescription wanted.description]
       in case (sameDescription, sameKey) of
            (best : _, _) -> Just (best, removeFirst best available)
            ([], best : _) -> Just (best, removeFirst best available)
            _ -> Nothing

    removeFirst target items = case partition (== target) items of
      (_ : otherCopies, others) -> otherCopies <> others
      ([], others) -> others

renderScore :: Text -> Score -> Text
renderScore name score =
  Text.unlines
    [ name <> ": " <> found <> " of " <> count score.expectedCount <> " expected rows found" <> percent score.foundCount score.expectedCount
    , "  missed " <> count (length score.missed) <> ", invented " <> count (length score.invented)
    , "  among the found rows: descriptions right " <> ratio score.descriptionsRight <> ", sections right " <> ratio score.sectionsRight <> ", balances right " <> ratio score.balancesRight
    ]
  where
    found = count score.foundCount
    count = Text.pack . show
    ratio right = count right <> "/" <> count score.foundCount
    -- Whole percent, rounded down, with no floating point.
    percent _ 0 = ""
    percent part whole = " (" <> count (part * 100 `div` whole) <> "%)"
