import Foundation
import BigInt
import Combine
import Darwin
import XCTest
@testable import ThorChainKit

final class PublicApiTests: XCTestCase {
    func testNetworkConstants() throws {
        XCTAssertEqual(Network.mainnet.environment, .mainnet)
        XCTAssertEqual(Network.mainnet.expectedChainId, "thorchain-1")
        XCTAssertEqual(Network.mainnet.accountHrp, "thor")
        XCTAssertEqual(Network.mainnet.coinType, 931)

        let stagenet = try Network.stagenet(expectedChainId: "stage-1")
        XCTAssertEqual(stagenet.environment, .stagenet)
        XCTAssertEqual(stagenet.expectedChainId, "stage-1")
        XCTAssertEqual(stagenet.accountHrp, "sthor")
        XCTAssertEqual(stagenet.coinType, 931)

        let chainnet = try Network.chainnet(expectedChainId: "chain-1")
        XCTAssertEqual(chainnet.environment, .chainnet)
        XCTAssertEqual(chainnet.expectedChainId, "chain-1")
        XCTAssertEqual(chainnet.accountHrp, "cthor")
        XCTAssertEqual(chainnet.coinType, 931)
    }

    func testNetworkRejectsBlankOrControlContainingChainId() throws {
        XCTAssertNoThrow(try Network.stagenet(expectedChainId: String(repeating: "a", count: 50)))
        XCTAssertNoThrow(try Network.stagenet(expectedChainId: String(repeating: "é", count: 25)))

        for chainId in [
            "",
            "   \n",
            "chain\u{0}id",
            String(repeating: "a", count: 51),
            String(repeating: "é", count: 26),
        ] {
            assertThrows(KitConfigurationError.invalidChainId) {
                try Network.chainnet(expectedChainId: chainId)
            }
        }
    }

    func testNetworkPersistenceKeyIncludesEnvironmentAndExactChainId() throws {
        XCTAssertEqual(Network.mainnet.persistenceKey, "mainnet\0thorchain-1")
        XCTAssertEqual(
            try Network.stagenet(expectedChainId: "stage-1").persistenceKey,
            "stagenet\0stage-1"
        )
        XCTAssertNotEqual(
            try Network.stagenet(expectedChainId: "stage-1").persistenceKey,
            try Network.chainnet(expectedChainId: "stage-1").persistenceKey
        )
    }

    func testEndpointConfigurationNormalizesAndAcceptsSingleFamilyDefaults() throws {
        let family = try EndpointFamilyDescriptor(
            id: " primary ",
            cosmosRestURL: URL(string: "https://rest.example.com/path")!,
            cometBftURL: URL(string: "https://rpc.example.com")!
        )
        let configuration = try EndpointConfiguration(
            families: [family],
            clientId: " client-1 "
        )

        XCTAssertEqual(family.id, "primary")
        XCTAssertEqual(configuration.clientId, "client-1")
        XCTAssertEqual(configuration.requestTimeout, 15)
        XCTAssertEqual(configuration.policy, .default)
        XCTAssertEqual(configuration.effectiveMaximumAttempts, 1)
        XCTAssertEqual(EndpointPolicy.default.maximumHeightLag, 5)
        XCTAssertEqual(EndpointPolicy.default.identityRevalidationInterval, 300)
        XCTAssertEqual(EndpointPolicy.default.retryableStatusCodes, [408, 429, 502, 503, 504])
        XCTAssertNil(EndpointPolicy.default.maximumAttempts)
        XCTAssertEqual(EndpointPolicy.default.maximumBalancePageCount, 100)
    }

