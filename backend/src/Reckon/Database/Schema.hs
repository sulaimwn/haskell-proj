{-# LANGUAGE NoDuplicateRecordFields #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}

-- | persistent's view of the tables created by the SQL migrations.
--
-- The migrations in @db/migrations@ own the schema. These definitions only
-- describe it, so persistent can generate typed rows, keys and query
-- columns, and they must be kept in step with the SQL by hand. Columns the
-- database fills in on its own (@created_at@, @created_in_transaction@)
-- are left out; persistent never selects or inserts them.
module Reckon.Database.Schema where

import Data.Text (Text)
import Data.Time (Day)
import Database.Persist.TH (mkPersist, persistLowerCase, share, sqlSettings)
import Reckon.Ledger.AccountType (AccountType)
import Reckon.Money (Cents)

-- Each block generates a record type (e.g. 'LedgerAccount'), a key type
-- ('LedgerAccountId', distinct per table, so an entry id can never be
-- passed where an account id is expected), and a column name per field
-- for esqueleto queries (e.g. 'JournalLineAmountCents').
share
  [mkPersist sqlSettings]
  [persistLowerCase|
LedgerAccount sql=ledger_accounts
  name Text
  accountType AccountType
  currency Text
  UniqueLedgerAccountName name
  deriving Show Eq

JournalEntry sql=journal_entries
  occurredOn Day
  description Text
  reversesEntryId JournalEntryId Maybe
  deriving Show Eq

JournalLine sql=journal_lines
  entryId JournalEntryId
  ledgerAccountId LedgerAccountId
  amountCents Cents
  deriving Show Eq
|]
