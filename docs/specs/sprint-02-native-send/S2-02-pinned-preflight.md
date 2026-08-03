# S2-02 — Height-Pinned Send Preflight

**Risk:** critical
**Depends on:** S2-01 and Sprint 1 endpoint/read infrastructure
**Produces:** a coherent authoritative snapshot and immutable quote; no signing

> **Partly superseded.** The rule this slice exists for still holds: one family, one
> proven height, one coherent snapshot. What changed since, and what the code now does:
>
> - Five routes, not ten: `account`, `spendable`, `network-fee`, `mimir`,
>   `recipient-account`. A token send reads `spendable` twice, for its own denom and for
>   the RUNE the fee is charged in.
> - Mimir arrives as one map from `/thorchain/mimir`. A key absent from the map is the
>   `-1` the per-key route used to report.
> - `node-version` is gone. It gated a module-address list the kit derives locally from
>   module names, so it protected nothing and would have refused every send once the
>   chain moved past 3.19.3.
> - `auth-params` is gone. The memo limit is a protocol constant the policy carries.
> - `SendPolicy.operationDeadline` is gone and the preflight runner sets no deadline of
>   its own; the transport bounds the wait, as it does in the Android kit.
> - A deposit has no recipient, so it skips `recipient-account` and ends on `mimir`.

## Goal

Authorize review only from one provider family at one proven Cosmos height. A quote must combine account, sequence, balance, native fee, halt, memo, module-account, and network identity facts without mixing time or providers.

## Assumptions

- Merged THR-139 is the current product authority for native-RUNE family IDs and
  the six normalized role-bound endpoint records.
- S1-04 supplies the existing lease, transport, and height/error seams; S2-02
  extends only the named preflight seams and does not replace them.
- Query-only protobuf sources can be generated from the pinned provenance
  contract below without introducing transaction or signing codecs.
- Live/fixture compatibility captures are implementation and QA evidence; until
  they are complete, every family remains read-only.

## Open Questions

None block this formalization. The three families' live/fixture proof status is
intentionally `UNRUN` and is an implementation/QA gate, not an unresolved
design choice.

## Scope

- `SendPreflightCoordinator`, `SendSnapshot`, `SendPolicy`, and THORNode send endpoints;
- the exact THR-139 native-RUNE manifest registry: `rorcual-mainnet`,
  `ibs-mainnet`, and `keplr-mainnet`, with all six role-bound endpoint records;
- the minimum existing `SendRuntime`, `QuoteStore`, `SendQuote`, and composition seams required to admit, invalidate, and store the preflight result;
- `EndpointLease`/provider-family pinning for the complete logical quote;
- one bounded owned-operation runner for every lease, retry/backoff, and provider request;
- exact height echo validation and snapshot digest;
- recipient account classification plus a versioned THORNode forbidden-module set, dynamic native fee, Mimir halt evaluation, and auth memo parameter;
- query-only Cosmos/ABCI protocol codecs required by the approved Comet proof modes;
- revalidation API consumed by S2-04;
- deterministic cache rules limited to data proven safe at the exact height.

Out of scope: transaction/signing protobuf and signature, broadcast, pending
journal, S2-05 retry/lookup implementation, UI, history, and Unstoppable
integration.

## Proposed Areas and Functions

```text
Sources/ThorChainKit/Send/Preflight/
  SendPreflightCoordinator.swift
  SendSnapshot.swift
  SendPolicy.swift
  HaltEvaluator.swift
  RecipientAccountClassifier.swift
  ForbiddenModuleAddressSet.swift
Sources/ThorChainKit/Network/
  EndpointOperationRunner.swift
  EndpointLease+Send.swift
  ThorNodeSendClient.swift
  CosmosAuthParametersClient.swift
  HeightProof.swift
  CosmosQueryCodec.swift
  Generated/Query/*.pb.swift
  Generated/Query/PROVENANCE.md
Scripts/generate-query-codec.sh
Package.swift (only the exact query-codec dependency)
Sources/ThorChainKit/Send/Internal/
  SendRuntime.swift
  QuoteStore.swift
Sources/ThorChainKit/Core/
  KitFactory.swift
  KitDependencies.swift
  LifecycleCommandBridge.swift
Sources/ThorChainKit/Send/Domain/
  SendQuote.swift
Tests/ThorChainKitTests/Send/Preflight/
  EndpointOperationRunnerTests.swift
  SendPreflightCoordinatorTests.swift
  HaltEvaluatorTests.swift
  RecipientAccountClassifierTests.swift
  ForbiddenModuleAddressSetTests.swift
  SendPolicyTests.swift
```

