# S2-03 — Local SIGN_MODE_DIRECT Codec

**Risk:** critical
**Depends on:** S2-01/S2-02 snapshot types
**Produces:** deterministic SignDoc, digest, TxRaw, and local transaction hash; no signer ownership or network broadcast

> **Amended.** The gas limit below is no longer what the codec uses. A send declares
> `6_000_000` and a deposit `600_000_000`, both matching the Android kit, which is the
> reference for anything the two kits can do alike. THORChain charges a fixed native fee
> rather than metering gas, so the declared limit does not change what a send costs. The
> THORNode example cited here remains the origin of the wire shape — message type, empty
> `Fee.amount`, denom — but no longer of the limit. Pinned digests were re-approved
> against the current limits.
>
> `MsgDeposit` was added after this slice: it carries its own memo inside the message
> while `TxBody.memo` stays empty, and it has no recipient.

## Verification policy

All builds, tests, mutants, simulator checks, Maestro checks, and other
verification for this slice run locally on the MacBook. GitHub Actions remains
disabled, is not an acceptance or merge gate, and must not be enabled or
dispatched without a new explicit operator approval for that exact run.

## Goal

Encode the exact THORChain native MsgSend/Cosmos direct-sign subset locally. The network cannot construct or alter sign bytes, and public APIs cannot expose protobuf implementation types.

## Dependencies and Generated Sources

Add `swift-protobuf` as an implementation dependency and generate/internalize only the pinned messages needed for:

- Cosmos base `Coin`;
- secp256k1 `PubKey`;
- `TxBody`, `ModeInfo`, `SignerInfo`, `Fee`, `AuthInfo`, `SignDoc`, `TxRaw`;
- THORChain `types.MsgSend`.

Generated files live under `Sources/ThorChainKit/Protocol/Generated/` with a checked-in source/protoc provenance manifest and deterministic regeneration script. The manifest pins THORNode `a759cb4f`, Cosmos SDK `v0.53.0`, `cosmossdk.io/api v0.9.2`, exact `protoc` and SwiftProtobuf plugin versions/checksums, include roots, and the complete regeneration command. They are internal and excluded from the public symbol allowlist.

## Proposed Areas and Functions

```text
Sources/ThorChainKit/Protocol/
  DirectSignCodec.swift
  MsgSendEncoder.swift
  TransactionHasher.swift
  Generated/*.pb.swift
  Generated/PROVENANCE.md
Scripts/generate-protobuf.sh
Tests/ThorChainKitTests/Protocol/
  MsgSendCodecGoldenTests.swift
  DirectSignGoldenTests.swift
  TransactionHasherTests.swift
  GeneratedProvenanceTests.swift
Tests/ThorChainKitTests/Fixtures/Send/*.json
```

Internal API:

```swift
func makeSignPayload(snapshot: SendSnapshot, quote: PreparedQuote, publicKey: Data) throws -> SignPayload
func makeTxRaw(payload: SignPayload, compactSignature: Data) throws -> SignedTransaction
func transactionId(txRaw: Data) -> TransactionID
```

`SignPayload` contains exact body/auth/sign bytes and digest but has a redacted description. `SignedTransaction` contains exact `TxRaw` and local hash and is internal until S2-05 journals it.
The codec enforces compact-signature framing only; production cryptographic
signature trust, including supplied-key matching, invalid/high-S rejection,
and signer ownership, belongs to S2-04.

## Canonical Encoding

1. `MsgSend.from_address`: raw 20-byte sender payload, field 1.
2. `MsgSend.to_address`: raw 20-byte recipient payload, field 2.
3. `MsgSend.amount`: one Cosmos Coin, field 3, with the literal lowercase denom `rune` and canonical positive decimal base-unit value.
4. Wrap message with type URL `/types.MsgSend`.
5. `TxBody` contains exactly one message and the validated memo; timeout/extensions are absent.
6. Wrap compressed 33-byte public key with `/cosmos.crypto.secp256k1.PubKey`.
7. One `SignerInfo`, `ModeInfo.Single.mode == 1`, snapshot sequence.
8. `Fee.amount` is empty and `gas_limit == 3_000_000`; no payer/granter.
9. `SignDoc` uses exact body/auth bytes, chain ID, and account number.
10. Digest is SHA-256 of serialized SignDoc.
11. `TxRaw` reuses the same body/auth bytes and one 64-byte compact signature.
12. Transaction ID is uppercase 64-character hex SHA-256 of exact serialized TxRaw.

Unknown fields, multiple messages/signers/signatures, fee coins, alternative sign mode, custom gas, timeout height, and arbitrary Any type URLs are rejected/not constructible.

## Golden Vectors

Three independent controls are mandatory:

1. reproduce the Vultisig fixture and its known digest `7e513b…1ebf` with its explicit legacy 20M gas parameter solely as a compatibility control;
2. reproduce the Vultisig-input unsigned official-gas control: digest `83a508ff301fc5cf7ab5126d861e7bac8dd1ebc5691df4842d6b2ac84dd3668f` and SignDoc length 193;
3. pin and verify the complete deterministic signed official-gas fixture below. Production construction has no gas parameter and can only use `3_000_000`; the 20M helper cannot be imported by product sources.

