-- | Joining screenshots of one scroll of a transaction list (Phase 5,
-- DECISIONS D056). Pure.
--
-- Scrolling the app and taking several screenshots makes neighbouring
-- screenshots share rows: the bottom of one is the top of the next. Joining
-- them means finding that overlap, not just removing duplicates, because
-- the list can legitimately hold identical rows (two $4.50 coffees on the
-- same day). Dropping every repeat would lose one of them.
--
-- The rule: screenshots are given in scroll order (top of the list first).
-- For each next screenshot, find the longest run of rows at the end of what
-- has been joined so far that equals the start of the next one, and join
-- there. When more than one overlap length would fit, the largest is used
-- (it invents the fewest rows) and the ambiguity is reported.
module Reckon.Screenshot.Align
  ( Alignment (..)
  , AlignWarning (..)
  , alignScreenshots
  ) where

data AlignWarning
  = -- | Between this screenshot (1-based) and the next, no rows are shared.
    -- Transactions between them may be missing.
    NoOverlap Int
  | -- | Several overlap lengths fit. Carries them; the largest was used.
    -- Identical rows make this unavoidable without a running balance to
    -- tell them apart.
    AmbiguousOverlap Int [Int]
  | -- | The next screenshot overlaps the START of what came before, so the
    -- screenshots were given in the wrong order. They were joined as if
    -- swapped.
    OutOfOrder Int
  deriving stock (Show, Eq)

data Alignment row = Alignment
  { rows :: [row]
  , warnings :: [AlignWarning]
  }
  deriving stock (Show, Eq)

-- | @alignScreenshots identity screenshots@. @identity@ is what makes two
-- rows "the same row" (date, description, amount, ...).
alignScreenshots :: (Eq identity) => (row -> identity) -> [[row]] -> Alignment row
alignScreenshots identity screenshots = case screenshots of
  [] -> Alignment [] []
  first : rest ->
    let (joined, warnings) = foldl step (first, []) (zip [1 ..] rest)
     in Alignment {rows = joined, warnings = reverse warnings}
  where
    step (joined, warnings) (position, next) =
      case overlapLengths joined next of
        [] -> case overlapLengths next joined of
          [] -> (joined <> next, NoOverlap position : warnings)
          swapped ->
            let overlap = maximum swapped
             in (take (length next - overlap) next <> joined, OutOfOrder position : warnings)
        lengths ->
          let overlap = maximum lengths
              ambiguous = [AmbiguousOverlap position lengths | length lengths > 1]
           in (joined <> drop overlap next, ambiguous <> warnings)

    -- Every k (at least 1) for which the last k rows of @before@ are the
    -- first k rows of @after@.
    overlapLengths before after =
      [ size
      | size <- [1 .. min (length before) (length after)]
      , map identity (lastN size before) == map identity (take size after)
      ]

    lastN size items = drop (length items - size) items
