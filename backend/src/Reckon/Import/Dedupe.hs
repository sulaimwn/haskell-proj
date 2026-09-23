-- | Deciding which rows of a new export are really new (DECISIONS D029).
--
-- Bank CSVs have no transaction IDs, and overlapping exports repeat rows.
-- A row is identified by its account, date, 'Fingerprint', and
-- /occurrence/: the position among rows with the same date and
-- fingerprint in the file (the first identical $4.50 coffee that day is
-- occurrence 1, the second is 2). Two exports that both contain both
-- coffees produce the same four keys, so the second import adds nothing.
-- An export that caught only one coffee (taken mid-day) adds the other
-- later.
--
-- Counting identical rows, rather than using a row's position in the file,
-- means the order of /different/ transactions within a day doesn't matter.
-- Banks don't promise to keep it stable between exports.
--
-- Everything here is pure and doesn't depend on the database. 'planImport'
-- is used for real imports and in the property tests.
module Reckon.Import.Dedupe
  ( Fingerprint (..)
  , fingerprintOf
  , normalizeDescription
  , RowKey (..)
  , IncomingRow (..)
  , assignOccurrences
  , StoredRow (..)
  , ImportPlan (..)
  , ReviewFlag (..)
  , ReviewItemKind (..)
  , reviewFlagKind
  , planImport
  ) where

import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (Day)
import Database.Persist.Sql (PersistField (..), PersistFieldSql (..), PersistValue (..), SqlType (..))
import Reckon.Money (Cents (..))

-- | What makes two rows on the same day "the same transaction": the
-- normalized descriptions, the cheque number, and the amount. Stored as
-- readable text (e.g. @"TIM HORTONS #123|COFFEE||-450"@) so it can be read
-- directly in psql.
newtype Fingerprint = Fingerprint Text
  deriving stock (Show)
  deriving newtype (Eq, Ord, PersistField, PersistFieldSql)

-- | Upper-cases and collapses runs of whitespace, so cosmetic differences
-- between exports ("Tim  Hortons " vs "TIM HORTONS") don't create a new
-- transaction.
normalizeDescription :: Text -> Text
normalizeDescription = Text.unwords . Text.words . Text.toUpper

fingerprintOf :: Text -> Text -> Text -> Cents -> Fingerprint
fingerprintOf description1 description2 chequeNumber (Cents amountCents) =
  Fingerprint
    ( Text.intercalate
        "|"
        [ normalizeDescription description1
        , normalizeDescription description2
        , Text.strip chequeNumber
        , Text.pack (show amountCents)
        ]
    )

-- | The identity of a row within one bank account.
data RowKey = RowKey
  { transactionDate :: Day
  , fingerprint :: Fingerprint
  , occurrence :: Int
  }
  deriving stock (Show, Eq, Ord)

-- | A row from the file being imported. The payload is whatever the caller
-- needs to insert it later (for RBC, the parsed CSV row).
data IncomingRow payload = IncomingRow
  { transactionDate :: Day
  , fingerprint :: Fingerprint
  , amount :: Cents
  , payload :: payload
  }
  deriving stock (Show, Eq)

-- | Numbers identical rows (same date and fingerprint) 1, 2, 3, ... in file
-- order.
assignOccurrences :: [IncomingRow payload] -> [(RowKey, IncomingRow payload)]
assignOccurrences = reverse . snd . foldl' number (Map.empty, [])
  where
    number (seenSoFar, numbered) row =
      let identity = (row.transactionDate, row.fingerprint)
          occurrence = Map.findWithDefault 0 identity seenSoFar + 1
          key = RowKey {transactionDate = row.transactionDate, fingerprint = row.fingerprint, occurrence}
       in (Map.insert identity occurrence seenSoFar, (key, row) : numbered)

-- | A row already in the database, as far as planning is concerned.
data StoredRow storedId = StoredRow
  { storedId :: storedId
  , key :: RowKey
  , amount :: Cents
  }
  deriving stock (Show, Eq)

-- | Something the import shouldn't decide on its own.
data ReviewFlag storedId
  = -- | A stored row is absent from the newer export, on a day the export
    -- fully covers. Maybe the bank dropped it, maybe the older export was
    -- wrong. Either way a person should look.
    MissingFromNewerExport storedId
  | -- | On the same day, a stored row is absent and a new row with the same
    -- amount appeared. It's probably the same transaction with its
    -- description changed between exports, and it's now stored twice.
    PossibleDuplicate storedId RowKey
  deriving stock (Show, Eq)

