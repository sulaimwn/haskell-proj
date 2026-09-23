module Main (main) where

import Reckon.Api.TypesSpec qualified as TypesSpec
import Reckon.Ledger.EntrySpec qualified as EntrySpec
import Reckon.LedgerSpec qualified as LedgerSpec
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
  describe "Reckon.Server" ServerSpec.spec
