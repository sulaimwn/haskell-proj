module Main (main) where

import Reckon.AnthropicSpec qualified as AnthropicSpec
import Reckon.Api.TypesSpec qualified as TypesSpec
import Reckon.Ledger.EntrySpec qualified as EntrySpec
import Reckon.LedgerSpec qualified as LedgerSpec
import Reckon.Posting.ClassifySpec qualified as ClassifySpec
import Reckon.Posting.SplitSpec qualified as SplitSpec
import Reckon.PostingSpec qualified as PostingSpec
import Reckon.ScreenshotSpec qualified as ScreenshotSpec
import Reckon.SharingSpec qualified as SharingSpec
import Reckon.Reconcile.ExplainSpec qualified as ExplainSpec
import Reckon.Screenshot.AlignSpec qualified as AlignSpec
import Reckon.Screenshot.ExtractionSpec qualified as ExtractionSpec
import Reckon.Screenshot.MatchSpec qualified as MatchSpec
import Reckon.Screenshot.ScoreSpec qualified as ScoreSpec
import Reckon.ConfigSpec qualified as ConfigSpec
import Reckon.Import.DedupeSpec qualified as DedupeSpec
import Reckon.Import.RbcCsvSpec qualified as RbcCsvSpec
import Reckon.ImportSpec qualified as ImportSpec
import Reckon.ServerSpec qualified as ServerSpec
import Test.Hspec (describe, hspec)

main :: IO ()
main = hspec $ do
  describe "Reckon.Config" ConfigSpec.spec
  describe "Reckon.Api.Types" TypesSpec.spec
  describe "Reckon.Ledger.Entry" EntrySpec.spec
  describe "Reckon.Ledger" LedgerSpec.spec
  describe "Reckon.Import.RbcCsv" RbcCsvSpec.spec
  describe "Reckon.Import.Dedupe" DedupeSpec.spec
  describe "Reckon.Import" ImportSpec.spec
  describe "Reckon.Posting.Classify" ClassifySpec.spec
  describe "Reckon.Posting.Split" SplitSpec.spec
  describe "Reckon.Reconcile.Explain" ExplainSpec.spec
  describe "Reckon.Screenshot.Extraction" ExtractionSpec.spec
  describe "Reckon.Screenshot.Align" AlignSpec.spec
  describe "Reckon.Screenshot.Match" MatchSpec.spec
  describe "Reckon.Screenshot.Score" ScoreSpec.spec
  describe "Reckon.Anthropic" AnthropicSpec.spec
  describe "Reckon.Posting" PostingSpec.spec
  describe "Reckon.Sharing and Reckon.People" SharingSpec.spec
  describe "Reckon.Screenshot.Import and Store" ScreenshotSpec.spec
  describe "Reckon.Server" ServerSpec.spec