    func testEndpointConfigurationRejectsInvalidValues() throws {
        let first = try family(id: "first")
        let second = try family(id: "second")

        assertEndpointError(.emptyFamilies) {
            try EndpointConfiguration(families: [])
        }
        assertEndpointError(.duplicateFamilyId("first")) {
            try EndpointConfiguration(families: [first, try self.family(id: " first ")])
        }
        for invalidId in ["", " \n ", "bad\u{7f}id"] {
            assertEndpointError(.invalidFamilyId) {
                try self.family(id: invalidId)
            }
        }

        for url in [
            URL(string: "http://rest.example.com")!,
            URL(string: "https:///missing-host")!,
        ] {
            assertEndpointError(.insecureURL) {
                try EndpointFamilyDescriptor(
                    id: "invalid",
                    cosmosRestURL: url,
                    cometBftURL: URL(string: "https://rpc.example.com")!
                )
            }
        }
        for url in [
            URL(string: "https://user:pass@rest.example.com")!,
            URL(string: "https://rest.example.com?query=1")!,
            URL(string: "https://rest.example.com#fragment")!,
        ] {
            assertEndpointError(.urlContainsCredentialsQueryOrFragment) {
                try EndpointFamilyDescriptor(
                    id: "invalid",
                    cosmosRestURL: url,
                    cometBftURL: URL(string: "https://rpc.example.com")!
                )
            }
        }

        XCTAssertNil(try EndpointConfiguration(families: [first], clientId: " \n ").clientId)
        assertEndpointError(.invalidClientId) {
            try EndpointConfiguration(families: [first], clientId: "bad\u{1f}id")
        }
        for timeout in [0, -1, .infinity, .nan] {
            assertEndpointError(.invalidPolicyField("requestTimeout")) {
                try EndpointConfiguration(families: [first], requestTimeout: timeout)
            }
        }

        for lag in [-1] {
            assertEndpointError(.invalidPolicyField("maximumHeightLag")) {
                try EndpointPolicy(maximumHeightLag: Int64(lag))
            }
        }
        for interval in [0, -1, .infinity, .nan] {
            assertEndpointError(.invalidPolicyField("identityRevalidationInterval")) {
                try EndpointPolicy(identityRevalidationInterval: interval)
            }
        }
        assertEndpointError(.invalidPolicyField("retryableStatusCodes")) {
            try EndpointPolicy(retryableStatusCodes: [408, 500])
        }
        for pageCount in [0, 1001] {
            assertEndpointError(.invalidPolicyField("maximumBalancePageCount")) {
                try EndpointPolicy(maximumBalancePageCount: pageCount)
            }
        }
        assertEndpointError(.invalidPolicyField("maximumAttempts")) {
            try EndpointPolicy(maximumAttempts: 0)
        }
        let excessiveAttempts = try EndpointPolicy(maximumAttempts: 3)
        assertEndpointError(.invalidPolicyField("maximumAttempts")) {
            try EndpointConfiguration(families: [first, second], policy: excessiveAttempts)
        }

        let explicit = try EndpointConfiguration(
            families: [first, second],
            policy: try EndpointPolicy(maximumAttempts: 1)
        )
        XCTAssertEqual(explicit.effectiveMaximumAttempts, 1)
        let implicit = try EndpointConfiguration(families: [first, second])
        XCTAssertEqual(implicit.effectiveMaximumAttempts, 2)
    }

    func testDenomAcceptsRuneAndRejectsInvalidValues() throws {
        XCTAssertEqual(Denom.rune.rawValue, "rune")
        XCTAssertEqual(try Denom(rawValue: "abc").rawValue, "abc")
        XCTAssertEqual(try Denom(rawValue: "ibc/ABC:_-.").rawValue, "ibc/ABC:_-.")
        XCTAssertNoThrow(try Denom(rawValue: "a" + String(repeating: "1", count: 127)))

        for value in [
            "ab",
            "1bc",
            "åbc",
            "a bc",
            "ab@",
            "a" + String(repeating: "1", count: 128),
        ] {
            assertThrows(KitConfigurationError.invalidDenom) {
                try Denom(rawValue: value)
            }
        }
    }

    func testStateModelsEnforceAccountExistenceAndStableSyncErrors() throws {
        let present = try accountState(accountNumber: 1, sequence: 2, balances: [.rune: 3], exists: true)
        XCTAssertTrue(present.exists)
        XCTAssertEqual(present.balances[.rune], 3)

        let absent = try accountState(accountNumber: nil, sequence: nil, balances: [:], exists: false)
        XCTAssertFalse(absent.exists)
        XCTAssertTrue(absent.balances.isEmpty)

        let invalid: [(UInt64?, UInt64?, [Denom: BigUInt], Bool)] = [
            (1, nil, [:], true),
            (nil, 1, [:], true),
            (nil, nil, [:], true),
            (1, 1, [:], false),
            (nil, nil, [.rune: 1], false),
        ]
        for (accountNumber, sequence, balances, exists) in invalid {
            XCTAssertThrowsError(
                try accountState(
                    accountNumber: accountNumber,
                    sequence: sequence,
                    balances: balances,
                    exists: exists
                )
            )
        }

        XCTAssertEqual(
            [
                SyncError.noConnection,
                .rateLimited,
                .wrongNetwork,
                .nodeUnavailable,
                .invalidResponse,
                .storageUnavailable,
                .internalInvariant,
            ],
            [
                .noConnection,
                .rateLimited,
                .wrongNetwork,
                .nodeUnavailable,
                .invalidResponse,
                .storageUnavailable,
                .internalInvariant,
            ]
        )
        XCTAssertEqual(SyncState.idle(cached: false), .idle(cached: false))
    }