-- | How a flag is stored in @import_review_items.kind@.
data ReviewItemKind
  = MissingFromNewerExportKind
  | PossibleDuplicateKind
  deriving stock (Show, Eq, Ord, Enum, Bounded)

reviewFlagKind :: ReviewFlag storedId -> ReviewItemKind
reviewFlagKind = \case
  MissingFromNewerExport _ -> MissingFromNewerExportKind
  PossibleDuplicate _ _ -> PossibleDuplicateKind

reviewItemKindText :: ReviewItemKind -> Text
reviewItemKindText = \case
  MissingFromNewerExportKind -> "missing_from_newer_export"
  PossibleDuplicateKind -> "possible_duplicate"

instance PersistField ReviewItemKind where
  toPersistValue = PersistText . reviewItemKindText
  fromPersistValue = \case
    PersistText text ->
      maybe
        (Left ("unknown import_review_items.kind: " <> text))
        Right
        (lookup text [(reviewItemKindText kind, kind) | kind <- [minBound .. maxBound]])
    other -> Left ("import_review_items.kind: expected text, got " <> Text.pack (show other))

instance PersistFieldSql ReviewItemKind where
  sqlType _ = SqlString

data ImportPlan storedId payload = ImportPlan
  { rowsToAdd :: [(RowKey, IncomingRow payload)]
  , rowsAlreadyPresent :: Int
  , reviewFlags :: [ReviewFlag storedId]
  }
  deriving stock (Show, Eq)

-- | Plans the import of one account's rows from one file.
--
-- @storedRows@ must be every stored row for this account dated within the
-- file's first and last dates. The first and last days are "edge days": an
-- export taken mid-day may legitimately miss some of that day's rows, so a
-- stored row missing from an edge day is not flagged.
planImport :: [StoredRow storedId] -> [IncomingRow payload] -> ImportPlan storedId payload
planImport storedRows incomingRows =
  ImportPlan
    { rowsToAdd
    , rowsAlreadyPresent = length numbered - length rowsToAdd
    , reviewFlags = concatMap flagsForDay (Map.keys absentByDay)
    }
  where
    numbered = assignOccurrences incomingRows
    storedKeys = Set.fromList (map (.key) storedRows)
    incomingKeys = Set.fromList (map fst numbered)
    rowsToAdd = filter (\(key, _) -> not (Set.member key storedKeys)) numbered

    fileDates = map (.transactionDate) incomingRows
    isEdgeDay day = not (null fileDates) && (day == minimum fileDates || day == maximum fileDates)

    absentByDay =
      Map.fromListWith
        (flip (<>))
        [ (storedRow.key.transactionDate, [storedRow])
        | storedRow <- storedRows
        , not (Set.member storedRow.key incomingKeys)
        ]
    addedByDay = Map.fromListWith (flip (<>)) [(key.transactionDate, [(key, row.amount)]) | (key, row) <- rowsToAdd]

    flagsForDay day =
      let absent = sortOn (.key) (Map.findWithDefault [] day absentByDay)
          added = Map.findWithDefault [] day addedByDay
          (pairs, unpaired) = pairByAmount absent added
          missing = [MissingFromNewerExport storedRow.storedId | not (isEdgeDay day), storedRow <- unpaired]
       in [PossibleDuplicate storedRow.storedId addedKey | (storedRow, addedKey) <- pairs] <> missing

-- | Greedily pairs each absent stored row with a not-yet-paired added row of
-- the same amount. Returns the pairs and the absent rows left unpaired.
pairByAmount :: [StoredRow storedId] -> [(RowKey, Cents)] -> ([(StoredRow storedId, RowKey)], [StoredRow storedId])
pairByAmount absent added = go absent added [] []
  where
    go [] _ pairs unpaired = (reverse pairs, reverse unpaired)
    go (storedRow : rest) candidates pairs unpaired =
      case break (\(_, candidateAmount) -> candidateAmount == storedRow.amount) candidates of
        (before, (candidateKey, _) : after) -> go rest (before <> after) ((storedRow, candidateKey) : pairs) unpaired
        (_, []) -> go rest candidates pairs (storedRow : unpaired)
