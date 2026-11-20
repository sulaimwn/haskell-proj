-- | How a provisional (screenshot-read) row stopped being provisional
-- (DECISIONS D058). Stored as text in @provisional_resolutions.kind@.
module Reckon.Screenshot.Resolution
  ( ResolutionKind (..)
  , resolutionKindText
  ) where

import Data.Text (Text)
import Data.Text qualified as Text
import Database.Persist.Sql (PersistField (..), PersistFieldSql (..), PersistValue (..), SqlType (..))

data ResolutionKind
  = -- | A bank CSV row for the same transaction arrived.
    ConfirmedByCsv
  | -- | The CSV row was already there, so nothing was ever posted.
    AlreadyInCsv
  | -- | A later screenshot shows the pending row posted.
    SupersededByScreenshot
  | -- | The owner said it never posted (a released hold).
    Released
  deriving stock (Show, Eq, Ord, Enum, Bounded)

resolutionKindText :: ResolutionKind -> Text
resolutionKindText = \case
  ConfirmedByCsv -> "confirmed_by_csv"
  AlreadyInCsv -> "already_in_csv"
  SupersededByScreenshot -> "superseded_by_screenshot"
  Released -> "released"

instance PersistField ResolutionKind where
  toPersistValue = PersistText . resolutionKindText
  fromPersistValue = \case
    PersistText text ->
      maybe
        (Left ("unknown provisional_resolutions.kind: " <> text))
        Right
        (lookup text [(resolutionKindText kind, kind) | kind <- [minBound .. maxBound]])
    other -> Left ("provisional_resolutions.kind: expected text, got " <> Text.pack (show other))

instance PersistFieldSql ResolutionKind where
  sqlType _ = SqlString