Internal responsibilities:

```swift
func prepareQuote(request: SendQuoteRequest) async throws -> PreparedQuote
func revalidate(_ prepared: PreparedQuote) async throws -> RevalidationResult
func loadSnapshot(request: SendQuoteRequest, lease: EndpointLease) async throws -> SendSnapshot
func refreshLease(family: EndpointFamilyDescriptor, minimumHeight: Int64) async throws -> EndpointLease
func evaluate(height: Int64, mimir: MimirSnapshot) throws -> HaltDecision
```

## Native RUNE Family Manifest

S2-02 admits native RUNE send preflight only through the exact registry already
accepted by THR-139. The registry has exactly these three families and exactly
these six role-bound records; it is not a host-set or a single-family fallback:

| Family | REST base | Comet base |
|---|---|---|
| `rorcual-mainnet` | `https://api-thorchain.rorcual.xyz/` | `https://rpc-thorchain.rorcual.xyz/` |
| `ibs-mainnet` | `https://thorchain.ibs.team/api` | `https://thorchain.ibs.team/rpc` |
| `keplr-mainnet` | `https://lcd-thorchain.keplr.app/` | `https://rpc-thorchain.keplr.app/` |

The six normalized records are:

```text
(rorcual-mainnet, rest, https, api-thorchain.rorcual.xyz, 443, /)
(rorcual-mainnet, rpc,   https, rpc-thorchain.rorcual.xyz, 443, /)
(ibs-mainnet,     rest, https, thorchain.ibs.team,         443, /api)
(ibs-mainnet,     rpc,   https, thorchain.ibs.team,         443, /rpc)
(keplr-mainnet,   rest, https, lcd-thorchain.keplr.app,    443, /)
(keplr-mainnet,   rpc,   https, rpc-thorchain.keplr.app,   443, /)
```

The manifest validator requires exact equality of all six `(family, role,
scheme, host, effective port, base path)` records. Missing, extra, duplicate,
cross-family, credential-bearing, query-bearing, fragment-bearing, or HTTP
records fail closed. Liquify is not a native-RUNE or send-capable family; its
historic one-provider behavior remains only a rejected counterexample.

Current S2-02 proof status is explicit and fail-closed:

| Family | Required-route fixture/live proof | Send status |
|---|---|---|
| `rorcual-mainnet` | `UNRUN` for the complete S2-02 route/proof matrix | read-only |
| `ibs-mainnet` | `UNRUN` for the complete S2-02 route/proof matrix | read-only |
| `keplr-mainnet` | `UNRUN` for the complete S2-02 route/proof matrix | read-only |

`PASS` requires every required route to have an approved proof mode and a
redacted fixture or live capture bound to the exact family, six-record
manifest, schema revision, and exact implementation head. `FAIL` and `UNRUN`
also remain read-only. No family is send-capable merely because S1-04 proves
account/height compatibility or because a query-only response exists.

## Query-Only Protobuf Provenance

S2-02 uses only the query/response protobuf messages needed for the approved
Comet proofs and recipient classification. It adds one exact, non-range
`swift-protobuf` dependency at version `1.33.3`; `Package.resolved` must record
the resolved revision, and no floating `from:` requirement is permitted. The
generated files are internal and live only under
`Sources/ThorChainKit/Network/Generated/Query/`. `PROVENANCE.md` and
`Scripts/generate-query-codec.sh --check` must pin THORNode `a759cb4f`, Cosmos
SDK `v0.53.0`, `cosmossdk.io/api v0.9.2`, the exact `protoc` and SwiftProtobuf
plugin versions/checksums, include roots, input file list, and complete
regeneration command. The query set must not contain `MsgSend`, `TxBody`,
`AuthInfo`, `SignDoc`, `TxRaw`, or signature codecs; those generated sources
remain S2-03 ownership.

