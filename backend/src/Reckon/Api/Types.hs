{-# LANGUAGE TemplateHaskell #-}

-- | Every type that crosses the HTTP boundary.
--
-- Each type gets its JSON instances and its TypeScript declaration from the
-- same Template Haskell splice ('deriveJSONAndTypeScript'), using the same
-- options. That is what keeps the frontend's types and the backend's JSON
-- from drifting apart: the TypeScript is generated from this module by
-- @reckon-codegen@, never written by hand.
--
-- To add an API type: define it here, add a splice for it, and add it to
-- 'typeScriptDeclarations'. Then run @make codegen@.
module Reckon.Api.Types
  ( HealthResponse (..)
  , DatabaseStatus (..)
  , ReconciliationState (..)
  , CheckpointSummary (..)
  , AccountSummary (..)
  , TransactionSource (..)
  , CounterLine (..)
  , TransactionView (..)
  , SpendingLine (..)
  , SpendingMonth (..)
  , PersonBalance (..)
  , ReceivablesResponse (..)
  , ReviewReasonKind (..)
  , ReviewRow (..)
  , ProvisionalRow (..)
  , ImportFlagKind (..)
  , ImportFlag (..)
  , ReviewQueue (..)
  , LedgerAccountView (..)
  , UploadedFile (..)
  , ImportCsvRequest (..)
  , ImportScreenshotsRequest (..)
  , ActionResult (..)
  , SettleRequest (..)
  , SplitShare (..)
  , SplitRequest (..)
  , AddPersonRequest (..)
  , AddRuleRequest (..)
  , RuleView (..)
  , RuleProblemView (..)
  , PreviewEffectKind (..)
  , PreviewRowView (..)
  , RulePreviewView (..)
  , CheckRuleRequest (..)
  , RuleCheck (..)
  , ApplyRuleRequest (..)
  , ReminderKindTag (..)
  , ReminderView (..)
  , DueDateView (..)
  , RemindersResponse (..)
  , AddDueDateRequest (..)
  , BalanceRequest (..)
  , ApiProblem (..)
  , typeScriptDeclarations
  ) where

import Data.Aeson.TypeScript.TH (TSDeclaration, deriveJSONAndTypeScript, getTypeScriptDeclarations)
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import Reckon.Api.JsonOptions (enumOptions, recordOptions)

-- | Whether the server could run a trivial query against Postgres.
data DatabaseStatus
  = DatabaseReachable
  | DatabaseUnreachable
  deriving stock (Show, Eq)

-- | Response of @GET /api/health@.
data HealthResponse = HealthResponse
  { databaseStatus :: DatabaseStatus
  , serverVersion :: Text
  }
  deriving stock (Show, Eq)

-- * Accounts

-- | Whether the ledger matched a statement balance on its date.
data ReconciliationState
  = ReconciliationReconciled
  | ReconciliationGap
  deriving stock (Show, Eq)

-- | The most recent statement balance recorded for an account, and how the
-- ledger compares. Balances are in the statement's own sign convention:
-- money in a chequing account, money owed on a card.
data CheckpointSummary = CheckpointSummary
  { asOf :: Text
  -- ^ ISO date.
  , statementBalanceCents :: Int
  , ledgerBalanceCents :: Int
  , state :: ReconciliationState
  , explanation :: [Text]
  -- ^ Why they differ (empty when reconciled), one finding per entry.
  }
  deriving stock (Show, Eq)

data AccountSummary = AccountSummary
  { last4 :: Text
  , nickname :: Text
  , kind :: Text
  -- ^ @chequing@, @savings@ or @credit_card@.
  , balanceCents :: Int
  -- ^ The ledger's balance today, in the statement's sign convention.
  , unpostedRows :: Int
  -- ^ Imported rows not posted to the journal yet.
  , openProvisional :: Int
  -- ^ Rows read from screenshots that no bank export has confirmed.
  , latestCheckpoint :: Maybe CheckpointSummary
  }
  deriving stock (Show, Eq)

-- * Transactions

data TransactionSource
  = SourceCsv
  | SourceScreenshot
  | SourceOpeningBalance
  | SourceOther
  deriving stock (Show, Eq)

-- | One line of an entry that isn't on the bank account: a category, a
-- friend's receivable, the clearing account. Raw sign: positive is a debit.
data CounterLine = CounterLine
  { account :: Text
  , amountCents :: Int
  }
  deriving stock (Show, Eq)

-- | An entry on a bank account, as the bank shows it.
data TransactionView = TransactionView
  { entryId :: Int
  , date :: Text
  , description :: Text
  , amountCents :: Int
  -- ^ Negative is money leaving the account.
  , counterLines :: [CounterLine]
  , source :: TransactionSource
  , rowId :: Maybe Int
  -- ^ The imported row it came from: a bank row for @csv@, a screenshot row
  -- for @screenshot@.
  , provisional :: Bool
  }
  deriving stock (Show, Eq)

-- * Spending

data SpendingLine = SpendingLine
  { account :: Text
  , cents :: Int
  }
  deriving stock (Show, Eq)

-- | One month's spending on the owner's own share, by expense account.
data SpendingMonth = SpendingMonth
  { month :: Text
  -- ^ @YYYY-MM@.
  , totalCents :: Int
  , categories :: [SpendingLine]
  -- ^ Largest first.
  }
  deriving stock (Show, Eq)

-- * Receivables

data PersonBalance = PersonBalance
  { name :: Text
  , owedCents :: Int
  -- ^ Negative if they have paid more than they owed.
  }
  deriving stock (Show, Eq)

data ReceivablesResponse = ReceivablesResponse
  { people :: [PersonBalance]
  , totalOwedCents :: Int
  }
  deriving stock (Show, Eq)

-- * Review

data ReviewReasonKind
  = ReviewAmbiguousPair
  | ReviewZeroAmount
  | ReviewPossibleRepayment
  deriving stock (Show, Eq)

-- | An imported row `post` wouldn't decide on its own.
data ReviewRow = ReviewRow
  { rowId :: Int
  , account :: Text
  , date :: Text
  , description :: Text
  , amountCents :: Int
  , reason :: ReviewReasonKind
  , detail :: Text
  -- ^ The reason in words.
  , people :: [Text]
  -- ^ For a possible repayment: who it might be from.
  }
  deriving stock (Show, Eq)

-- | A row read from a screenshot that no bank export has confirmed yet.
data ProvisionalRow = ProvisionalRow
  { screenshotRowId :: Int
  , account :: Text
  , date :: Text
  , description :: Text
  , amountCents :: Int
  , pending :: Bool
  , posted :: Bool
  -- ^ False for a row the model wasn't sure of, which is held, not posted.
  }
  deriving stock (Show, Eq)

data ImportFlagKind
  = ImportFlagPossibleDuplicate
  | ImportFlagMissingFromNewerExport
  deriving stock (Show, Eq)

-- | Something an import noticed and left for a person.
data ImportFlag = ImportFlag
  { kind :: ImportFlagKind
  , account :: Text
  , date :: Text
  , description :: Text
  , amountCents :: Int
  , relatedDescription :: Maybe Text
  }
  deriving stock (Show, Eq)

data ReviewQueue = ReviewQueue
  { unposted :: [ReviewRow]
  , provisional :: [ProvisionalRow]
  , importFlags :: [ImportFlag]
  }
  deriving stock (Show, Eq)

data LedgerAccountView = LedgerAccountView
  { name :: Text
  , accountType :: Text
  }
  deriving stock (Show, Eq)

-- * Doing things

-- | A file sent from the browser, its bytes in base64.
data UploadedFile = UploadedFile
  { fileName :: Text
  , contentBase64 :: Text
  }
  deriving stock (Show, Eq)

data ImportCsvRequest = ImportCsvRequest
  { file :: UploadedFile
  }
  deriving stock (Show, Eq)

data ImportScreenshotsRequest = ImportScreenshotsRequest
  { last4 :: Text
  , takenOn :: Maybe Text
  -- ^ ISO date the screenshots were taken. Today when absent.
  , files :: [UploadedFile]
  -- ^ One scroll of the list, the top of it first.
  }
  deriving stock (Show, Eq)

-- | What happened, in words. Most actions answer with this.
data ActionResult = ActionResult
  { message :: Text
  , details :: [Text]
  }
  deriving stock (Show, Eq)

newtype SettleRequest = SettleRequest
  { account :: Text
  }
  deriving stock (Show, Eq)

data SplitShare = SplitShare
  { person :: Text
  , cents :: Int
  }
  deriving stock (Show, Eq)

-- | Share a payment: either equally with these people, or by exact shares
-- (the owner keeps the rest). Exactly one of the two.
data SplitRequest = SplitRequest
  { category :: Text
  , equalWith :: Maybe [Text]
  , shares :: Maybe [SplitShare]
  }
  deriving stock (Show, Eq)

data AddPersonRequest = AddPersonRequest
  { name :: Text
  , matchText :: Text
  }
  deriving stock (Show, Eq)

-- | A rule in the rule language (one line of text) and when it runs.
data AddRuleRequest = AddRuleRequest
  { ruleText :: Text
  , priority :: Maybe Int
  -- ^ Lower runs first. 100 if not given.
  }
  deriving stock (Show, Eq)

-- | A saved rule. @problem@ is set only if the text no longer reads as a
-- rule (the language changed since it was saved).
data RuleView = RuleView
  { ruleId :: Int
  , ruleText :: Text
  , priority :: Int
  , problem :: Maybe Text
  }
  deriving stock (Show, Eq)

-- | Where a rule's text went wrong. Line and column count from 1.
data RuleProblemView = RuleProblemView
  { line :: Int
  , column :: Int
  , message :: Text
  }
  deriving stock (Show, Eq)

-- | What a rule would do to a row that already exists.
data PreviewEffectKind
  = EffectMove
  | EffectAlreadyThere
  | EffectOnNextPost
  | EffectCannotChange
  deriving stock (Show, Eq)

data PreviewRowView = PreviewRowView
  { rowId :: Int
  , date :: Text
  , description :: Text
  , amountCents :: Int
  , effect :: PreviewEffectKind
  , detail :: Maybe Text
  -- ^ For a move, the account it is in now. For a refusal, why.
  }
  deriving stock (Show, Eq)

-- | The rows a rule matches among those already imported, counted by what
-- would happen to them, with the newest rows listed.
data RulePreviewView = RulePreviewView
  { matched :: Int
  , wouldMove :: Int
  , alreadyThere :: Int
  , onNextPost :: Int
  , cannotChange :: Int
  , rows :: [PreviewRowView]
  }
  deriving stock (Show, Eq)

newtype CheckRuleRequest = CheckRuleRequest
  { ruleText :: Text
  }
  deriving stock (Show, Eq)

-- | The answer to "is this a rule?": either what's wrong and where, or the
-- rule as the system will store it and what it would do to existing rows.
data RuleCheck = RuleCheck
  { problem :: Maybe RuleProblemView
  , canonicalText :: Maybe Text
  , preview :: Maybe RulePreviewView
  }
  deriving stock (Show, Eq)

newtype ApplyRuleRequest = ApplyRuleRequest
  { ruleText :: Text
  }
  deriving stock (Show, Eq)

-- | What kind of thing a recurring check found.
data ReminderKindTag
  = ReminderStatementMissing
  | ReminderProvisionalStale
  | ReminderDueSoon
  deriving stock (Show, Eq)

-- | Something the recurring checks want a person to know. The message is
-- ready to show.
data ReminderView = ReminderView
  { reminderId :: Int
  , kind :: ReminderKindTag
  , message :: Text
  , detectedAt :: Text
  -- ^ ISO 8601, UTC.
  }
  deriving stock (Show, Eq)

-- | A day of every month someone should be reminded of.
data DueDateView = DueDateView
  { dueDateId :: Int
  , label :: Text
  , dayOfMonth :: Int
  , warnDays :: Int
  }
  deriving stock (Show, Eq)

data RemindersResponse = RemindersResponse
  { reminders :: [ReminderView]
  , dueDates :: [DueDateView]
  , lastCheckedAt :: Maybe Text
  -- ^ When the checks last ran (by the schedule or by hand), ISO 8601, UTC.
  }
  deriving stock (Show, Eq)

data AddDueDateRequest = AddDueDateRequest
  { label :: Text
  , dayOfMonth :: Int
  , warnDays :: Maybe Int
  -- ^ Days ahead to start reminding. 5 if not given.
  }
  deriving stock (Show, Eq)

-- | A balance on a date: an opening balance or a statement checkpoint.
data BalanceRequest = BalanceRequest
  { date :: Text
  , balanceCents :: Int
  }
  deriving stock (Show, Eq)

-- | The body of every error response.
newtype ApiProblem = ApiProblem
  { problem :: Text
  }
  deriving stock (Show, Eq)

$(deriveJSONAndTypeScript (enumOptions "Database") ''DatabaseStatus)
$(deriveJSONAndTypeScript recordOptions ''HealthResponse)

$(deriveJSONAndTypeScript (enumOptions "Reconciliation") ''ReconciliationState)
$(deriveJSONAndTypeScript recordOptions ''CheckpointSummary)
$(deriveJSONAndTypeScript recordOptions ''AccountSummary)
$(deriveJSONAndTypeScript (enumOptions "Source") ''TransactionSource)
$(deriveJSONAndTypeScript recordOptions ''CounterLine)
$(deriveJSONAndTypeScript recordOptions ''TransactionView)
$(deriveJSONAndTypeScript recordOptions ''SpendingLine)
$(deriveJSONAndTypeScript recordOptions ''SpendingMonth)
$(deriveJSONAndTypeScript recordOptions ''PersonBalance)
$(deriveJSONAndTypeScript recordOptions ''ReceivablesResponse)
$(deriveJSONAndTypeScript (enumOptions "Review") ''ReviewReasonKind)
$(deriveJSONAndTypeScript recordOptions ''ReviewRow)
$(deriveJSONAndTypeScript recordOptions ''ProvisionalRow)
$(deriveJSONAndTypeScript (enumOptions "ImportFlag") ''ImportFlagKind)
$(deriveJSONAndTypeScript recordOptions ''ImportFlag)
$(deriveJSONAndTypeScript recordOptions ''ReviewQueue)
$(deriveJSONAndTypeScript recordOptions ''LedgerAccountView)
$(deriveJSONAndTypeScript recordOptions ''UploadedFile)
$(deriveJSONAndTypeScript recordOptions ''ImportCsvRequest)
$(deriveJSONAndTypeScript recordOptions ''ImportScreenshotsRequest)
$(deriveJSONAndTypeScript recordOptions ''ActionResult)
$(deriveJSONAndTypeScript recordOptions ''SettleRequest)
$(deriveJSONAndTypeScript recordOptions ''SplitShare)
$(deriveJSONAndTypeScript recordOptions ''SplitRequest)
$(deriveJSONAndTypeScript recordOptions ''AddPersonRequest)
$(deriveJSONAndTypeScript recordOptions ''AddRuleRequest)
$(deriveJSONAndTypeScript recordOptions ''RuleView)
$(deriveJSONAndTypeScript recordOptions ''RuleProblemView)
$(deriveJSONAndTypeScript (enumOptions "Effect") ''PreviewEffectKind)
$(deriveJSONAndTypeScript recordOptions ''PreviewRowView)
$(deriveJSONAndTypeScript recordOptions ''RulePreviewView)
$(deriveJSONAndTypeScript recordOptions ''CheckRuleRequest)
$(deriveJSONAndTypeScript recordOptions ''RuleCheck)
$(deriveJSONAndTypeScript recordOptions ''ApplyRuleRequest)
$(deriveJSONAndTypeScript (enumOptions "Reminder") ''ReminderKindTag)
$(deriveJSONAndTypeScript recordOptions ''ReminderView)
$(deriveJSONAndTypeScript recordOptions ''DueDateView)
$(deriveJSONAndTypeScript recordOptions ''RemindersResponse)
$(deriveJSONAndTypeScript recordOptions ''AddDueDateRequest)
$(deriveJSONAndTypeScript recordOptions ''BalanceRequest)
$(deriveJSONAndTypeScript recordOptions ''ApiProblem)

-- | The TypeScript declarations for every API type, in the order they are
-- written to @frontend/src/api/generated.ts@.
typeScriptDeclarations :: [TSDeclaration]
typeScriptDeclarations =
  mconcat
    [ getTypeScriptDeclarations (Proxy @HealthResponse)
    , getTypeScriptDeclarations (Proxy @DatabaseStatus)
    , getTypeScriptDeclarations (Proxy @ReconciliationState)
    , getTypeScriptDeclarations (Proxy @CheckpointSummary)
    , getTypeScriptDeclarations (Proxy @AccountSummary)
    , getTypeScriptDeclarations (Proxy @TransactionSource)
    , getTypeScriptDeclarations (Proxy @CounterLine)
    , getTypeScriptDeclarations (Proxy @TransactionView)
    , getTypeScriptDeclarations (Proxy @SpendingLine)
    , getTypeScriptDeclarations (Proxy @SpendingMonth)
    , getTypeScriptDeclarations (Proxy @PersonBalance)
    , getTypeScriptDeclarations (Proxy @ReceivablesResponse)
    , getTypeScriptDeclarations (Proxy @ReviewReasonKind)
    , getTypeScriptDeclarations (Proxy @ReviewRow)
    , getTypeScriptDeclarations (Proxy @ProvisionalRow)
    , getTypeScriptDeclarations (Proxy @ImportFlagKind)
    , getTypeScriptDeclarations (Proxy @ImportFlag)
    , getTypeScriptDeclarations (Proxy @ReviewQueue)
    , getTypeScriptDeclarations (Proxy @LedgerAccountView)
    , getTypeScriptDeclarations (Proxy @UploadedFile)
    , getTypeScriptDeclarations (Proxy @ImportCsvRequest)
    , getTypeScriptDeclarations (Proxy @ImportScreenshotsRequest)
    , getTypeScriptDeclarations (Proxy @ActionResult)
    , getTypeScriptDeclarations (Proxy @SettleRequest)
    , getTypeScriptDeclarations (Proxy @SplitShare)
    , getTypeScriptDeclarations (Proxy @SplitRequest)
    , getTypeScriptDeclarations (Proxy @AddPersonRequest)
    , getTypeScriptDeclarations (Proxy @AddRuleRequest)
    , getTypeScriptDeclarations (Proxy @RuleView)
    , getTypeScriptDeclarations (Proxy @RuleProblemView)
    , getTypeScriptDeclarations (Proxy @PreviewEffectKind)
    , getTypeScriptDeclarations (Proxy @PreviewRowView)
    , getTypeScriptDeclarations (Proxy @RulePreviewView)
    , getTypeScriptDeclarations (Proxy @CheckRuleRequest)
    , getTypeScriptDeclarations (Proxy @RuleCheck)
    , getTypeScriptDeclarations (Proxy @ApplyRuleRequest)
    , getTypeScriptDeclarations (Proxy @ReminderKindTag)
    , getTypeScriptDeclarations (Proxy @ReminderView)
    , getTypeScriptDeclarations (Proxy @DueDateView)
    , getTypeScriptDeclarations (Proxy @RemindersResponse)
    , getTypeScriptDeclarations (Proxy @AddDueDateRequest)
    , getTypeScriptDeclarations (Proxy @BalanceRequest)
    , getTypeScriptDeclarations (Proxy @ApiProblem)
    ]
