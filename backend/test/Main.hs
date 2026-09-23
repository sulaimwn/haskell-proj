module Main (main) where

import Reckon.Api.TypesSpec qualified as TypesSpec
import Reckon.Ledger.EntrySpec qualified as EntrySpec
import Reckon.LedgerSpec qualified as LedgerSpec
import Reckon.ConfigSpec qualified as ConfigSpec
import Reckon.ServerSpec qualified as ServerSpec
import Test.Hspec (describe, hspec)

main :: IO ()
main = hspec $ do
  describe "Reckon.Config" ConfigSpec.spec
  describe "Reckon.Api.Types" TypesSpec.spec
  describe "Reckon.Ledger.Entry" EntrySpec.spec
  describe "Reckon.Ledger" LedgerSpec.spec
  describe "Reckon.Server" ServerSpec.spec