## Bounded Endpoint Operation Contract

`EndpointOperationRunner` is the single internal liveness primitive used by H0,
H1, and H2 preflight operations. Each lease acquisition, bounded backoff wait,
and HTTP/proof read is one separately owned unstructured `Task` with an
immutable request. Its owner waits through an exactly-once result channel that
races the operation against caller cancellation, the injected
`SendPolicy.operationDeadline`, and—only for H0—the captured client lifecycle
generation becoming inactive. Every H0 context also carries a unique attempt
token and one-shot lifecycle invalidation signal. Cancelling the child is only
a hint: the owner never awaits termination of a dependency that ignores
cancellation or never resumes.

For H1/H2, the callback must re-enter the owning runtime actor and match the
exact attempt token before its value is accepted. H0 callbacks match the exact
client ID, lifecycle generation, attempt token, family token, and route token
captured at quote admission. The actor starts no later endpoint operation until
the guarded callback succeeds. When cancellation/deadline wins, it invalidates
ownership and invokes the phase-specific caller finalizer before returning;
when H0 lifecycle invalidation wins, it returns `kitNotStarted`. A late result
is discarded and cannot start another request, insert a quote, or normalize a
generation. H0 has no send gate/reservation, but its one-shot lifecycle signal
and non-cooperative race prevent both hanging and post-stop quote creation. The
runner has an injected absolute-deadline clock/sleeper seam and fixed
precedence: lifecycle invalidation, caller cancellation, deadline, then
operation result. Orphaned preflight operations are counted per family and
globally; admission fails closed when the configured cap is reached until the
family is quarantined or its operations complete. Durable retry ownership and
transaction lookup remain S2-05.

## Snapshot Transaction

1. On the runtime actor, require this Kit client to be active and capture its exact client ID/lifecycle generation before lease or storage work.
2. Apply S2-01's pure local validation order under that admitted generation; failure returns its typed input error with zero lease/storage calls.
3. Acquire one send-capable `EndpointLease` that identifies a provider family and exact chain identity, guarded by that generation.
4. Select the accepted family round height `H0` as the highest height proven queryable by every required role, bounded by `min(lease.cosmosReadHeight, lease.cometReferenceHeight)`. A family with role skew must prove the common height for every route or fail as a whole.
5. Resolve the family's capability manifest from the exact THR-139 registry,
   bound to exact network identity, normalized Cosmos REST base URL, normalized
   Comet base URL, all six role-bound records, and a versioned manifest
   revision. Unknown or mismatched tuples return `policyUnavailable`. Every
   logical preflight route has one approved proof mode; the returned business
   value and its height proof must come from the same request. A query
   parameter, a neighboring request, or a second transport can never
   retroactively prove an unlabelled value.
6. Load, without switching families and rechecking the captured generation after every callback:
   - sender account number and sequence;
   - exact spendable native balance from the Cosmos single-denom spendable endpoint for literal denom `rune`;
   - `/thorchain/network?height=<H>` and `native_tx_fee_rune`;
   - required Mimir values at `<H>`;
   - Cosmos auth params/memo maximum at `<H>`;
   - THORNode semantic version and the recipient's exact Cosmos auth account classification at `<H>`.
7. Validate network identity/freshness and construct one immutable `SendSnapshot`.
8. Re-enter the runtime actor, require the same client ID, lifecycle generation, H0 attempt token, family token, and route token still active, and only then atomically insert/return the quote through the existing runtime/store seams. Compute a stable internal digest from versioned, length-prefixed canonical bytes, hashed with SHA-256, over exact network identity, normalized family endpoints, manifest/proof revision, common height, sender account, balance, fee, halt inputs, memo limit, node version, recipient account classification, and the versioned forbidden-module policy revision. A fixed digest vector is part of the test contract.

If the server cannot prove `<H>`, the family fails as a whole. A new quote may retry on another complete family, but no partial value survives the switch.

## Executable Height Proof Modes

The implementation supports exactly three internal modes:

