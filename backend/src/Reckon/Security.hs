-- | Keeping the API private (Phase 6, DECISIONS D061).
--
-- reckon serves real financial data over HTTP with no login. It is meant to
-- run on one person's machine, and three things keep it that way:
--
-- 1. It listens on the loopback address only ("Reckon.Config").
-- 2. 'hostGuard' (this module) refuses any request whose @Host@ header isn't
--    on a short list. Without it, a web page you visit could use /DNS
--    rebinding/ (a name that first resolves to its own server, then to
--    127.0.0.1) to have your browser read the API as if it were that page.
-- 3. Every request that changes anything must be JSON ("Reckon.Server"
--    only accepts @application/json@), which a page on another site can't
--    send to us without a CORS preflight, which we never answer.
module Reckon.Security
  ( hostGuard
  , hostAllowed
  , jsonOnlyWrites
  ) where

import Control.Applicative ((<|>))
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Network.HTTP.Types (hContentType, hHost, status403, status415)
import Network.Wai (Middleware, requestHeaderHost, requestHeaders, requestMethod, responseLBS)

-- | A middleware that answers 403 to a request addressed to a host that
-- isn't allowed. Warp fills in 'requestHeaderHost' from the @Host@ header;
-- the header itself is checked too, so a request built by hand (as the
-- in-process tests do) is judged the same way.
hostGuard :: [Text] -> Middleware
hostGuard allowed application request respond
  | hostAllowed allowed (requestHeaderHost request <|> lookup hHost (requestHeaders request)) = application request respond
  | otherwise =
      respond
        ( responseLBS
            status403
            [(hContentType, "application/json")]
            "{\"problem\":\"This host name isn't allowed. Open reckon at http://localhost, or list the name in RECKON_ALLOWED_HOSTS.\"}"
        )

-- | Is a request with this @Host@ header (name and optional port) allowed?
-- A missing header is allowed: every real browser sends one, and a
-- cross-site page can't remove it.
hostAllowed :: [Text] -> Maybe ByteString -> Bool
hostAllowed _ Nothing = True
hostAllowed allowed (Just header) = Text.toLower (hostName (Text.decodeUtf8Lenient header)) `elem` map Text.toLower allowed

-- | The name part of @name@ or @name:port@, keeping the brackets of an IPv6
-- address (@[::1]:8080@).
hostName :: Text -> Text
hostName header
  | "[" `Text.isPrefixOf` header = Text.takeWhile (/= ']') header <> "]"
  | otherwise = Text.takeWhile (/= ':') header

-- | A middleware that answers 415 to anything but a read that doesn't
-- declare a JSON body. Servant already does this for routes that declare a
-- @ReqBody@; this covers the rest (a future write route with no body, which
-- Servant would run whatever the request said it was). Browsers send a \"simple\" cross-site POST (a form, or
-- @text/plain@) without asking permission first; refusing every write that
-- isn't @application/json@ means only a request that needed a CORS
-- preflight, which this server never grants, can change anything.
jsonOnlyWrites :: Middleware
jsonOnlyWrites application request respond
  | requestMethod request `elem` ["GET", "HEAD", "OPTIONS"] = application request respond
  | isJson (lookup hContentType (requestHeaders request)) = application request respond
  | otherwise =
      respond
        ( responseLBS
            status415
            [(hContentType, "application/json")]
            "{\"problem\":\"Requests that change something must be sent as application/json.\"}"
        )
  where
    isJson = \case
      Just value -> "application/json" `ByteString.isPrefixOf` value
      Nothing -> False
