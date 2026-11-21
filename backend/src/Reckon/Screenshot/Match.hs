-- | Matching a screenshot's rows to the rows that supersede them (Phase 5,
-- DECISIONS D057). Pure.
--
-- A screenshot row is provisional: it's what the app showed, read by a
-- model. A bank CSV row (or a later screenshot's posted row) is better
-- evidence of the same transaction. This decides which provisional row is
-- which later row.
--
-- Same discipline as transfer pairing: two rows are matched only when each
-- is the other's /only/ candidate. Anything else stays unmatched for a
-- person to see, rather than being resolved on a guess.
--
-- Two stages. First, the same amount: the app's date and the bank's date can
-- differ by a few days, and descriptions are worded differently, so a match
-- needs the dates close and a meaningful word in common. Second, only for
-- /pending/ rows: a hold that posted for a different amount (a $100 gas
-- hold that posted at $43.20). That needs the same sign, the later row to
-- come within a week after the hold, and a word in common.
module Reckon.Screenshot.Match
  ( Provisional (..)
  , Later (..)
  , Match (..)
  , MatchKind (..)
  , planMatches
  , descriptionsAgree
  , sameAmountWindowDays
  , pendingWindowDays
  ) where

import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (Day, diffDays)
import Reckon.Import.Dedupe (normalizeDescription)
import Reckon.Money (Cents (..))
import Reckon.Screenshot.Extraction (Section (..))

-- | A row read from a screenshot, not yet confirmed.
data Provisional rowId = Provisional
  { rowId :: rowId
  , date :: Day
  , description :: Text
  , amount :: Cents
  , section :: Section
  }
  deriving stock (Show, Eq)

-- | A row that may supersede one: from a CSV, or a later screenshot's
-- posted row.
data Later rowId = Later
  { rowId :: rowId
  , date :: Day
  , description :: Text
  , amount :: Cents
  }
  deriving stock (Show, Eq)

data MatchKind
  = SameAmount
  | -- | A pending hold that posted for a different amount: the hold's, then
    -- the final one.
    AmountChanged Cents Cents
  deriving stock (Show, Eq)

data Match provisionalId laterId = Match
  { provisional :: provisionalId
  , later :: laterId
  , kind :: MatchKind
  }
  deriving stock (Show, Eq)

-- | How far apart the app's date and the bank's date for one transaction may
-- be, when the amounts are the same.
sameAmountWindowDays :: Integer
sameAmountWindowDays = 3

-- | How long after a pending hold's date the posted version may appear.
pendingWindowDays :: Integer
pendingWindowDays = 7

-- | Which provisional row is which later row. Identical rows (the same date,
-- words and amount: two coffees on one day) are interchangeable, so they
-- are matched as a group, in row order: two coffees in a screenshot and two
-- in the bank's export pair off one to one. Rows that differ in any way are
-- only matched when the match is unambiguous.
planMatches :: (Ord provisionalId, Ord laterId) => [Provisional provisionalId] -> [Later laterId] -> [Match provisionalId laterId]
planMatches provisionals laters = sameAmountMatches <> changedAmountMatches
  where
    sameAmountMatches =
      matchGroups sameAmountRelated (\_ _ -> SameAmount) (provisionalGroups provisionals) (laterGroups laters)
    matchedProvisional = Set.fromList (map (.provisional) sameAmountMatches)
    matchedLater = Set.fromList (map (.later) sameAmountMatches)
    changedAmountMatches =
      matchGroups
        pendingChangedRelated
        (\provisional later -> AmountChanged provisional.amount later.amount)
        (provisionalGroups [row | row <- provisionals, not (Set.member row.rowId matchedProvisional)])
        (laterGroups [row | row <- laters, not (Set.member row.rowId matchedLater)])

-- | Rows alike in everything that matters, in row order. The first stands
-- for the group.
provisionalGroups :: (Ord rowId) => [Provisional rowId] -> [[Provisional rowId]]
provisionalGroups = groupAlike (\row -> (row.date, normalizeDescription row.description, row.amount, row.section == Pending)) (.rowId)

laterGroups :: (Ord rowId) => [Later rowId] -> [[Later rowId]]
laterGroups = groupAlike (\row -> (row.date, normalizeDescription row.description, row.amount)) (.rowId)

groupAlike :: (Ord key, Ord rowId) => (row -> key) -> (row -> rowId) -> [row] -> [[row]]
groupAlike keyOf rowIdOf rows =
  map (sortOn rowIdOf) (Map.elems (Map.fromListWith (flip (<>)) [(keyOf row, [row]) | row <- rows]))

-- | Pairs groups when each is the other's only candidate, then pairs their
-- members off in order. A group with more members than its partner leaves
-- the extras unmatched.
matchGroups ::
  (Provisional p -> Later l -> Bool) ->
  (Provisional p -> Later l -> MatchKind) ->
  [[Provisional p]] ->
  [[Later l]] ->
  [Match p l]
matchGroups related kindOf provisionalGroupsList laterGroupsList =
  concat
    [ zipWith (\provisional later -> Match {provisional = provisional.rowId, later = later.rowId, kind = kindOf provisional later}) provisionalMembers laterMembers
    | (provisionalMembers, laterMembers) <- pairs
    ]
  where
    indexedProvisional = zip [0 :: Int ..] provisionalGroupsList
    indexedLater = Map.fromList (zip [0 :: Int ..] laterGroupsList)
    candidatesOf = Map.fromList [(i, [j | (j, group) <- Map.toList indexedLater, related (head' members) (head' group)]) | (i, members) <- indexedProvisional]
    providersOf = Map.fromListWith (<>) [(j, [i]) | (i, js) <- Map.toList candidatesOf, j <- js]
    pairs =
      [ (members, laterMembers)
      | (i, members) <- indexedProvisional
      , [j] <- [Map.findWithDefault [] i candidatesOf]
      , [only] <- [Map.findWithDefault [] j providersOf]
      , only == i
      , Just laterMembers <- [Map.lookup j indexedLater]
      ]
    -- Groups are never empty.
    head' = \case
      first : _ -> first
      [] -> error "matchGroups: empty group"

sameAmountRelated :: Provisional p -> Later l -> Bool
sameAmountRelated provisional later =
  provisional.amount == later.amount
    && abs (diffDays provisional.date later.date) <= sameAmountWindowDays
    && descriptionsAgree provisional.description later.description

pendingChangedRelated :: Provisional p -> Later l -> Bool
pendingChangedRelated provisional later =
  provisional.section == Pending
    && provisional.amount /= later.amount
    && sameSign provisional.amount later.amount
    && diffDays later.date provisional.date >= 0
    && diffDays later.date provisional.date <= pendingWindowDays
    && descriptionsAgree provisional.description later.description
  where
    sameSign (Cents a) (Cents b) = signum a == signum b

-- | The two descriptions share a meaningful word. Banks word the same
-- transaction differently ("Interac purchase - COFFEE CO" in an export,
-- "Coffee Co" in the app), so this is deliberately loose: it only gets to
-- decide together with an equal amount or date window and uniqueness.
descriptionsAgree :: Text -> Text -> Bool
descriptionsAgree first second = not (Set.null (Set.intersection (meaningfulWords first) (meaningfulWords second)))

meaningfulWords :: Text -> Set.Set Text
meaningfulWords =
  Set.fromList
    . filter (\word -> Text.length word >= 3 && word `Set.notMember` genericWords)
    . Text.words
    . Text.map (\character -> if isWordCharacter character then character else ' ')
    . normalizeDescription
  where
    isWordCharacter character = character `elem` (['A' .. 'Z'] <> ['0' .. '9'])

-- | Words that appear in many descriptions and say nothing about which
-- transaction it is.
genericWords :: Set.Set Text
genericWords =
  Set.fromList
    [ "THE", "AND", "INTERAC", "PURCHASE", "DEBIT", "CREDIT", "PAYMENT", "ONLINE", "BANKING"
    , "TRANSFER", "RECEIVED", "SENT", "POS", "MERCHANDISE", "PENDING", "ETRANSFER", "BILL", "CAD"
    ]