```text
RESTHeaderProof
  request: x-cosmos-block-height: H, plus ?height=H only when the route defines it
  accept:  the same response returns a positive x-cosmos-block-height exactly H

CometABCIProof
  request: the route's exact approved ABCI query path and encoded request at height H
  accept:  decode the business value from that ABCI response and require response.height == H

BodyHeightProof
  request: the route's documented historical-height input
  accept:  the authoritative response schema itself identifies the evaluated height exactly H
```

`BodyHeightProof` is opt-in per schema, never inferred from a generic `height`,
pagination, or latest-block field. `CometABCIProof` uses the Comet role paired
with the same provider family; it does not call REST for a value and Comet only
for a height. The family manifest pins exact network/endpoints, query
path/request encoding, query-only protobuf codec, decoder, proof mode, and
supported node revision range for sender account, spendable balance, network
fee, each Mimir key, auth params, node version, and recipient account
classification. `RESTHeaderProof` additionally requires one canonical
`x-cosmos-block-height` header, expected success status/media type, bounded
body, no redirect, and strict duplicate-key rejection. `BodyHeightProof`
relies only on its pinned authoritative body height and must not substitute a
header. Each ABCI proof requires the expected JSON-RPC envelope/id, `code == 0`,
canonical positive height, bounded response, and strict duplicate-key rejection
at every decoded level. These are trusted-provider coherence proofs, not
cryptographic application-state proofs; the provider trust boundary is
explicit. Transaction/signing codecs remain S2-03 scope.

Historic Liquify probes are retained only as rejected counterevidence for
header-stripped REST and the broken bulk ModuleAccounts route. They do not
populate the S2-02 manifest or authorize any family. The three THR-139
families require their own complete route matrix; until a family's fixture/live
status is `PASS`, it remains read-only. Bulk module enumeration is prohibited,
and query-only REST remains discovery/debug evidence that cannot authorize a
quote.

## Validation Rules

- Sender account must exist and decode to `/cosmos.auth.v1beta1.BaseAccount` or one of the same five pinned Cosmos `v0.53.0` vesting wrappers listed below, with exactly one embedded matching BaseAccount. A first-send account with `pub_key == nil` is valid. A non-null key must be secp256k1 and is retained for S2-04 equality with the signer key snapshot.
- `.exact` amount is positive native RUNE only and balance must cover checked `amount + native_tx_fee_rune`. The single-denom response must itself contain literal lowercase denom `rune`; a successful route/query with another or missing denom is rejected.
- `.maximum` resolves inside this snapshot to `spendableRune - native_tx_fee_rune`; the result must be positive and becomes the immutable quoted amount.
- `native_tx_fee_rune == 0` is valid and yields `totalDebit == amount`; missing, negative, malformed, or overflowing fee is not valid.
- Recipient must pass S2-01 local validation, the exact-height account classifier, and the versioned forbidden-module-address check below.
- Memo parameter must be a canonical positive bounded integer; memo UTF-8 byte count must not exceed it. Zero, negative, malformed, or overflowing parameters fail closed.
- Chain must not be halted by the exact rules below.
- Snapshot/quote creation time uses the injected monotonic clock; wall-clock Date is display only.

## Halt Rules

At height `H`, reject when:

```text
HaltChainGlobal > 0       && HaltChainGlobal <= H
NodePauseChainGlobal >= H
HaltTHORChain > 0         && HaltTHORChain <= H
SolvencyHaltTHORChain > 0 && SolvencyHaltTHORChain <= H
```

Read the four exact keys at `H` rather than inferring absence from the bulk map. THORNode's proven unset sentinel `-1` and value `0` are inactive for all four keys; values below `-1`, duplicated responses, overflow, malformed data, transport failure, or an unproven height fail closed. For `NodePauseChainGlobal`, a positive value is active exactly when it is greater than or equal to `H`.

## Module Recipient Rule

The broken bulk module-account endpoint is not used. At each H0/H1/H2 round the same family proves the THORNode semantic version and classifies the **specific recipient** through the exact-height Cosmos `Query/Account` response:

