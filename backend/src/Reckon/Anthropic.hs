-- | A small client for the Anthropic Messages API, used to read screenshots
-- (Phase 5, DECISIONS D054).
--
-- There is no official Haskell SDK, so this is the raw HTTP API: one
-- request shape (an image plus instructions, with the response constrained
-- to a JSON Schema) and one response shape. The request builder and the
-- response parser are pure and tested; only 'anthropicExtractor' touches
-- the network, and tests never reach it (they use a fake 'Extractor' or a
-- local stub server).
--
-- The API key comes from the environment, is only ever sent to the API in a
-- request header, and has no way to be printed: 'ApiKey' has a hand-written
-- 'Show' instance, and error messages are built from the response, never
-- from the request.
module Reckon.Anthropic
  ( -- * Configuration
    ApiKey
  , mkApiKey
  , AnthropicConfig (..)
  , loadAnthropicConfig
  , defaultModel

    -- * Images
  , ImageInput (..)
  , detectMediaType

    -- * Reading a screenshot
  , Extractor
  , ClientError (..)
  , renderClientError
  , anthropicExtractor

    -- * Pure parts (exported for tests)
  , buildRequestBody
  , readResponse
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, try)
import Data.Aeson (Value (..), encode, object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Base64 qualified as Base64
import Data.ByteString.Char8 qualified as ByteString.Char8
import Data.ByteString.Lazy qualified as LazyByteString
import Data.CaseInsensitive qualified as CI
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Vector qualified as Vector
import Network.HTTP.Client
  ( HttpException (..)
  , Manager
  , Request (..)
  , RequestBody (..)
  , httpLbs
  , parseRequest
  , responseBody
  , responseStatus
  , responseTimeoutMicro
  )
import Network.HTTP.Client.TLS (newTlsManager)
import Network.HTTP.Types (statusCode)
import Reckon.Screenshot.Extraction (extractionInstructions, extractionSchema)
import System.Environment (lookupEnv)

-- | The secret. Its 'Show' instance never reveals it.
newtype ApiKey = ApiKey ByteString

instance Show ApiKey where
  show _ = "ApiKey <redacted>"

mkApiKey :: Text -> Maybe ApiKey
mkApiKey text
  | Text.null (Text.strip text) = Nothing
  | otherwise = Just (ApiKey (Text.encodeUtf8 (Text.strip text)))

data AnthropicConfig = AnthropicConfig
  { apiKey :: ApiKey
  , model :: Text
  , baseUrl :: String
  -- ^ Without a trailing slash. Only changed to point at a test server.
  , retryDelayMicros :: Int
  -- ^ Pause before the first retry of a rate-limited or overloaded request
  -- (doubles on the second).
  }
  deriving stock (Show)

-- | Used when @ANTHROPIC_MODEL@ is not set.
defaultModel :: Text
defaultModel = "claude-opus-5-5"

-- | Reads @ANTHROPIC_API_KEY@ (required), @ANTHROPIC_MODEL@ and
-- @ANTHROPIC_BASE_URL@ (optional).
loadAnthropicConfig :: IO (Either Text AnthropicConfig)
loadAnthropicConfig = do
  maybeKey <- lookupEnv "ANTHROPIC_API_KEY"
  maybeModel <- lookupEnv "ANTHROPIC_MODEL"
  maybeBase <- lookupEnv "ANTHROPIC_BASE_URL"
  pure $ case maybeKey >>= mkApiKey . Text.pack of
    Nothing -> Left "ANTHROPIC_API_KEY is not set. Put it in .env (see .env.example). It is only ever used by the backend."
    Just apiKey ->
      Right
        AnthropicConfig
          { apiKey
          , model = maybe defaultModel Text.pack (nonEmpty maybeModel)
          , baseUrl = maybe "https://api.anthropic.com" (dropTrailingSlash) (nonEmpty maybeBase)
          , retryDelayMicros = 2_000_000
          }
  where
    nonEmpty value = case value of
      Just text | not (null text) -> Just text
      _ -> Nothing
    dropTrailingSlash = reverse . dropWhile (== '/') . reverse

data ImageInput = ImageInput
  { mediaType :: Text
  , bytes :: ByteString
  }
  deriving stock (Show, Eq)

-- | Recognized by the file's first bytes, not its name.
detectMediaType :: ByteString -> Maybe Text
detectMediaType content
  | ByteString.take 4 content == ByteString.pack [0x89, 0x50, 0x4E, 0x47] = Just "image/png"
  | ByteString.take 3 content == ByteString.pack [0xFF, 0xD8, 0xFF] = Just "image/jpeg"
  | ByteString.take 4 content == "GIF8" = Just "image/gif"
  | ByteString.take 4 content == "RIFF" && ByteString.take 4 (ByteString.drop 8 content) == "WEBP" = Just "image/webp"
  | otherwise = Nothing

-- | What a screenshot is turned into: the model's reply text, which is JSON
-- following 'extractionSchema'.
type Extractor = ImageInput -> IO (Either ClientError ByteString)

data ClientError
  = -- | The request never got a response (DNS, TLS, timeout, ...).
    Unreachable Text
  | -- | The API answered with an error status. Carries the status, the
    -- error type, and the message.
    ApiError Int Text Text
  | -- | The model declined to answer (@stop_reason: refusal@).
    Refused
  | -- | The reply was cut off by the token limit, so the JSON is incomplete.
    Truncated
  | UnexpectedResponse Text
  deriving stock (Show, Eq)

renderClientError :: ClientError -> Text
renderClientError = \case
  Unreachable reason -> "Couldn't reach the Anthropic API: " <> reason
  ApiError status errorType message -> "The Anthropic API returned " <> Text.pack (show status) <> " (" <> errorType <> "): " <> message
  Refused -> "The model declined to read this image."
  Truncated -> "The model's reply was cut off before it finished."
  UnexpectedResponse reason -> "Unexpected response from the Anthropic API: " <> reason

-- | The request body for one screenshot.
buildRequestBody :: Text -> ImageInput -> Value
buildRequestBody model image =
  object
    [ "model" .= model
    , "max_tokens" .= (16000 :: Int)
    , "system" .= extractionInstructions
    , "output_config" .= object ["format" .= object ["type" .= ("json_schema" :: Text), "schema" .= extractionSchema]]
    , "messages"
        .= [ object
               [ "role" .= ("user" :: Text)
               , "content"
                   .= [ object
                          [ "type" .= ("image" :: Text)
                          , "source"
                              .= object
                                [ "type" .= ("base64" :: Text)
                                , "media_type" .= image.mediaType
                                , "data" .= Text.decodeUtf8 (Base64.encode image.bytes)
                                ]
                          ]
                      , object ["type" .= ("text" :: Text), "text" .= ("Transcribe the transactions in this screenshot." :: Text)]
                      ]
               ]
           ]
    ]

-- | The model's reply text from a successful response body, or why there
-- isn't one.
readResponse :: Value -> Either ClientError ByteString
readResponse body = case body of
  Object fields -> case stringField "stop_reason" fields of
    Just "refusal" -> Left Refused
    Just "max_tokens" -> Left Truncated
    _ -> case [text | Object block <- blocks fields, stringField "type" block == Just "text", Just text <- [stringField "text" block]] of
      [] -> Left (UnexpectedResponse "no text in the reply")
      texts -> Right (Text.encodeUtf8 (Text.concat texts))
  _ -> Left (UnexpectedResponse "the body isn't a JSON object")
  where
    blocks fields = case KeyMap.lookup "content" fields of
      Just (Array items) -> Vector.toList items
      _ -> []
    stringField key fields = case KeyMap.lookup key fields of
      Just (String text) -> Just text
      _ -> Nothing

-- | The real thing. Makes one HTTP connection manager, then one request per
-- screenshot, retrying twice when the API says it is overloaded or rate
-- limiting.
anthropicExtractor :: AnthropicConfig -> IO Extractor
anthropicExtractor config = do
  manager <- newTlsManager
  pure (sendWithRetries manager config 2 . buildRequestBody config.model)

sendWithRetries :: Manager -> AnthropicConfig -> Int -> Value -> IO (Either ClientError ByteString)
sendWithRetries manager config retriesLeft body = do
  result <- sendOnce manager config body
  case result of
    Left (ApiError status _ _)
      | retriesLeft > 0 && status `elem` [429, 500, 502, 503, 529] -> do
          threadDelay (config.retryDelayMicros * (2 ^ (2 - retriesLeft)))
          sendWithRetries manager config (retriesLeft - 1) body
    _ -> pure result

sendOnce :: Manager -> AnthropicConfig -> Value -> IO (Either ClientError ByteString)
sendOnce manager config body = do
  parsed <- try (parseRequest (config.baseUrl <> "/v1/messages"))
  case parsed of
    Left (exception :: SomeException) -> pure (Left (Unreachable ("the base URL is invalid: " <> Text.pack (takeWhile (/= '\n') (show exception)))))
    Right baseRequest -> do
      let ApiKey key = config.apiKey
          request =
            baseRequest
              { method = "POST"
              , requestHeaders =
                  [ ("content-type", "application/json")
                  , ("x-api-key", key)
                  , ("anthropic-version", "2026-10-21")
                  ]
              , requestBody = RequestBodyLBS (encode body)
              , responseTimeout = responseTimeoutMicro (180 * 1_000_000)
              , -- Belt and braces: the request is never printed, but if it
                -- ever were, the key would be hidden.
                redactHeaders = Set.fromList [CI.mk (ByteString.Char8.pack "x-api-key")]
              }
      outcome <- try (httpLbs request manager)
      pure $ case outcome of
        -- Only the failure's /content/ is shown: an 'HttpException' also
        -- carries the whole request, headers included.
        Left (HttpExceptionRequest _ content) -> Left (Unreachable (Text.pack (takeWhile (/= '\n') (show content))))
        Left (InvalidUrlException _ reason) -> Left (Unreachable (Text.pack reason))
        Right response ->
          let status = statusCode (responseStatus response)
              responseText = LazyByteString.toStrict (responseBody response)
           in if status >= 200 && status < 300
                then case Aeson.eitherDecodeStrict responseText of
                  Left _ -> Left (UnexpectedResponse "the body isn't JSON")
                  Right value -> readResponse value
                else Left (apiErrorFrom status responseText)

apiErrorFrom :: Int -> ByteString -> ClientError
apiErrorFrom status responseText = case Aeson.decodeStrict responseText of
  Just (Object fields)
    | Just (Object err) <- KeyMap.lookup "error" fields ->
        ApiError status (stringOr "unknown" "type" err) (stringOr "(no message)" "message" err)
  _ -> ApiError status "unknown" "(the error body wasn't readable)"
  where
    stringOr fallback key fields = case KeyMap.lookup key fields of
      Just (String text) -> text
      _ -> fallback
