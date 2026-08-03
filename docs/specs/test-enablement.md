# Deterministic test execution

**Status:** resolved. All three defects below are fixed: `swift test` runs the
deterministic suite from a clean checkout, and the wallet's ThorChain tests run
through the Development scheme. The one remaining failure is by design —
`ThorChainKitLiveTests` refuses to run without `THORCHAIN_RUN_LIVE=1`.

Kept as the record of what was broken and why. Supersedes part of
`docs/specs/ci/build-only-github-actions.md` — see "Policy delta" below.

## Problem

The kit ships 61 deterministic test files and the wallet ships four
ThorChain test files. **None of them can be executed by any supported
command**, and this has been true since `0874f0d9`.

Three independent defects compose:

1. `swift build` fails with 49 errors before reaching any test. Every error
   is in the transitive dependency `HsExtensions`, none in `ThorChainKit`.
2. The wallet's ThorChain test files contain a mass-replace artefact,
   `#expecttry (…)`, which is not a Swift directive.
3. `.gitignore` silently excludes the production `Sources/` directory, so a
   fix that adds a file can be lost before it is ever reviewed. The rule
   exists only to hide a vendored copy of a third-party application that
   should never have been inside the package root.

The result is that no automated barrier protects any behaviour in this
package. Every finding in `thorchain-audit-2026-07-30.md` passed CI green.

## Evidence

`HsExtensions.Swift/Package.swift` declares `platforms: [.iOS(.v13)]` and
does not declare macOS at all. SwiftPM therefore assumes the macOS 10.13
default, while the sources use Combine and Swift Concurrency, which require
10.15:

```
error: 'Task' is only available in macOS 10.15 or newer
error: 'PassthroughSubject' is only available in macOS 10.15 or newer
error: 'AnyPublisher' / 'eraseToAnyPublisher()' / 'cancel()' / 'isCancelled'
```

The iOS deployment target is not involved. Raising it changes nothing.

`HsCryptoKit` already declares `.macOS(.v10_15)` and depends on
`HsExtensions` as `.upToNextMajor(from: "1.0.0")`, so a `1.0.7` tag
propagates without any change to `HsCryptoKit` or to `ThorChainKit`'s
manifest.

Measured, in this order, against a scratch checkout:

| Step | Result |
|---|---|
| `swift build` HsExtensions with the platform line added | `Build complete!`, no source changes required |
| `swift build` ThorChainKit against it | `Build complete! (40.24s)`, 0 errors, 951 modules |
| `swift test --filter ThorChainKitTests` | `Executed 275 tests, with 0 failures` in 2.055 s |

`git check-ignore -v Sources/ThorChainKit/Storage/ZZZProbe.swift` resolves to
`.gitignore:10:sources/` and exits 0, with `core.ignorecase = true`. The rule
was written for `sources/vultisig-ios`, but APFS matches it case-insensitively
and it therefore also covers the production `Sources/` tree.

`sources/vultisig-ios` is a 655 MB full clone of `vultisig/vultisig-ios`,
nested inside the package root, at commit `d3123dbe6ef1103937c272a8b1cd81f613af0acc`.
`research-cache/vultisig-ios-d3123dbe` holds the same revision in 15 MB, and
every specification that cites Vultisig — `thorchainkit-analog-conformance.md`,
`S1-02`, `S1-03` — cites that path, not the in-package one. `AGENTS.md:21`
requires treating Vultisig as supporting evidence but prescribes no location.
The in-package copy is therefore a redundant duplicate whose only effect on
the repository is the ignore rule that broke `Sources/`.

## Design

### Platform

`ThorChainKit` already declares `.macOS(.v10_15)`. That declaration is
currently false: the package does not build for macOS. Two coherent
resolutions exist, and this spec takes the first.

**Chosen — make the declaration true.** Add macOS to `HsExtensions`. The
whole deterministic suite then runs in about two seconds with no simulator,
no device runtime download, and no `xcodebuild`.