- `code == 0` requires a supported Any and an embedded canonical address payload exactly equal to the requested recipient. `/cosmos.auth.v1beta1.ModuleAccount` is rejected. The only accepted user types from pinned Cosmos SDK `v0.53.0` are `/cosmos.auth.v1beta1.BaseAccount` and `/cosmos.vesting.v1beta1.{BaseVestingAccount,ContinuousVestingAccount,DelayedVestingAccount,PeriodicVestingAccount,PermanentLockedAccount}`; each vesting decoder must unwrap to one matching BaseAccount. Any other Any, wrapper cycle/depth, missing base account, or address mismatch fails closed.
- Exact `codespace == "sdk"`, `code == 22`, zero response bytes, and response height exactly H is the only admissible account-absent result. For the pinned Comet JSON decoder, a unique `value` field that is absent, JSON `null`, or base64 `""` normalizes to zero bytes because protobuf bytes have an empty default; all three forms receive the same fixture. Any nonempty decoded bytes, invalid base64/type, duplicate `value` key, foreign/missing codespace, other code, or height mismatch fails closed. The historic rejected fixture used JSON `null`; it does not establish a native family.

Concrete account type is necessary but not sufficient. `ForbiddenModuleAddressSet` accepts only proven `Query/Version.current` and `.querier` values in the explicit set `{3.19.0, 3.19.1, 3.19.2, 3.19.3}`. These are backed by official tags/commits `v3.19.0@5f2141c3`, `v3.19.1@59a3e925`, `v3.19.2@c6fa8caa`, and `v3.19.3@52e66ad9`; all four have byte-identical `x/thorchain/helpers.go` SHA-256 `72ce4607cfcd45e1546e9c12d79afaeeb897946d0c9f3df31c14b8e05a3a98cf` and `x/thorchain/types/keys.go` SHA-256 `65f6e60694fa3667bf63805f1a933b357164f321bfb822f3459ffce05e5bae69`. Live height `27049190` reported `current=3.19.3` and `querier=3.19.0`, so both fields are required rather than conflated.

The generated set uses the exact pinned `IsModuleAccAddress` names `asgard`, `bond`, `reserve`, `lending`, `affiliate_collector`, `thorchain`, `tcy_claim`, `tcy_stake`, and `treasury` plus Cosmos SDK `v0.53.0`'s legacy no-derivation-key rule: `SHA256(UTF8(moduleName)).prefix(20)`, rendered with the selected network HRP. A recipient matching any derived 20-byte payload is rejected even if the account query unexpectedly decodes as a user account or NotFound. The manifest pins the ordered names and derivation vectors—including `thorchain` → `thor1v8ppstuf6e3x0r4glqc68d5jqcs2tf38cg2q6y`. Any current or querier version outside the explicit set makes the family send-ineligible until its exact tagged source and vectors are reviewed; implementation never assumes semantic-version range compatibility.

This is a versioned source-derived protocol set, not an operator-maintained address list. It protects the exact THORNode MsgSend rule even if the registered module-address set and the concrete stored account type disagree. Sending to the THOR module can become MsgDeposit and is outside Sprint 2; every other detected Cosmos module destination is also rejected conservatively.

## Revalidation Contract

S2-04 calls `revalidate` immediately before requesting the signature and again after the async signer returns, before journal persistence/broadcast. Revalidation never rereads the frozen quote height. It obtains a fresh exact-family lease through an internal refresh operation that bypasses cached height, requires the same family and a minimum height, revalidates identity, and cannot fall back to another family. It obtains a complete coherent snapshot from that family at fresh accepted heights:

```text
quote:       H0
pre-signer:  H1 >= H0
post-signer: H2 >= H1
```

A height rollback, mixed response height, or family switch fails closed. Each round reloads the complete sender account/sequence, spendable `rune`, fee, four Mimir keys, memo policy, node version, and recipient account classification before comparing:

- chain identity and accepted family;
- account number, sequence, and supported/null account public-key state;
- native fee and sufficient balance;
- halt decision;
- memo limit;
- node version and forbidden-module policy revision;
- recipient account/reserved-module status;
- quote expiry.