    func testAddressCanonicalizesValidNetworksAndUppercase() throws {
        let vectors: [(String, Network)] = [
            ("thor1x0jkvqdh2hlpeztd5zyyk70n3efx6mhudkmnn2", .mainnet),
            ("sthor1x0jkvqdh2hlpeztd5zyyk70n3efx6mhue08995", try .stagenet(expectedChainId: "stage-1")),
            ("cthor1x0jkvqdh2hlpeztd5zyyk70n3efx6mhupxcqek", try .chainnet(expectedChainId: "chain-1")),
        ]

        for (raw, network) in vectors {
            let address = try Address(raw, network: network)
            XCTAssertEqual(address.raw, raw)
            XCTAssertEqual(address.description, raw)
            XCTAssertEqual(address.network, network)
            XCTAssertEqual(address.payload.map { String(format: "%02x", $0) }.joined(), "33e56601b755fe1c896da0884b79f38e526d6efc")
            XCTAssertEqual(try Address(raw.uppercased(), network: network).raw, raw)
        }
    }

    func testAddressRejectsStructureCaseAndCanonicalViolations() throws {
        for raw in [
            "",
            " thor1x0jkvqdh2hlpeztd5zyyk70n3efx6mhudkmnn2",
            "Thor1x0jkvqdh2hlpeztd5zyyk70n3efx6mhudkmnn2",
            "thor",
            "thor1invalidbcharacter",
            String(repeating: "a", count: 91),
            "THOR1x0jkvqdh2hlpeztd5zyyk70n3efx6mhuldgh54",
        ] {
            XCTAssertThrowsError(try Address(raw, network: .mainnet), "accepted \(raw)")
        }
    }

    func testAddressRejectsClassicChecksumAndBech32m() throws {
        assertAddressError(.invalidChecksum) {
            try Address("thor1x0jkvqdh2hlpeztd5zyyk70n3efx6mhudkmnnq", network: .mainnet)
        }
        assertAddressError(.invalidChecksum) {
            try Address("thor1x0jkvqdh2hlpeztd5zyyk70n3efx6mhuc2tlkg", network: .mainnet)
        }
    }

    func testAddressRejectsWrongHrp() throws {
        assertAddressError(.wrongHrp(expected: "sthor", actual: "thor")) {
            try Address(
                "thor1x0jkvqdh2hlpeztd5zyyk70n3efx6mhudkmnn2",
                network: .stagenet(expectedChainId: "stage-1")
            )
        }
    }

    func testAddressRejectsInvalidPaddingOrPayloadLength() throws {
        assertAddressError(.invalidPadding) {
            try Address("thor1pl86cm8", network: .mainnet)
        }
        assertAddressError(.invalidPayloadLength(expected: 20, actual: 19)) {
            try Address("thor1x0jkvqdh2hlpeztd5zyyk70n3efx6msz7dska", network: .mainnet)
        }
        assertAddressError(.invalidPayloadLength(expected: 20, actual: 21)) {
            try Address("thor1x0jkvqdh2hlpeztd5zyyk70n3efx6mhuqqt3psdz", network: .mainnet)
        }
    }

    func testFactoryRejectsWhitespaceOnlyWalletId() throws {
        let address = try Address(
            "thor1x0jkvqdh2hlpeztd5zyyk70n3efx6mhudkmnn2",
            network: .mainnet
        )
        for walletId in ["", " ", "\n\t"] {
            assertThrows(KitConfigurationError.invalidWalletId) {
                try Kit.instance(
                    address: address,
                    walletId: walletId,
                    endpoints: try self.endpoints()
                )
            }
        }
    }

    func testFactoryDerivesNetworkFromAddress() throws {
        let vectors: [(String, Network)] = [
            ("thor1x0jkvqdh2hlpeztd5zyyk70n3efx6mhudkmnn2", .mainnet),
            ("sthor1x0jkvqdh2hlpeztd5zyyk70n3efx6mhue08995", try .stagenet(expectedChainId: "stage-1")),
            ("cthor1x0jkvqdh2hlpeztd5zyyk70n3efx6mhupxcqek", try .chainnet(expectedChainId: "chain-1")),
        ]

        for (raw, network) in vectors {
            let address = try Address(raw, network: network)
            let kit = try Kit.instance(
                address: address,
                walletId: "wallet-01",
                endpoints: endpoints()
            )
            XCTAssertEqual(kit.address, address)
            XCTAssertEqual(kit.network, address.network)
        }
    }