**Rejected — drop `.macOS(.v10_15)` and align with the other kits as
iOS-only.** `HsCryptoKit` is the only `Hs*` package that declares macOS;
`HsExtensions`, `HsToolKit`, `EvmKit`, `TronKit`, `BitcoinCore`,
`BitcoinKit` and `BitcoinCashKit` are all iOS-only, so `ThorChainKit` is the
outlier and alignment is defensible. It was rejected because it costs more,
not less: `swift test` becomes impossible, tests must run through an iOS
Simulator destination, and the repository currently has **no shared scheme
for any test target** — only the two Example app schemes are checked in.
`xcodebuild test -scheme ThorChainKit` fails with `Scheme ThorChainKit is
not currently configured for the test action`. That route therefore needs a
committed scheme on top of everything else.

### Compatibility of the HsExtensions change

Adding a platform is additive: it widens support and narrows nothing. No
consumer that builds today can regress, because **nothing in this dependency
branch builds for macOS today**. The only behavioural change is that a
consumer which itself declares a macOS target below 10.15 would now fail at
manifest resolution with a clear message instead of failing later with
opaque availability errors.

`HsExtensions` is a shared dependency of every wallet kit, so the change is
made upstream and tagged rather than forked or vendored.

### Policy delta, when CI lands

`docs/specs/ci/build-only-github-actions.md` states that hosted CI proves
only that the Example compiles, and that "all tests and acceptance evidence
remain local to the operator MacBook". That policy was written when running
the suite in CI meant booting a simulator.

That premise no longer holds. `swift test` needs no simulator and the suite
completes in about two seconds of test time. When the kits are published, one
job is therefore added and the existing build-only job is left untouched:

- the existing manually dispatched Example build is unchanged;
- a new `swift test` job runs on `pull_request`;
- no simulator, device runtime, or acceptance flow is added to CI.

Live/network tests stay out of CI: `ThorChainKitLiveTests` is a separate
target and remains opt-in, exactly as before.

This is a deliberate amendment to that policy, not an oversight of it.

## Steps

| # | Change | Repository |
|---|---|---|
| 1 | Add `.macOS(.v10_15)` to `platforms` | `HsExtensions.Swift` |
| 2 | Consume the patched HsExtensions locally, unpublished | `ThorChainKit.Swift` |
| 3 | `#expecttry (X)` → `#expect(try X)`, 8 occurrences in 2 files | `unstoppable-wallet-ios` |
| 4 | Withdrawn — no product dependency is needed, see below | `unstoppable-wallet-ios` |
| 5 | Delete `sources/vultisig-ios`; drop the ignore rule entirely | `ThorChainKit.Swift` |
| 6 | Deferred: `swift test` job on `pull_request` | `ThorChainKit.Swift` |

### Local linking until the kits are published together

The kits are released as a set, so no tag is cut for this change on its own.
Until that release:

- the wallet consumes `ThorChainKit` through `.package(path:)` rather than a
  pinned revision;
- `ThorChainKit` consumes the patched `HsExtensions` through
  `swift package edit HsExtensions.Swift --path <local clone>`, which records
  the override in `.build` and a `Packages/` symlink and leaves both
  `Package.swift` and `Package.resolved` untouched.

Neither substitution is committed, so nothing in either repository asserts a
dependency that does not exist yet.

Step 6 is deferred for the same reason and is **not** landed here. A hosted
runner clones only this repository and resolves `HsExtensions` from source
control, where the macOS platform is still absent, so the job would be red on
every pull request. A permanently red required check is worse than no check:
it trains reviewers to ignore CI. The workflow lands in the same change that
publishes the kits.

Until then the suite is a local command:

```
swift test --filter ThorChainKitTests
```

### On release, this must be reverted

Both substitutions are temporary and neither fails loudly when forgotten.
The release change must, in one commit: tag `HsExtensions` `1.0.7`; run
`swift package unedit HsExtensions.Swift` and refresh `Package.resolved`;
restore the wallet's pinned `.package(url:revision:)` and its
`XCRemoteSwiftPackageReference`; and land the `swift test` workflow.

Step 5 lands first. Until it does, any file added under `Sources/` by a
later step is silently dropped by `git add`.