Snapshot differences return `SendError.quoteChanged` with `QuoteChanges(validating:)` and this nonempty exact mapping: family/chain → `.providerIdentity`; rollback → `.heightRollback`; account number → `.accountNumber`; sequence → `.sequence`; non-null account key state → `.accountPublicKey`; spendable sufficiency → `.balance`; fee → `.nativeFee`; halt → `.haltStatus`; memo limit → `.memoPolicy`; node version/policy revision/recipient classification → `.recipientPolicy`. An empty comparison returns unchanged success and cannot construct the error payload. Expiry returns `.quoteExpired`, not a changed set. Missing transport, unproven height, and unavailable/unsupported policy return `.providerUnavailable`, `.heightUnproven`, and `.policyUnavailable` respectively. Never silently change review values or ask a signer to approve old bytes.

Every request in H1 and H2 uses the same route-specific proof mode and pinned family capability as H0. `RESTHeaderProof`, `CometABCIProof`, and `BodyHeightProof` each require exact positive equality with the round height, which is the highest common height proven by every required role in that round. A route may not switch proof mode during one quote/send attempt. Current THORNode maps supported `?height=` values into SDK metadata, but query-only REST is never portable proof and is not accepted.

## Failure/Retry Policy

- A complete family may be retried/fail over only before a quote is returned.
- During send revalidation, family loss or mismatch expires the quote; it does not switch families.
- 429/503/backoff remains bounded by the Sprint 1 endpoint policy and the owned-operation race; dependency cooperation with cancellation is never required for caller liveness.
- No five-minute native-fee cache or cross-provider sequence maximum is allowed.

## Analog Delta

Vultisig proves the required THOR data categories but fetches them independently and caches native fee; THORNode supplies consensus rules. This design adds an atomic provider/height boundary. EvmKit's max-nonce strategy is rejected because a higher value from another provider cannot make a THOR snapshot coherent. The existing `ReadOperationCoordinator` task-group drain is also rejected as the liveness spine because a non-cooperative child can hold its owner; only its supporting lease/decoder facts are retained.

## Tests Before Implementation

- exact success fixtures cover every route's pinned proof mode and each of the three exact family IDs;
- ~~`RESTHeaderProof` requires exact request/response `x-cosmos-block-height`; a proxy-stripped
  or mismatched header fails that route rather than falling back silently~~ — **WITHDRAWN.** Two errors compounded here. The header name is wrong: cosmos
  gRPC-gateway returns `Grpc-Metadata-X-Cosmos-Block-Height`, and `x-cosmos-block-height`
  is the *request* header the client sets itself. And no mainnet provider we use (keplr,
  rorcual, ibs) returns a height header on these routes at all, so enforcing the rule
  blocked every send with `heightUnproven`. Height proof for REST routes is now disabled
  outright; the routes are unpinned while the snapshot still claims otherwise. Closing
  that gap needs a mechanism providers actually support — not a stricter rule.
