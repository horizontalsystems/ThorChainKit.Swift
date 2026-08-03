# ThorChainKit — Main Roadmap

## Goal

Create a standalone Swift Package, `ThorChainKit`, that provides complete native THORChain support in Unstoppable Wallet iOS. Each sprint must conclude with an observable vertical outcome in the real app and on the real network; unit tests without host verification do not constitute sprint completion.

## Slicing Principle

```text
Protocol fact
  → standalone Kit behavior
    → Unstoppable adapter boundary
      → deterministic tests
        → opt-in live-network gate
          → real user scenario
```

## Major Milestones

| Sprint | Status | In-app outcome | Core capabilities |
|---|---|---|---|
| 1. Foundation + read-only RUNE | done | The user enables RUNE and sees the correct `thor1…` address and balance after restart | package, `iOS Example`, network identity, derivation/address, THORNode reads, account sync, UW manager/adapter/parser, MarketKit metadata |
| 2. Native RUNE send | done | The user sends RUNE and receives a tx hash | account number/sequence, fee, protobuf sign doc, signer boundary, broadcast, preflight quote |
| 3. Transaction history and status | done | The wallet displays inbound/outbound transactions and their statuses | Midgard actions, pagination, normalized transaction model, pending reconciliation, explorer |
| 4. Native THOR actions | done | The wallet performs deposit/memo operations | `MsgDeposit`, memo validation, native fee, halt/mimir checks |
| 5. THOR assets and token model | done | The wallet displays THORChain denoms beyond native RUNE | opaque and `x/` denoms, decimals, per-denom balance and send, RUNE-charged fee |
| 6. Provider reliability | partial | User-supplied and public nodes work predictably | endpoint pool, health/identity probe, failover, backoff, rate-limit reporting. Telemetry and a published privacy policy are still open |
| 7. Native swap v2 | not started | The multichain swap provider gains an internal THOR-native implementation | quote/inbound/memo/streaming swap, action tracking and refunds. The wallet currently swaps through the existing THORChain/Maya providers, which use this kit only to sign and broadcast |
| 8. Release hardening | partial | The kit ships from a public repository | released as `1.0.0` from `horizontalsystems/ThorChainKit.Swift`. API stability, fuzz/fixtures, performance, and a security review are still open |

## Version Boundaries

- `v1`: native RUNE account, send, history/status, THOR deposits, THORChain tokens, production-grade provider behavior.
- `v2`: internal THOR-native swap. The existing multichain THORChain provider continues to operate until a separate migration decision is made.
- Key handling follows TronKit and EvmKit: the kit owns derivation and signing through a conventional `Signer`, built with `Signer.instance(seed:)` or `Signer.instance(privateKey:)`, with `Signer.address(seed:)` for address lookup. Anything TronKit does this way, ThorChainKit does the same way.
- Vultisig MPC/TSS stays outside that conventional path. `ISigner` is the seam a substitute signer implements, so an external device or a test double can drive the send pipeline without holding a seed.

## Definition of Done for Any Sprint

- Every slice has an approved spec and acceptance criteria.
- All deterministic tests are green; network tests are separate and opt-in.
- Errors, cancellation, timeouts, and restarts are explicitly tested.
- Significant state is not published from a stale lifecycle generation.
- Integration goes through the standard Unstoppable adapter contract without a hidden special case, unless the spec explicitly proves otherwise.
- A real user scenario is completed on a controlled account, with the endpoint, block height/tx ID, and outcome recorded.
- Whatever the Android kit already does is done the same way, unless a platform fact forces otherwise and the spec says which.

## Cross-Repository State

1. `ThorChainKit.Swift` — public at `horizontalsystems/ThorChainKit.Swift`, released as `1.0.0`.
2. MarketKit — `BlockchainType.thorChain`, RUNE and THORChain token metadata, decimals `8`, explorer template: in place.
3. Unstoppable `WalletCore` — consumes the kit by tag; manager, wrapper, adapters, transaction converter, send and swap wiring: in place.
4. App-level acceptance and the UI for custom nodes: in place. Advanced THOR actions beyond deposit remain open.