The authoritative gas/wire example is THORNode `docs/cli/multisig.md` at commit `a759cb4f99b1a13d5d94ace1dddcaf25c165641f`, lines 27–56, Git blob `537cac65592828fb0f10dbf2d75edf51eaa4be67`, full-file SHA-256 `27e39d943dee5744df87d87ef29828c8b34f51ae8bb4a7504fe4c98716d2649c`. It fixes `/types.MsgSend`, denom `rune`, empty `Fee.amount`, and gas `3_000_000`.

The signed fixture is named `thorchain_native_send_scalar_1_rfc6979`. “Scalar 1” identifies a public cryptographic test vector, never production key material; the repository fixture contains only public key/signature/serialized outputs. Inputs are chain ID `thorchain-1`, account number `123456`, sequence `1`, empty memo, amount `100000000` base units, sender `thor1w508d6qejxtdg4y5r3zarvary0c5xw7ku6wp68`, recipient `thor1tgxm5jw6hrlvslrd6lqpk4jwuu4g29dxytrean`, and compressed public key:

```text
0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798
```

The complete 193-byte SignDoc hashes to `1ff56dd4c3627af0cee040965178f50c8d7c854e909d7b54aedbd1b7bf110b68`. The independently verified RFC6979 low-S compact signature is:

```text
23103daa64330d051da3bfa85ea7c8af9080edf19b19a306403303634b0992a32cc1b9061b2e76cd245edb2976bb437bc6636dfb23deae31e38508c5478dae45
```

The complete 242-byte TxRaw is:

```text
0a530a510a0e2f74797065732e4d736753656e64123f0a14751e76e8199196d454941c45d1b3a323f1433bd612145a0dba49dab8fec87c6dd7c01b564ee72a8515a61a110a0472756e65120931303030303030303012590a500a460a1f2f636f736d6f732e63727970746f2e736563703235366b312e5075624b657912230a210279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f8179812040a0208011801120510c08db7011a4023103daa64330d051da3bfa85ea7c8af9080edf19b19a306403303634b0992a32cc1b9061b2e76cd245edb2976bb437bc6636dfb23deae31e38508c5478dae45
```

Its uppercase transaction ID is `3685BF7AD0C65889B763D4B6D1F1EDEEC96E9B63B63F8DB992D00757EB5F136E`. The golden test independently decodes every field and uses an independent test oracle to verify the static compact signature over the exact SignDoc digest with the pinned public key. This oracle is fixture evidence, not production signer-trust behavior. The test fails on any signature framing or one-bit TxRaw change.

## Validation and Trust

- Require exactly 20-byte address payloads and a canonical 33-byte compressed public-key encoding before encoding.
- Convert arbitrary-precision amounts/account numbers/sequence to protobuf fields with explicit overflow errors.
- Require canonical decimal amount text; no sign, whitespace, leading plus, exponent, or locale formatting.
- Do not log or interpolate SignDoc, digest, signature, or TxRaw bytes.
- Hash functions accept exact Data; reserialization after signing is prohibited.
- Enforce exactly one 64-byte compact signature for TxRaw framing, without
  deciding cryptographic validity, low-S policy, or key/signature matching;
  those signer-trust checks are S2-04 behavior.

## Analog Delta

Vultisig's helper proves the THOR transaction assembly order but delegates to WalletCore/MPC and uses 20M gas. THORNode proto/TxConfig is authoritative. Tron generated protobuf demonstrates SwiftProtobuf feasibility but not THOR semantics. The package owns a deliberately narrow codec rather than a generic Cosmos transaction framework.

## Tests Before Implementation

- complete byte-for-byte golden vectors for every intermediate value, including the literal signed scalar-one vector above;
- independent decode round-trip asserts type URLs and semantic fields;
- every full golden decode asserts denom bytes equal exactly `rune`;
- field-order/determinism across repeated runs;
- address/public-key length and invalid key cases;
- amount/account/sequence boundaries and overflow;
- memo empty/ASCII/multibyte;
- signature length zero/63/64/65 for TxRaw construction;
- independent verification of the pinned static fixture as a test oracle only;
- production invalid/high-S/wrong-key and supplied-key trust vectors remain in
  S2-04;
- produced local hash format and single-bit TxRaw mutation;
- public symbol/import audit proves no generated/SwiftProtobuf type escapes;
- provenance test pins proto source revisions and regeneration produces no diff.

## Verification

```text
Scripts/generate-protobuf.sh --check
swift test --filter MsgSendCodecGoldenTests
swift test --filter DirectSignGoldenTests
swift test --filter GeneratedProvenanceTests
swift test
public symbol allowlist audit
```

## Acceptance Criteria

- Official-gas and independent compatibility vectors match complete expected bytes/hashes.
- Production cannot encode any operation other than one native MsgSend direct-sign transaction.
- Sign bytes are constructed without network assistance.
- No public API or debug/error surface exposes protobuf internals or sensitive bytes.
- Generation is reproducible from pinned authoritative proto sources.

## Pinned Decision

This is a transaction-specific codec, not a reusable Cosmos SDK. MsgDeposit and other messages require later specs and distinct golden vectors.
