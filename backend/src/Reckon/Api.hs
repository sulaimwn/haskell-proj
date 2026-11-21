-- | The HTTP API, described as a type.
--
-- Servant reads this type to route requests, decode inputs and encode
-- outputs, so a handler that returns the wrong type does not compile. Routes
-- are grouped in a record ('Routes') rather than chained with @:<|>@, so each
-- endpoint has a name and handlers are matched to routes by field name.
--
-- Reads are @GET@. Everything that changes anything is a @POST@ with a JSON
-- body (enforced by "Reckon.Security"), and answers with an 'ActionResult'
-- saying what happened, or an 'ApiProblem' with a 4xx or 5xx status.
module Reckon.Api
  ( Api
  , Routes (..)
  ) where

import Data.Aeson (Value)
import Data.Int (Int64)
import Data.Text (Text)
import GHC.Generics (Generic)
import Reckon.Api.Types
import Servant.API

-- | Everything lives under @/api@, so the frontend dev server only has to
-- proxy one path prefix to the backend.
type Api = "api" :> NamedRoutes Routes

data Routes mode = Routes
  { health :: mode :- "health" :> Get '[JSON] HealthResponse
  -- ^ Liveness plus a database round trip. Used by the frontend status badge.
  , accounts :: mode :- "accounts" :> QueryParam "asOf" Text :> Get '[JSON] [AccountSummary]
  -- ^ Every bank account: balance (as of a date, today by default), what's
  -- waiting, and reconciliation status.
  , transactions ::
      mode
        :- "accounts"
          :> Capture "last4" Text
          :> "transactions"
          :> QueryParam "from" Text
          :> QueryParam "to" Text
          :> QueryParam "q" Text
          :> QueryParam "limit" Int
          :> Get '[JSON] [TransactionView]
  -- ^ An account's entries as the bank shows them, newest first.
  , spending :: mode :- "spending" :> QueryParam "from" Text :> QueryParam "to" Text :> Get '[JSON] [SpendingMonth]
  -- ^ Month by month, the owner's own share only.
  , receivables :: mode :- "receivables" :> QueryParam "asOf" Text :> Get '[JSON] ReceivablesResponse
  , review :: mode :- "review" :> Get '[JSON] ReviewQueue
  , ledgerAccounts :: mode :- "ledger-accounts" :> Get '[JSON] [LedgerAccountView]
  , importCsv :: mode :- "imports" :> "csv" :> ReqBody '[JSON] ImportCsvRequest :> Post '[JSON] ActionResult
  , importScreenshots :: mode :- "imports" :> "screenshots" :> ReqBody '[JSON] ImportScreenshotsRequest :> Post '[JSON] ActionResult
  , postRows :: mode :- "post" :> ReqBody '[JSON] Value :> Post '[JSON] ActionResult
  -- ^ Post every imported row that isn't posted. The body is ignored (send @{}@).
  , settleRow :: mode :- "rows" :> Capture "id" Int64 :> "settle" :> ReqBody '[JSON] SettleRequest :> Post '[JSON] ActionResult
  , recategorizeRow :: mode :- "rows" :> Capture "id" Int64 :> "recategorize" :> ReqBody '[JSON] SettleRequest :> Post '[JSON] ActionResult
  , splitRow :: mode :- "rows" :> Capture "id" Int64 :> "split" :> ReqBody '[JSON] SplitRequest :> Post '[JSON] ActionResult
  , releaseProvisional :: mode :- "provisional" :> Capture "id" Int64 :> "release" :> ReqBody '[JSON] Value :> Post '[JSON] ActionResult
  , addPerson :: mode :- "people" :> ReqBody '[JSON] AddPersonRequest :> Post '[JSON] ActionResult
  , addRule :: mode :- "rules" :> ReqBody '[JSON] AddRuleRequest :> Post '[JSON] ActionResult
  , setOpeningBalance :: mode :- "accounts" :> Capture "last4" Text :> "opening-balance" :> ReqBody '[JSON] BalanceRequest :> Post '[JSON] ActionResult
  , addCheckpoint :: mode :- "accounts" :> Capture "last4" Text :> "checkpoints" :> ReqBody '[JSON] BalanceRequest :> Post '[JSON] ActionResult
  }
  deriving stock (Generic)
