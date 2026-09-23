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
-- are left out; persistent never selects or inserts them. Columns stored as
-- text with a CHECK constraint (account_type, account_kind, kind) use
-- Haskell types with hand-written text conversions (DECISIONS D028).
module Reckon.Database.Schema where

import Data.Text (Text)
import Data.Time (Day)
import Database.Persist.TH (mkPersist, persistLowerCase, share, sqlSettings)
import Reckon.Bank (BankAccountKind, Last4)
import Reckon.Import.Dedupe (Fingerprint, ReviewItemKind)
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

BankAccount sql=bank_accounts
  institution Text
  accountKind BankAccountKind
  last4 Last4
  nickname Text
  ledgerAccountId LedgerAccountId
  UniqueBankAccount institution accountKind last4
  deriving Show Eq

ImportBatch sql=import_batches
  source Text
  fileSha256 Text
  fileName Text
  UniqueImportBatchFile fileSha256
  deriving Show Eq

ImportBatchCoverage sql=import_batch_coverage
  batchId ImportBatchId
  bankAccountId BankAccountId
  firstDate Day
  lastDate Day
  rowsInFile Int
  rowsAdded Int
  Primary batchId bankAccountId
  deriving Show Eq

RawBankRow sql=raw_bank_rows
  bankAccountId BankAccountId
  firstSeenBatchId ImportBatchId
  transactionDate Day
  description1 Text sql=description_1
  description2 Text sql=description_2
  chequeNumber Text
  amountCents Cents
  fingerprint Fingerprint
  occurrence Int
  UniqueRawBankRow bankAccountId transactionDate fingerprint occurrence
  deriving Show Eq

ImportReviewItem sql=import_review_items
  batchId ImportBatchId
  bankAccountId BankAccountId
  transactionDate Day
  kind ReviewItemKind
  rawBankRowId RawBankRowId
  relatedRawBankRowId RawBankRowId Maybe
  deriving Show Eq
|]