    func testFactoryCreatesNoWorkAndDoesNotStartLifecycle() throws {
        let kit = makeTestKit(address: try Address(
            "thor1x0jkvqdh2hlpeztd5zyyk70n3efx6mhudkmnn2",
            network: .mainnet
        ))
        XCTAssertNil(kit.lastBlockHeight)
        XCTAssertEqual(kit.syncState, .idle(cached: false))
        XCTAssertNil(kit.accountState)
        XCTAssertEqual(kit.runeBalance, 0)
        XCTAssertFalse(kit.accountExists)

        let factoryKit = try Kit.instance(
            address: kit.address,
            walletId: "wallet-01",
            endpoints: endpoints()
        )
        XCTAssertNil(factoryKit.lastBlockHeight)
        XCTAssertEqual(factoryKit.syncState, .idle(cached: false))
        XCTAssertNil(factoryKit.accountState)
        XCTAssertEqual(factoryKit.runeBalance, 0)
        XCTAssertFalse(factoryKit.accountExists)
    }

    func testInitialPublishersAllowReentrantSnapshotAndLifecycleAccess() throws {
        let kit = makeTestKit(address: try Address(
            "thor1x0jkvqdh2hlpeztd5zyyk70n3efx6mhudkmnn2",
            network: .mainnet
        ))
        let height = expectation(description: "height replay")
        let sync = expectation(description: "sync replay")
        let account = expectation(description: "account replay")
        var cancellables = Set<AnyCancellable>()

        kit.lastBlockHeightPublisher.sink { value in
            XCTAssertNil(value)
            XCTAssertNil(kit.lastBlockHeight)
            kit.stop()
            height.fulfill()
        }.store(in: &cancellables)

        kit.syncStatePublisher.sink { value in
            XCTAssertEqual(value, .idle(cached: false))
            XCTAssertEqual(kit.syncState, .idle(cached: false))
            kit.refresh()
            sync.fulfill()
        }.store(in: &cancellables)

        kit.accountStatePublisher.sink { value in
            XCTAssertNil(value)
            XCTAssertNil(kit.accountState)
            account.fulfill()
        }.store(in: &cancellables)

        wait(for: [height, sync, account], timeout: 1)
        XCTAssertEqual(cancellables.count, 3)
    }

    func testPersistenceNamespaceIsDeterministicInternalAndAbsentFromErrors() throws {
        let address = try Address(
            "thor1x0jkvqdh2hlpeztd5zyyk70n3efx6mhudkmnn2",
            network: .mainnet
        )
        let kit = try Kit.instance(
            address: address,
            walletId: "wallet-01",
            endpoints: endpoints()
        )
        XCTAssertEqual(
            kit.persistenceNamespace,
            "e2df225b7a00d471b1b09ec2d3344df89a11e9cfe116c05f5290683480623015"
        )

        do {
            _ = try Kit.instance(address: address, walletId: " \n", endpoints: endpoints())
            XCTFail("accepted whitespace-only wallet ID")
        } catch {
            let description = String(describing: error)
            XCTAssertFalse(description.contains("wallet-01"))
            XCTAssertFalse(description.contains(kit.persistenceNamespace))
        }
    }

    private func family(id: String) throws -> EndpointFamilyDescriptor {
        try EndpointFamilyDescriptor(
            id: id,
            cosmosRestURL: URL(string: "https://rest.example.com")!,
            cometBftURL: URL(string: "https://rpc.example.com")!
        )
    }

    private func endpoints() throws -> EndpointConfiguration {
        try EndpointConfiguration(families: [family(id: "primary")])
    }


    private func accountState(
        accountNumber: UInt64?,
        sequence: UInt64?,
        balances: [Denom: BigUInt],
        exists: Bool
    ) throws -> AccountState {
        try AccountState(
            accountNumber: accountNumber,
            sequence: sequence,
            balances: balances,
            acceptedHeight: 10,
            fetchedAt: Date(timeIntervalSince1970: 1),
            providerFamilyId: "primary",
            exists: exists
        )
    }

    private func assertThrows<T, E: Error & Equatable>(
        _ expected: E,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ expression: () throws -> T
    ) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            XCTAssertEqual(error as? E, expected, file: file, line: line)
        }
    }

    private func assertEndpointError<T>(
        _ expected: EndpointConfigurationError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ expression: () throws -> T
    ) {
        assertThrows(expected, file: file, line: line, expression)
    }

    private func assertAddressError<T>(
        _ expected: AddressError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ expression: () throws -> T
    ) {
        assertThrows(expected, file: file, line: line, expression)
    }
}