Step 5 removes the directory rather than narrowing the rule to
`/sources/vultisig-ios/`. A narrowed rule would close the immediate hole but
keep a 655 MB duplicate of an already-pinned reference inside the package
root, where the next `git add -f`, archive, or tree-walking indexer can pull
it back in. Reference material belongs outside the package; the canonical
copy in `research-cache` is what the specifications already cite.

Steps 2 and 6 cannot complete until the `1.0.7` tag is published, because
SwiftPM resolves `HsExtensions` from source control, not from a local path.
Step 1 is therefore prepared locally and pushed as a separate, explicit act.

Step 3 restores the assertions but does not add any: the two files are
returned to the state they were in before the mass-replace. Widening
coverage is Phase 4 of the action plan, not this spec.

### Why step 4 was withdrawn

`0874f0d9` removed the `ThorChainKit` product dependency from AppTests at the
same time as it corrupted the assertions, so the two looked like one
regression. They are not: removing the dependency was correct.

AppTests already imports `EvmKit`, `TronKit`, `HsCryptoKit`, `GRDB` and
`MarketKit` while declaring none of them. A test bundle compiles against
whatever modules are in its search path and resolves their symbols from the
host application, so `import ThorChainKit` needs no product dependency of its
own. Measured: with no dependency declared, all five files under
`Tests/ThorChain` compile with zero errors, including the three that import
`ThorChainKit`.

Declaring it is also harmful. It forces the package graph to link
swift-crypto's `Crypto` product as a dynamic framework. On Apple platforms
that module is only `@_exported import CryptoKit`, so it contains no symbols,
its framework is emitted with an `Info.plist` and no binary, and HsCryptoKit
fails with `no such file or directory: Crypto_…_PackageProduct`. Observed on
four builds with the dependency declared and on none without it.

This was diagnosed the wrong way round at first: the failure was called
pre-existing and unrelated because it appeared in a dependency the App target
already pulled in. A control build with only the dependency reverted
disproved that. Correlation across builds, not reasoning about the graph, is
what settled it.

## Verification

1. `swift build` in `ThorChainKit.Swift` exits 0. **Met**: `Build complete!`
2. `swift test --filter ThorChainKitTests` reports 275 tests, 0 failures.
   **Met**: `Executed 275 tests, with 0 failures` in 2.199 s, exit 0, in this
   repository rather than a scratch copy.
3. `git check-ignore Sources/ThorChainKit/<new file>` exits 1, `Sources/`
   contains only `ThorChainKit`, and `.gitignore` no longer names Vultisig.
   **Met**: exit 1; `Sources/` fell from 656 MB to 1.1 MB with all 99 kit
   files intact.
4. `grep -rn '#expecttry' Unstoppable/Tests` returns nothing. **Met**.
5. Every file under `Tests/ThorChain` compiles. **Met**: all five compile
   with zero errors. Build through `Wallet.xcworkspace` and a concrete arm64
   simulator id — `-project Unstoppable.xcodeproj` cannot see the local
   `packages/WalletCore`, and `generic/platform=iOS Simulator` builds x86_64,
   which `MoneroZano.xcframework` does not carry.

   The AppTests target as a whole still fails to build, on a defect unrelated
   to this work and older than it: `Tests/Modules/MultiSwap/SwapExecutableTests.swift:188`
   dereferences `CreatedTransactionResponse?` without unwrapping. So the test
   target has been broken in two independent places, which is further evidence
   that nobody runs it. Fixing that file is out of scope here, but the target
   cannot go green until it is fixed.
6. On publication, the CI job goes red on a branch that reintroduces any of
   the above.

Check 6 is what distinguishes this work from a cosmetic fix. Until a
deliberately broken branch turns the job red, the barrier is unproven — and
until the kits are published, that check cannot be performed at all.

## Non-goals

- No new test cases. Coverage gaps — the missing cross-platform seed vector,
  the low-S boundary, the untested converter and adapter — are Phase 4.
- No change to `HsCryptoKit`, which already declares macOS correctly.
- No change to `ThorChainKit`'s own manifest beyond `Package.resolved`.
- No simulator or acceptance runs in CI.
