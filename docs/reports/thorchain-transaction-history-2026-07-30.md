# THORChain transaction history — work log, 2026-07-30

## Scope

Implemented THORChain transaction history with Midgard while retaining TronKit
as the default architecture. THOR-specific behaviour is limited to Midgard's
opaque pagination token and action format.

## Delivered behaviour

- Midgard actions are persisted as the Kit transaction history and exposed
  through the existing Kit publishers and pagination API.
- History refresh is independent of the account/balance request, so a failed
  balance read does not leave transaction history stale.
- A newly journaled send is immediately inserted once as a pending history
  transaction by its hash. Midgard then replaces that row with indexed chain
  data for the same hash.
- A rejected broadcast marks an existing pending history row as `failed` by
  hash. It does not require a separate "local" marker.
- Terminal Midgard actions and journal cleanup remain one database write.
- The durable `processed` flag follows TronKit's delta-publication model: a
  subscriber receives only changed rows, not the full history every refresh.
- History sync state now retains a typed reason instead of reducing every
  failure to a bare `failed` state.
- Midgard nanosecond timestamps are retained for ordering and cursor storage.
  Recent pagination continues through all actions at the current watermark
  timestamp and stops only at a strictly older timestamp. This prevents a
  page boundary from permanently losing actions sharing the same timestamp.
- Wallet's THOR transaction adapter is passed through the standard transaction
  decorator factory, matching the Tron adapter composition path.

## Deliberate decisions

- There are no THORChainKit clients yet, so the in-progress `v4-history`
  schema is maintained as one layer; no compatibility migration was added.
  A developer database created before the final schema must be reset.
- No `is_local` persistence column is used. Repeating local journal recovery
  is an idempotent insert by hash; only Midgard updates the row afterwards.
- Midgard does not document a secondary ordering key alongside its opaque
  `nextPageToken`. We therefore do not invent an EVM-style hash/index cursor.
  Instead, the syncer consumes the complete equal-timestamp segment.
- Wallet-level incoming/outgoing/contact filtering is intentionally not
  patched here. Tron filters normalized transaction tags before pagination;
  THOR currently has arbitrary Midgard transfer legs and needs a separately
  designed query contract to preserve cursor correctness.

## Validation

- Before the final `is_local` removal: 35 focused Kit tests passed, including
  history, account sync, pending journal, sender ownership, and Kit lifecycle.
- After the final change: 22 targeted history and pending-manager tests passed.
- `git diff --check` and syntax parsing of the edited files passed.
- Xcode/AppTests were not run because their known dynamic Swift Package
  framework issue is unrelated to this Kit work.

## Git checkpoints

- `4d1594a feat: add Midgard transaction history`
- `9f8dcf7 feat: project local sends into transaction history`

The final `is_local` simplification is intentionally still uncommitted at the
time of this report.

## Main code locations

### ThorChainKit

- `Sources/ThorChainKit/Core/Kit.swift`
- `Sources/ThorChainKit/Core/KitFactory.swift`
- `Sources/ThorChainKit/Models/Transaction.swift`
- `Sources/ThorChainKit/Send/Internal/TransactionSender.swift`
- `Sources/ThorChainKit/Send/Storage/SendJournal.swift`
- `Sources/ThorChainKit/Storage/TransactionStorage.swift`
- `Sources/ThorChainKit/Storage/TransactionRepository.swift`
- `Sources/ThorChainKit/Storage/TransactionManager.swift`
- `Sources/ThorChainKit/Sync/Syncer.swift`
- `Sources/ThorChainKit/Sync/TransactionSyncer.swift`
- `Tests/ThorChainKitTests/AccountSyncerTests.swift`
- `Tests/ThorChainKitTests/TransactionHistoryTests.swift`

### Unstoppable Wallet integration

- `packages/WalletCore/Sources/WalletCore/Core/Factories/AdapterFactory.swift`
- `packages/WalletCore/Sources/WalletCore/Core/Adapters/ThorChain/ThorChainTransactionAdapter.swift`
- `packages/WalletCore/Sources/WalletCore/Core/Adapters/ThorChain/ThorChainTransactionConverter.swift`
- `packages/WalletCore/Sources/WalletCore/Models/TransactionRecords/ThorChain/`
