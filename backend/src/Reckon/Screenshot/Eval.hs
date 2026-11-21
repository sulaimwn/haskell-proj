-- | Scoring screenshot extraction against hand-labelled screenshots
-- (Phase 5). @reckon-cli eval-screenshots DIR@.
--
-- DIR holds pairs: @name.png@ (or .jpg, .jpeg, .webp, .gif) and
-- @name.json@, a label in this shape:
--
-- > { "takenOn": "2026-02-20", "extraction": { "accountLabel": ..., "transactions": [...] } }
--
-- where @extraction@ is exactly what the model is asked to return, so a
-- label can start as the model's own answer and be corrected by hand. The
-- real screenshots and labels belong in @private/eval@ and are never
-- committed. This module is the only place that reads them, and it prints
-- scores, never their contents.
module Reckon.Screenshot.Eval
  ( evaluateScreenshots
  ) where

import Control.Monad (forM)
import Data.Aeson (Value (..), eitherDecodeStrict)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (Day)
import Data.Time.Format.ISO8601 (iso8601ParseM)
import Reckon.Anthropic (Extractor, ImageInput (..), detectMediaType, renderClientError)
import Reckon.Screenshot.Extraction (ExtractedScreenshot (..), parseExtraction, renderExtractionError)
import Reckon.Screenshot.Score (Score (..), renderScore, scoreExtraction)
import System.Directory (doesFileExist, listDirectory)
import System.FilePath (replaceExtension, takeExtension, (</>))

-- | Runs every labelled screenshot in the directory through the extractor
-- and reports the scores, then the total.
evaluateScreenshots :: Extractor -> FilePath -> IO Text
evaluateScreenshots extract directory = do
  names <- sort . filter isImage <$> listDirectory directory
  results <- forM names $ \name -> do
    let labelPath = replaceExtension (directory </> name) "json"
    hasLabel <- doesFileExist labelPath
    if not hasLabel
      then pure (Left (Text.pack name <> ": no label file (" <> Text.pack (replaceExtension name "json") <> "), skipped\n"))
      else evaluateOne extract (Text.pack name) (directory </> name) labelPath
  let scores = [score | Right score <- results]
      combined = foldr addScores Nothing scores
  pure $
    Text.concat [either id (const "") result | result <- results]
      <> Text.concat [renderScore (Text.pack name) score | (name, Right score) <- zip names results]
      <> maybe "No labelled screenshots were scored.\n" (renderScore "ALL") combined
  where
    isImage name = takeExtension name `elem` [".png", ".jpg", ".jpeg", ".webp", ".gif"]
    addScores score = \case
      Nothing -> Just score
      Just total ->
        Just
          total
            { expectedCount = total.expectedCount + score.expectedCount
            , extractedCount = total.extractedCount + score.extractedCount
            , foundCount = total.foundCount + score.foundCount
            , missed = total.missed <> score.missed
            , invented = total.invented <> score.invented
            , descriptionsRight = total.descriptionsRight + score.descriptionsRight
            , sectionsRight = total.sectionsRight + score.sectionsRight
            , balancesRight = total.balancesRight + score.balancesRight
            }

evaluateOne :: Extractor -> Text -> FilePath -> FilePath -> IO (Either Text Score)
evaluateOne extract name imagePath labelPath = do
  imageBytes <- ByteString.readFile imagePath
  labelBytes <- ByteString.readFile labelPath
  case (detectMediaType imageBytes, readLabel labelBytes) of
    (Nothing, _) -> pure (Left (name <> ": not an image, skipped\n"))
    (_, Left problem) -> pure (Left (name <> ": bad label: " <> problem <> "\n"))
    (Just mediaType, Right (takenOn, expected)) -> do
      reply <- extract ImageInput {mediaType, bytes = imageBytes}
      pure $ case reply of
        Left problem -> Left (name <> ": " <> renderClientError problem <> "\n")
        Right replyBytes -> case parseExtraction takenOn replyBytes of
          Left problems -> Left (name <> ": the reading was unusable:\n" <> Text.concat ["  " <> renderExtractionError problem <> "\n" | problem <- problems])
          Right got -> Right (scoreExtraction expected.rows got.rows)

readLabel :: ByteString.ByteString -> Either Text (Day, ExtractedScreenshot)
readLabel bytes = do
  value <- either (Left . Text.pack) Right (eitherDecodeStrict bytes)
  fields <- case value of
    Object found -> Right found
    _ -> Left "the label isn't a JSON object"
  takenText <- case KeyMap.lookup "takenOn" fields of
    Just (String text) -> Right (Text.unpack text)
    _ -> Left "missing takenOn (YYYY-MM-DD)"
  takenOn <- maybe (Left "takenOn isn't a date") Right (iso8601ParseM takenText)
  extraction <- maybe (Left "missing extraction") Right (KeyMap.lookup "extraction" fields)
  labelled <- either (Left . Text.intercalate "; " . map renderExtractionError) Right (parseExtraction takenOn (LazyByteString.toStrict (Aeson.encode extraction)))
  pure (takenOn, labelled)
