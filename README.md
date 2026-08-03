# ThorChainKit.Swift

Native THORChain SDK for iOS — RUNE and THORChain-native assets (TCY, RUJI, secured assets).

- HD key derivation `m/44'/931'/0'/0/0`, bech32 `thor1...` addresses
- Cosmos-style protobuf transaction signing (`SIGN_MODE_DIRECT`) with THORChain's native `MsgSend` / `MsgDeposit`
- THORNode for balances, account state, fees, and broadcast; CometBFT for chain identity and height
- Midgard for transaction history
- Networks: `mainnet` (prefix `thor`) and `stagenet` (prefix `sthor`)

## Denoms

The kit is denom-agnostic: balances and sends work with plain bank denom strings.
All THORChain native assets are bank denoms with **8 decimals**:

| Denom | Asset | Kind |
|---|---|---|
| `rune` | `THOR.RUNE` | native |
| `tcy` | `THOR.TCY` | native token |
| `x/ruji` | `THOR.RUJI` | native token |
| `btc-btc` | `BTC-BTC` | secured asset |
| `btc/btc` | `BTC/BTC` | synth (deprecated) |

`Denom.asset(for:)` / `Denom.denom(for:)` convert between the two notations. Only the
denoms listed above round-trip exactly, so a send takes the bank denom itself instead of
deriving it from an asset. Naming and metadata for these tokens live on the wallet side;
the kit does not carry a token list.

The network fee is charged in RUNE whatever moves, so sending a token needs a RUNE balance
on top of the token balance.

## Usage

```swift
let address = try Signer.address(seed: seed, network: .mainnet)
let kit = try Kit.instance(address: address, walletId: walletId, endpoints: endpoints)
kit.start()

kit.balance(denom: .rune)                       // base units, 8 decimals
kit.transactions(descending: true, limit: 50)

// A send is quoted first: the quote pins the account state it was built from and
// expires, so nothing signs against a snapshot the chain has moved past.
let quote = try await kit.quote(to: recipient, amount: .exact(amount), denom: .rune)
let submission = try await kit.send(quote: quote, signer: signer)

// A deposit addresses the chain itself: it has no recipient, and the memo is the
// instruction rather than a note.
let deposit = try await kit.depositQuote(asset: .rune, denom: .rune, amount: .exact(amount), memo: memo)
```

`submission.state` is either `checkTxAccepted` or `unknown`. `unknown` means no node
confirmed the broadcast and the transaction may still be included — track it rather than
sending it again.

`Signer.instance(seed:)` and `Signer.instance(privateKey:)` build the conventional signer.
`ISigner` is the seam an external signer implements, so a hardware device or a test double
can drive the same pipeline without holding a seed.

## Installation

Swift Package Manager:

```swift
.package(url: "https://github.com/horizontalsystems/ThorChainKit.Swift", exact: "1.0.0"),
```

Requires iOS 13 / macOS 10.15 and Swift 5.10.

## Modules

- `Sources/ThorChainKit` — the library
- `iOS Example` — sample app

## License

MIT
