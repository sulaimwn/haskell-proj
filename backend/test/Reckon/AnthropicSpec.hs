module Reckon.AnthropicSpec (spec) where

import Data.Aeson (Value (..), decodeStrict, object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString.Base64 qualified as Base64
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef)
import Data.Maybe (fromJust)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Network.HTTP.Types (Header, Status, status200, status400, status429)
import Network.Wai (Application, requestHeaders, responseLBS, strictRequestBody)
import Network.Wai.Handler.Warp (testWithApplication)
import Reckon.Anthropic
import Test.Hspec

image :: ImageInput
image = ImageInput {mediaType = "image/png", bytes = "\137PNG fake image bytes"}

-- | A stub of the API: replies with the given responses in order (the last
-- one repeats), and records every request it gets.
withStubApi :: [(Status, LazyByteString.ByteString)] -> (Int -> IORef [([Header], ByteString)] -> IO a) -> IO a
withStubApi responses action = do
  received <- newIORef []
  remaining <- newIORef responses
  let application :: Application
      application request respond = do
        body <- strictRequestBody request
        modifyIORef' received (<> [(requestHeaders request, LazyByteString.toStrict body)])
        (status, reply) <- atomicModifyIORef' remaining (\rest -> case rest of [one] -> (rest, one); next : more -> (more, next); [] -> ([], (status200, "{}")))
        respond (responseLBS status [("content-type", "application/json")] reply)
  testWithApplication (pure application) (\port -> action port received)

requestFields :: KeyMap.KeyMap Value
requestFields = case buildRequestBody "claude-test-model" image of
  Object fields -> fields
  _ -> KeyMap.empty

configFor :: Int -> AnthropicConfig
configFor port =
  AnthropicConfig
    { apiKey = fromJust (mkApiKey "sk-test-key-12345")
    , model = "claude-test-model"
    , baseUrl = "http://127.0.0.1:" <> show port
    , retryDelayMicros = 1000
    }

okReply :: Text -> LazyByteString.ByteString
okReply text =
  Aeson.encode
    ( object
        [ "stop_reason" .= ("end_turn" :: Text)
        , "content" .= [object ["type" .= ("thinking" :: Text), "thinking" .= ("" :: Text)], object ["type" .= ("text" :: Text), "text" .= text]]
        ]
    )

spec :: Spec
spec = do
  describe "ApiKey" $
    it "never shows itself" $ do
      let config = configFor 1
      show config `shouldNotContain` "sk-test-key"
      show config `shouldContain` "<redacted>"
      mkApiKey "   " `shouldSatisfy` null

  describe "detectMediaType" $
    it "recognizes images by their first bytes, not their names" $ do
      detectMediaType "\137PNG\r\n\26\n....." `shouldBe` Just "image/png"
      detectMediaType "\255\216\255\224....JFIF" `shouldBe` Just "image/jpeg"
      detectMediaType "GIF89a..." `shouldBe` Just "image/gif"
      detectMediaType "RIFF\0\0\0\0WEBPVP8 " `shouldBe` Just "image/webp"
      detectMediaType "not an image" `shouldBe` Nothing
      detectMediaType "" `shouldBe` Nothing

  describe "buildRequestBody" $ do
    it "asks for JSON that follows the schema, about one image" $ do
      KeyMap.lookup "model" requestFields `shouldBe` Just (String "claude-test-model")
      let rendered = Text.unpack (Text.decodeUtf8 (LazyByteString.toStrict (Aeson.encode (Object requestFields))))
      rendered `shouldContain` "\"json_schema\""
      rendered `shouldContain` "\"media_type\":\"image/png\""
      rendered `shouldContain` Text.unpack (Text.decodeUtf8 (Base64.encode image.bytes))

    it "sets nothing the newer models reject" $
      mapM_ (\field -> KeyMap.member field requestFields `shouldBe` False) ["temperature", "top_p", "top_k", "thinking", "tool_choice"]

  describe "readResponse" $ do
    it "returns the text of the reply, ignoring thinking blocks" $
      readResponse (fromJust (decodeStrict (LazyByteString.toStrict (okReply "{\"a\":1}")))) `shouldBe` Right "{\"a\":1}"

    it "reports a refusal and a truncated reply" $ do
      readResponse (object ["stop_reason" .= ("refusal" :: Text), "content" .= ([] :: [Value])]) `shouldBe` Left Refused
      readResponse (object ["stop_reason" .= ("max_tokens" :: Text), "content" .= ([] :: [Value])]) `shouldBe` Left Truncated

    it "reports a reply with no text" $
      readResponse (object ["stop_reason" .= ("end_turn" :: Text), "content" .= ([] :: [Value])]) `shouldSatisfy` isUnexpected

  describe "anthropicExtractor, against a stub server" $ do
    it "sends the key and version headers and the request, and returns the reply text" $
      withStubApi [(status200, okReply "{\"accountLabel\":\"Chequing\"}")] $ \port received -> do
        extract <- anthropicExtractor (configFor port)
        extract image `shouldReturn` Right "{\"accountLabel\":\"Chequing\"}"
        [(headers, body)] <- readIORef received
        lookup "x-api-key" headers `shouldBe` Just "sk-test-key-12345"
        lookup "anthropic-version" headers `shouldBe` Just "2026-10-21"
        lookup "content-type" headers `shouldBe` Just "application/json"
        (decodeStrict body :: Maybe Value) `shouldBe` Just (buildRequestBody "claude-test-model" image)

    it "retries when the API is rate limiting, and then succeeds" $
      withStubApi [(status429, "{\"type\":\"error\",\"error\":{\"type\":\"rate_limit_error\",\"message\":\"slow down\"}}"), (status200, okReply "{}")] $ \port received -> do
        extract <- anthropicExtractor (configFor port)
        extract image `shouldReturn` Right "{}"
        length <$> readIORef received `shouldReturn` 2

    it "gives up after the retries, naming the API's error" $
      withStubApi [(status429, "{\"type\":\"error\",\"error\":{\"type\":\"rate_limit_error\",\"message\":\"slow down\"}}")] $ \port received -> do
        extract <- anthropicExtractor (configFor port)
        extract image `shouldReturn` Left (ApiError 429 "rate_limit_error" "slow down")
        length <$> readIORef received `shouldReturn` 3

    it "doesn't retry a request the API says is wrong" $
      withStubApi [(status400, "{\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"bad image\"}}")] $ \port received -> do
        extract <- anthropicExtractor (configFor port)
        extract image `shouldReturn` Left (ApiError 400 "invalid_request_error" "bad image")
        length <$> readIORef received `shouldReturn` 1

    it "reports an unreachable API without revealing the key" $ do
      extract <- anthropicExtractor (configFor 1)
      result <- extract image
      case result of
        Left problem@(Unreachable _) -> do
          Text.unpack (renderClientError problem) `shouldNotContain` "sk-test-key"
          show problem `shouldNotContain` "sk-test-key"
        other -> expectationFailure ("expected Unreachable, got " <> show other)

isUnexpected :: Either ClientError a -> Bool
isUnexpected = \case
  Left (UnexpectedResponse _) -> True
  _ -> False