- `CometABCIProof` decodes the value from the same ABCI response, requires `response.height == H`, and rejects wrong path/encoding, missing/mismatched height, and a REST-value/ABCI-height merge;
- `BodyHeightProof` is accepted only for a pinned schema whose authoritative evaluated-height field equals H; lookalike/latest/pagination heights fail;
- a THORNode fixture where `?height=H` executes or responds at `H+1` is rejected rather than accepted as pinned;
- missing/mismatched height for each endpoint;
- account absent/wrong Any/overflowing number or sequence;
- native fee zero/missing/malformed/overflowing and balance boundary; returned spendable denom missing/not exactly `rune` is rejected;
- all four Mimir keys unset as `-1` is a normal non-halted success fixture; `< -1` fails;
- every halt rule at `H-1`, `H`, `H+1` boundaries;
- recipient Account at exact height: BaseAccount and each of the five exact supported vesting wrappers, exact sdk/22 NotFound with absent/null/empty-base64 zero-byte encodings, nonempty/invalid/duplicate value rejection, ModuleAccount, nested/missing/embedded-address mismatch, unknown Any, foreign/missing codespace, and height mismatch;
- generated forbidden-module set covers every pinned `IsModuleAccAddress` name/vector and tag/file checksum, rejects an unexpected BaseAccount or NotFound at a reserved payload, accepts the live `current=3.19.3`/`querier=3.19.0` pair, and fails closed at `3.19.4`, `3.20.0`, malformed, or unproven version fields;
- live regression fixture proves bulk ModuleAccounts panic is not called and the recipient-specific normal/module probes remain exact-height;
- memo with multibyte UTF-8 exactly at and one byte over limit;
- memo parameter zero/negative/malformed/overflow rejection;
- cancellation at each request and between pages;
- runner deadline/cancellation/lifecycle precedence with an injected clock/sleeper, H0 attempt-token races, and a non-cooperative dependency that never resumes; the caller returns promptly and the late value is discarded;
- lease acquisition, every H0/H1/H2 route request, and backoff continuations that never resume or return late after cancellation/deadline; each caller returns promptly and no subsequent endpoint call starts;
- H0 suspended before/after any callback then `stop()` wins: the caller promptly receives `kitNotStarted`, a late value cannot start another route or insert a quote, and a rapid new `start()` has a different generation and cannot revive the old attempt;
- initial family failure may retry as a whole; no response from family A appears in family B quote;
- `.maximum` with balance above/equal/below fee and fee changes between H0/H1/H2;
- exact three-family/six-record manifest equality, each family's `PASS`/`FAIL`/`UNRUN` fixture/live status, Liquify absence, Cosmos/Comet role-height skew in both directions, exact-family refresh that bypasses cache and never falls back, manifest endpoint/revision mismatch, orphan caps/quarantine, a fixed SHA-256 digest vector, and before/after quote immutability;
- H0/H1/H2 monotonicity and rollback rejection; changes visible only at H1/H2 are detected before signer or discard its result.

## Verification

```text
swift test --filter SendPreflightCoordinatorTests
swift test --filter EndpointOperationRunnerTests
swift test --filter HaltEvaluatorTests
swift test --filter RecipientAccountClassifierTests
swift test --filter ForbiddenModuleAddressSetTests
swift test --filter SendPolicyTests
swift test
opt-in live or fixture preflight against each exact THR-139 family. Evidence
records capture ID, exact implementation head, one of the six manifest records,
route/proof mode, request/response schema version, timeout, redaction status,
and `PASS`, `FAIL`, or `UNRUN` with a reason; `UNRUN` never counts as `PASS`.
All three families are currently `UNRUN`/read-only, and a family remains
read-only until every required route has `PASS` evidence.
```

Each filtered command must fail if zero tests are discovered and must retain the XCTest summary; a skipped or unavailable filter is `UNRUN`, not pass. The local verification record maps each acceptance criterion to its named test and records public-error, digest-vector, common-height, exact-family, cancellation, orphan-cap, and quote-immutability results separately.

## Acceptance Criteria

- A quote proves every authoritative value from the same request that returned its route-specific height evidence, at one common height/family, and carries a fixed-algorithm internal digest.
- Native RUNE send preflight uses exactly the three THR-139 families and six role-bound endpoint records; Liquify is absent, and each family exposes explicit `PASS`, `FAIL`, or `UNRUN`/read-only status.
- Every missing/unproven required value fails closed with a stable public error.
- Module/memo/halt/fee/balance behavior matches pinned THORNode/Cosmos semantics.
- A stopped or superseded client lifecycle generation cannot start another H0 request or insert/return a quote.
- Revalidation uses a fresh exact-family lease, never mutates an existing quote or switches providers, and the test suite proves the frozen quote is byte-for-byte unchanged before and after revalidation.
- Tests demonstrate no cross-family or cross-height merge.

## Open Compatibility Evidence

Implementation must record the selected proof mode and live response shape for recipient Account success/NotFound/module variants, both node-version fields, exact-key Mimir, auth params, `/thorchain/network`, and spendable `rune` for each of the three exact families, with a capture ID, exact head, schema version, timeout, redaction result, and PASS/FAIL/UNRUN status. It must also retain the bulk ModuleAccounts panic as a regression counterexample proving that route is never selected. If any required route lacks one of the three accepted proofs, either proven node-version field leaves the explicit manifest set, or live/fixture compatibility evidence is absent, that family is read-only; a query-only value is never grandfathered in.
