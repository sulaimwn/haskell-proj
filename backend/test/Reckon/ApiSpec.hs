module Reckon.ApiSpec (spec) where

import Control.Monad (forM_)
import Data.Aeson (FromJSON, ToJSON, Value, decode, encode, object)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Base64 qualified as Base64
import Data.ByteString.Lazy qualified as LazyByteString
import Data.List (find, sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Network.HTTP.Client qualified as Client
import Network.HTTP.Types (Header, Method, Status, status200, status400, status403, status404, status415, status422, status502, status503)
import Network.Wai (Application, Request (..), defaultRequest, responseLBS)
import Network.Wai.Handler.Warp (testWithApplication)
import Network.Wai.Test (SResponse (..), SRequest (..), runSession, setPath, srequest)
import Reckon.Anthropic (ClientError (..), ScreenshotReading (..))
import Reckon.Api.Types
import Reckon.App (AppEnv (..))
import Reckon.Security (hostAllowed, jsonOnlyWrites)
import Reckon.Server (application)
import Reckon.ScenarioSupport
import Reckon.TestSupport
import Test.Hspec

-- * Talking to the application without a network

type Response = (Status, LazyByteString.ByteString)

call :: AppEnv -> Method -> ByteString -> [Header] -> LazyByteString.ByteString -> IO SResponse
call env method path headers body =
  runSession
    (srequest SRequest {simpleRequest = setPath defaultRequest {requestMethod = method, requestHeaders = headers} path, simpleRequestBody = body})
    (application env)

getResponse :: AppEnv -> ByteString -> IO Response
getResponse env path = do
  response <- call env "GET" path [] ""
  pure (simpleStatus response, simpleBody response)

postResponse :: (ToJSON a) => AppEnv -> ByteString -> a -> IO Response
postResponse env path payload = do
  response <- call env "POST" path [("Content-Type", "application/json")] (encode payload)
  pure (simpleStatus response, simpleBody response)

emptyBody :: Value
emptyBody = object []

-- | A response that succeeded, decoded.
succeeded :: (FromJSON a) => Response -> IO a
succeeded (status, body) = do
  status `shouldBe` status200
  maybe (expectationFailure ("couldn't decode: " <> show body) >> fail "undecodable") pure (decode body)

-- | A response that was refused with this status, and the reason it gave.
refusedWith :: Status -> Response -> IO Text
refusedWith expected (status, body) = do
  status `shouldBe` expected
  case decode body of
    Just ApiProblem {problem} -> pure problem
    Nothing -> expectationFailure ("not an ApiProblem: " <> show body) >> fail "no problem"

-- | An uploaded file for a request.
uploaded :: Text -> ByteString -> UploadedFile
uploaded fileName content = UploadedFile {fileName, contentBase64 = Text.decodeUtf8 (Base64.encode content)}

importFixtureOverHttp :: AppEnv -> Scenario -> FilePath -> IO ActionResult
importFixtureOverHttp env scenario path = do
  csv <- ByteString.readFile path
  postResponse env "/api/imports/csv" ImportCsvRequest {file = uploaded "export.csv" (forScenario scenario (Text.decodeUtf8 csv))} >>= succeeded

-- | The account's summary as of the end of the scenario's year (its dates are
-- all in that year, which is in the future).
accountFor :: AppEnv -> Scenario -> Text -> IO AccountSummary
accountFor env scenario last4 = do
  accounts <- getResponse env (ByteString.concat ["/api/accounts?asOf=", Text.encodeUtf8 (Text.pack (show (on scenario 12 31)))]) >>= succeeded @[AccountSummary]
  case find (\account -> account.last4 == last4) accounts of
    Just account -> pure account
    Nothing -> expectationFailure ("no account ending " <> Text.unpack last4) >> fail "no account"

spec :: Spec
spec = beforeAll makeTestEnv $ do
  describe "keeping the API private" $ do
    it "answers a request for another host name with 403, and one for localhost normally" $ \env -> do
      other <- call env "GET" "/api/health" [("Host", "evil.example.com")] ""
      simpleStatus other `shouldBe` status403
      local <- call env "GET" "/api/health" [("Host", "localhost:5173")] ""
      simpleStatus local `shouldBe` status200

    it "knows the names a browser uses for this machine, with or without a port, and nothing that merely contains them" $ \_ -> do
      let defaults = ["localhost", "127.0.0.1", "[::1]"]
          allowed = hostAllowed defaults . Just
      allowed "localhost" `shouldBe` True
      allowed "LOCALHOST:5173" `shouldBe` True
      allowed "127.0.0.1:8080" `shouldBe` True
      allowed "[::1]:8080" `shouldBe` True
      allowed "localhost.evil.example.com" `shouldBe` False
      allowed "evil.example.com:80" `shouldBe` False
      allowed "127.0.0.1.nip.io" `shouldBe` False
      allowed "" `shouldBe` False
      hostAllowed defaults Nothing `shouldBe` True

    it "enforces that over a real socket, where Warp (not the test) builds the request" $ \env ->
      testWithApplication (pure (application env)) $ \port -> do
        manager <- Client.newManager Client.defaultManagerSettings
        request <- Client.parseRequest ("http://127.0.0.1:" <> show port <> "/api/health")
        rebound <- Client.httpLbs request {Client.requestHeaders = [("Host", "evil.example.com")]} manager
        Client.responseStatus rebound `shouldBe` status403
        local <- Client.httpLbs request {Client.requestHeaders = [("Host", "localhost")]} manager
        Client.responseStatus local `shouldBe` status200

    it "refuses a write that isn't JSON even on a route that declares no body, which Servant alone would let through" $ \_ -> do
      let bodyless :: Application
          bodyless _ respond = respond (responseLBS status200 [] "changed something")
          send method headers = runSession (srequest SRequest {simpleRequest = setPath defaultRequest {requestMethod = method, requestHeaders = headers} "/anything", simpleRequestBody = ""}) (jsonOnlyWrites bodyless)
      form <- send "POST" [("Content-Type", "application/x-www-form-urlencoded")]
      simpleStatus form `shouldBe` status415
      plain <- send "POST" [("Content-Type", "text/plain")]
      simpleStatus plain `shouldBe` status415
      untyped <- send "DELETE" []
      simpleStatus untyped `shouldBe` status415
      json <- send "POST" [("Content-Type", "application/json; charset=utf-8")]
      simpleStatus json `shouldBe` status200
      reading <- send "GET" []
      simpleStatus reading `shouldBe` status200

    it "refuses a write that isn't JSON (what a cross-site form sends)" $ \env -> do
      form <- call env "POST" "/api/post" [("Content-Type", "text/plain")] "{}"
      simpleStatus form `shouldBe` status415
      noType <- call env "POST" "/api/post" [] "{}"
      simpleStatus noType `shouldBe` status415

  describe "the whole loop over HTTP" $
    it "imports, posts, shows what needs review, settles it, records a statement and reconciles" $ \env -> do
      scenario <- newScenario env
      imported <- importFixtureOverHttp env scenario "../fixtures/rbc/february-two-accounts.csv"
      imported.message `shouldSatisfy` (not . Text.null)

      beforePosting <- accountFor env scenario scenario.chequingLast4
      beforePosting.unpostedRows `shouldBe` 8
      beforePosting.latestCheckpoint `shouldBe` Nothing

      posted <- postResponse env "/api/post" emptyBody >>= succeeded @ActionResult
      Text.unpack (Text.unlines (posted.message : posted.details)) `shouldContain` "Left for review"

      -- The three rows it wouldn't decide are in the review queue, with their reasons.
      queue <- getResponse env "/api/review" >>= succeeded @ReviewQueue
      let mine = [row | row <- queue.unposted, Text.pack (show scenario.year) `Text.isPrefixOf` row.date]
      length mine `shouldBe` 3
      map (.reason) mine `shouldBe` replicate 3 ReviewAmbiguousPair

      -- Settle them the way the CLI's post-row does: both legs of the
      -- transfer to the clearing account, the return to refunds.
      forM_ (zip mine ["asset:clearing", "asset:clearing", "income:refunds"]) $ \(row, account) ->
        postResponse env (ByteString.concat ["/api/rows/", Text.encodeUtf8 (Text.pack (show row.rowId)), "/settle"]) SettleRequest {account} >>= succeeded @ActionResult

      _ <-
        postResponse env (ByteString.concat ["/api/accounts/", Text.encodeUtf8 scenario.chequingLast4, "/opening-balance"]) BalanceRequest {date = Text.pack (show (on scenario 1 31)), balanceCents = 100000}
          >>= succeeded @ActionResult
      checkpoint <-
        postResponse env (ByteString.concat ["/api/accounts/", Text.encodeUtf8 scenario.chequingLast4, "/checkpoints"]) BalanceRequest {date = Text.pack (show (on scenario 2 28)), balanceCents = 155243}
          >>= succeeded @ActionResult
      Text.unpack (Text.unlines (checkpoint.message : checkpoint.details)) `shouldContain` "RECONCILED"

      afterReconciling <- accountFor env scenario scenario.chequingLast4
      afterReconciling.unpostedRows `shouldBe` 0
      fmap (.state) afterReconciling.latestCheckpoint `shouldBe` Just ReconciliationReconciled
      fmap (.explanation) afterReconciling.latestCheckpoint `shouldBe` Just []
      afterReconciling.balanceCents `shouldBe` 155243

      -- ...and the same statement date with a wrong balance is a gap, in words.
      let gapDate = Text.pack (show (on scenario 2 27))
      _ <- postResponse env (ByteString.concat ["/api/accounts/", Text.encodeUtf8 scenario.chequingLast4, "/checkpoints"]) BalanceRequest {date = gapDate, balanceCents = 150000} >>= succeeded @ActionResult
      latest <- accountFor env scenario scenario.chequingLast4
      -- The latest checkpoint by date is still the 28th.
      fmap (.asOf) latest.latestCheckpoint `shouldBe` Just (Text.pack (show (on scenario 2 28)))

  describe "transactions" $
    it "lists an account's entries as the bank shows them, with their categories, and filters them" $ \env -> do
      scenario <- newScenario env
      _ <- importFixtureOverHttp env scenario "../fixtures/rbc/february-two-accounts.csv"
      _ <- postResponse env "/api/post" emptyBody >>= succeeded @ActionResult
      let path suffix = ByteString.concat ["/api/accounts/", Text.encodeUtf8 scenario.chequingLast4, "/transactions", suffix]

      everything <- getResponse env (path "") >>= succeeded @[TransactionView]
      -- 9 rows, 3 of them left unposted, plus none reversed: 6 posted.
      length everything `shouldSatisfy` (>= 6)
      map (.date) everything `shouldBe` reverse (sortedDates everything)
      let payroll = [t | t <- everything, "PAYROLL" `Text.isInfixOf` t.description]
      map (.amountCents) payroll `shouldBe` [150000]
      map (.source) payroll `shouldBe` [SourceCsv]
      map (map (.account) . (.counterLines)) payroll `shouldBe` [["income:uncategorized"]]

      searched <- getResponse env (path "?q=hydro") >>= succeeded @[TransactionView]
      map (.amountCents) searched `shouldBe` [-8540]

      ranged <- getResponse env (path (ByteString.concat ["?from=", Text.encodeUtf8 (Text.pack (show (on scenario 2 9))), "&to=", Text.encodeUtf8 (Text.pack (show (on scenario 2 12)))])) >>= succeeded @[TransactionView]
      map (.amountCents) ranged `shouldBe` [-8540, -12000]

      limited <- getResponse env (path "?limit=2") >>= succeeded @[TransactionView]
      length limited `shouldBe` 2

  describe "sharing, over HTTP" $
    it "splits a dinner, shows only my share as spending, and tracks what each friend owes" $ \env -> do
      scenario <- newScenario env
      _ <- importFixtureOverHttp env scenario "../fixtures/rbc/shared-dinner.csv"
      let names = ["alex-" <> Text.toLower scenario.tag, "sam-" <> Text.toLower scenario.tag]
      forM_ (zip names ["ALEX EXAMPLE" <> scenario.tag, "SAM EXAMPLE" <> scenario.tag]) $ \(name, matchText) ->
        postResponse env "/api/people" AddPersonRequest {name, matchText} >>= succeeded @ActionResult
      _ <- postResponse env "/api/post" emptyBody >>= succeeded @ActionResult

      -- Find the dinner (a $120 payment) among the account's entries and split it three ways.
      transactions <- getResponse env (ByteString.concat ["/api/accounts/", Text.encodeUtf8 scenario.chequingLast4, "/transactions"]) >>= succeeded @[TransactionView]
      dinner <- case find (\t -> t.amountCents == -12000) transactions of
        Just found | Just row <- found.rowId -> pure row
        _ -> expectationFailure "no dinner" >> fail "no dinner"
      _ <- postResponse env (ByteString.concat ["/api/rows/", Text.encodeUtf8 (Text.pack (show dinner)), "/split"]) SplitRequest {category = "expense:food", equalWith = Just names, shares = Nothing} >>= succeeded @ActionResult

      let year = Text.pack (show scenario.year)
      months <- getResponse env (ByteString.concat ["/api/spending?from=", Text.encodeUtf8 year, "-01-01&to=", Text.encodeUtf8 year, "-12-31"]) >>= succeeded @[SpendingMonth]
      -- March: the $100 grocery run, and only my $40 of the $120 dinner.
      map (.month) months `shouldBe` [year <> "-03"]
      map (\m -> map (\l -> (l.account, l.cents)) m.categories) months `shouldBe` [[("expense:uncategorized", 10000), ("expense:food", 4000)]]
      map (.totalCents) months `shouldBe` [14000]

      receivables <- getResponse env (ByteString.concat ["/api/receivables?asOf=", Text.encodeUtf8 year, "-12-31"]) >>= succeeded @ReceivablesResponse
      [(person.name, person.owedCents) | person <- receivables.people, person.name `elem` names] `shouldBe` [(n, 4000) | n <- names]

      -- The two repayments are suggested in the review queue, not posted as income.
      queue <- getResponse env "/api/review" >>= succeeded @ReviewQueue
      let suggestions = [row | row <- queue.unposted, row.reason == ReviewPossibleRepayment, any (`elem` names) row.people]
      length suggestions `shouldBe` 2

      -- Splitting the same row twice, or with nonsense, says why.
      problem <- postResponse env (ByteString.concat ["/api/rows/", Text.encodeUtf8 (Text.pack (show dinner)), "/split"]) SplitRequest {category = "expense:food", equalWith = Just ["nobody"], shares = Nothing} >>= refusedWith status422
      problem `shouldSatisfy` Text.isInfixOf "no one called nobody"
      both <- postResponse env (ByteString.concat ["/api/rows/", Text.encodeUtf8 (Text.pack (show dinner)), "/split"]) SplitRequest {category = "expense:food", equalWith = Just names, shares = Just []} >>= refusedWith status400
      both `shouldSatisfy` Text.isInfixOf "exactly one"

  describe "reading screenshots over HTTP" $ do
    it "says why when no API key is configured" $ \env -> do
      scenario <- newScenario env
      _ <- importFixtureOverHttp env scenario "../fixtures/rbc/shared-dinner.csv"
      reason <- postResponse env "/api/imports/screenshots" ImportScreenshotsRequest {last4 = scenario.chequingLast4, takenOn = Nothing, files = [uploaded "a.png" "\137PNG..."]} >>= refusedWith status503
      reason `shouldSatisfy` Text.isInfixOf "can't be read"

    it "reads them with the configured model, posts them provisionally, and shows them for review" $ \env -> do
      scenario <- newScenario env
      _ <- importFixtureOverHttp env scenario "../fixtures/rbc/shared-dinner.csv"
      reply <- ByteString.readFile "../fixtures/screenshots/hold-pending.json"
      let reading = ReadingAvailable "test-model" (\_ -> pure (Right reply))
          withReading = env {screenshotReading = reading}
          png = "\137PNG\r\n\26\nimage for " <> Text.encodeUtf8 scenario.tag
      result <-
        postResponse withReading "/api/imports/screenshots" ImportScreenshotsRequest {last4 = scenario.chequingLast4, takenOn = Just (Text.pack (show (on scenario 3 1))), files = [uploaded "monday.png" png]}
          >>= succeeded @ActionResult
      Text.unpack (Text.unlines (result.message : result.details)) `shouldContain` "posted provisionally"
      queue <- getResponse env "/api/review" >>= succeeded @ReviewQueue
      length [row | row <- queue.provisional, row.description == "SHELL GAS STATION", row.pending] `shouldSatisfy` (>= 1)

      -- A failing API is a bad gateway, not our fault.
      let failing = env {screenshotReading = ReadingAvailable "test-model" (\_ -> pure (Left (ApiError 500 "api_error" "overloaded")))}
      status <- fst <$> postResponse failing "/api/imports/screenshots" ImportScreenshotsRequest {last4 = scenario.chequingLast4, takenOn = Nothing, files = [uploaded "other.png" ("\137PNG other " <> Text.encodeUtf8 scenario.tag)]}
      status `shouldBe` status502

  describe "refusals" $ do
    it "404s an account or row that doesn't exist, 400s what isn't a date or base64" $ \env -> do
      (fst <$> getResponse env "/api/accounts/9999/transactions") `shouldReturn` status404
      (fst <$> getResponse env "/api/accounts/abc/transactions") `shouldReturn` status400
      (fst <$> getResponse env "/api/spending?from=yesterday") `shouldReturn` status400
      postResponse env "/api/rows/0/settle" SettleRequest {account = "expense:food"} >>= void' (refusedWith status404)
      postResponse env "/api/provisional/0/release" emptyBody >>= void' (refusedWith status404)
      broken <- postResponse env "/api/imports/csv" ImportCsvRequest {file = UploadedFile {fileName = "x.csv", contentBase64 = "!!! not base64 !!!"}} >>= refusedWith status400
      broken `shouldSatisfy` Text.isInfixOf "base64"

    it "422s a file the importer rejects, listing the problems" $ \env -> do
      bad <- ByteString.readFile "../fixtures/rbc/malformed.csv"
      problem <- postResponse env "/api/imports/csv" ImportCsvRequest {file = uploaded "bad.csv" bad} >>= refusedWith status422
      Text.toLower problem `shouldSatisfy` Text.isInfixOf "line"

    it "422s moving one leg of a transfer, and says why" $ \env -> do
      scenario <- newScenario env
      _ <- importFixtureOverHttp env scenario "../fixtures/rbc/february-two-accounts.csv"
      _ <- postResponse env "/api/post" emptyBody >>= succeeded @ActionResult
      transactions <- getResponse env (ByteString.concat ["/api/accounts/", Text.encodeUtf8 scenario.chequingLast4, "/transactions"]) >>= succeeded @[TransactionView]
      leg <- case find (\t -> map (.account) t.counterLines == ["asset:clearing"] && t.amountCents == -50000) transactions of
        Just found | Just row <- found.rowId -> pure row
        _ -> expectationFailure "no transfer leg" >> fail "no transfer leg"
      problem <- postResponse env (ByteString.concat ["/api/rows/", Text.encodeUtf8 (Text.pack (show leg)), "/recategorize"]) SettleRequest {account = "expense:food"} >>= refusedWith status422
      problem `shouldSatisfy` Text.isInfixOf "one leg of a transfer"

    it "lists the ledger accounts, including the ones posting created" $ \env -> do
      accounts <- getResponse env "/api/ledger-accounts" >>= succeeded @[LedgerAccountView]
      map (.name) accounts `shouldSatisfy` elem "asset:clearing"
      map (.name) accounts `shouldSatisfy` (\names -> names == sort names)
  where
    sortedDates transactions = sort (map (.date) transactions)
    void' check response = () <$ check response
