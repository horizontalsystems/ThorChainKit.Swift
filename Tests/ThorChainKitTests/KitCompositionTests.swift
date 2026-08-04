import CryptoKit
import Foundation
import secp256k1
import XCTest
@testable import ThorChainKit

final class KitCompositionTests: XCTestCase {
    func testKitCompositionRetainsTransactionSenderAndPendingFacade() throws {
        let address = try sendTestAddress()
        let sender = TransactionSender(address: address)
        let kit = makeTestKit(address: address, transactionSender: sender, persistenceNamespace: "composition")

        XCTAssertNotNil(kit.transactionSender)
    }

    func testTwoClientsInSameNamespaceStoppingADoesNotStopB() async throws {
        let address = try sendTestAddress()
        let first = TransactionSender(address: address, persistenceNamespace: "same-namespace")
        let second = TransactionSender(address: address, persistenceNamespace: "same-namespace")

        await first.activate(generation: 1)
        await second.activate(generation: 1)
        await first.invalidate(generation: 1)

        let secondIsActive = await second.isAdmissionActive()
        XCTAssertTrue(secondIsActive)
    }

    func testInstanceAndFixtureFactoriesEachOwnOneDistinctTransactionSender() async throws {
        let address = try sendTestAddress()
        let walletId = "composition-same-wallet"
        let endpoints = try EndpointConfiguration(families: [
            try EndpointFamilyDescriptor(
                id: "composition",
                cosmosRestURL: URL(string: "https://rest.composition.example")!,
                cometBftURL: URL(string: "https://rpc.composition.example")!
            )
        ])
        let instance = try Kit.instance(
            address: address,
            walletId: walletId,
            endpoints: endpoints
        )
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("thorchain-s2-01-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let fixture = try Kit.fixture(
            address: address,
            walletId: walletId,
            endpoints: endpoints,
            transport: CompositionTransport(),
            databasePath: databaseURL.path,
            observedAt: Date(timeIntervalSince1970: 1)
        )

        XCTAssertNotEqual(ObjectIdentifier(instance.transactionSender), ObjectIdentifier(fixture.transactionSender))
        let instanceAuthority = await instance.transactionSender.authorityClientID()
        let fixtureAuthority = await fixture.transactionSender.authorityClientID()
        XCTAssertNotEqual(instanceAuthority, fixtureAuthority)
    }

    func testFixtureFactoryUsesRegisteredFamilyAndInjectedTransportAfterStart() async throws {
        let address = try sendTestAddress()
        let family = try XCTUnwrap(NativeRuneEndpointRegistry.families().first { $0.id == "rorcual-mainnet" })
        let endpoints = try EndpointConfiguration(families: [family])
        let transport = CompositionTransport()
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("thorchain-s2-06-(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let fixture = try Kit.fixture(
            address: address,
            walletId: "composition-s2-06",
            endpoints: endpoints,
            transport: transport,
            databasePath: databaseURL.path,
            observedAt: Date(timeIntervalSince1970: 1)
        )
        fixture.start()

        var isActive = false
        var urls = [URL]()
        for _ in 0..<100 {
            isActive = await fixture.transactionSender.isAdmissionActive()
            urls = await transport.requestURLs()
            if isActive && !urls.isEmpty { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertTrue(isActive)
        XCTAssertFalse(urls.isEmpty)
        XCTAssertTrue(urls.allSatisfy { $0.host == family.cosmosRestURL.host || $0.host == family.cometBftURL.host })
    }

    func testFixtureSendReachesInjectedTransportOnceAndAcceptsCheckTx() async throws {
        let signer = try FixtureBroadcastSigner()
        let address = try AccountAddressFactory.address(
            compressedPublicKey: signer.compressedPublicKey,
            network: .mainnet
        )
        let family = try XCTUnwrap(NativeRuneEndpointRegistry.families().first { $0.id == "rorcual-mainnet" })
        let endpoints = try EndpointConfiguration(families: [family])
        let transport = FixtureBroadcastTransport()
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("thorchain-s2-06-broadcast-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let fixture = try Kit.fixture(
            address: address,
            walletId: "composition-s2-06-broadcast",
            endpoints: endpoints,
            transport: transport,
            databasePath: databaseURL.path,
            observedAt: Date(timeIntervalSince1970: 1)
        )
        let runtime = fixture.transactionSender
        await runtime.activate(generation: 1)
        let snapshot = try SendSnapshot(
            familyID: family.id,
            chainID: "thorchain-1",
            height: 12,
            sender: address.raw,
            recipient: try sendOtherAddress().raw,
            accountNumber: 1,
            sequence: 2,
            amount: 100,
            nativeFee: 2,
            mimir: MimirSnapshot(haltChainGlobal: -1, nodePauseChainGlobal: -1, haltTHORChain: -1, solvencyHaltTHORChain: -1),
            memoMaximumBytes: 256,
            accountPublicKey: "/cosmos.crypto.secp256k1.PubKey",
            accountPublicKeyData: signer.compressedPublicKey
        )
        let quote = try await runtime.issuePreflightQuote(
            request: SendQuoteRequest(
                sender: address,
                recipient: try sendOtherAddress(),
                amount: .exact(snapshot.amount)
            ),
            snapshot: snapshot
        )

        let submission = try await fixture.send(quote: quote, signer: signer)

        let postCount = await transport.postCount()
        let requestPath = await transport.requestPath()
        XCTAssertEqual(submission.state, .checkTxAccepted)
        XCTAssertEqual(postCount, 1)
        XCTAssertEqual(requestPath, "/cosmos/tx/v1beta1/txs")
    }

}

private actor CompositionTransport: TestingHTTPTransport {
    private var requests = [URLRequest]()

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    func requestURLs() -> [URL] { requests.compactMap(\.url) }
}

private actor FixtureBroadcastTransport: TestingHTTPTransport {
    private var posts = 0
    private var path: String?

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard request.httpMethod == "POST", let url = request.url, let body = request.httpBody,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: String],
              let txBytes = object["tx_bytes"], object["mode"] == "BROADCAST_MODE_SYNC",
              let raw = Data(base64Encoded: txBytes) else {
            throw BroadcastTransportError.invalidResponse
        }
        posts += 1
        path = url.path
        let hash = SHA256.hash(data: raw).map { String(format: "%02X", $0) }.joined()
        let response = Data("{\"tx_response\":{\"txhash\":\"\(hash)\",\"code\":0}}".utf8)
        return (response, HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!)
    }

    func postCount() -> Int { posts }
    func requestPath() -> String? { path }
}

private final class FixtureBroadcastSigner: ISigner, @unchecked Sendable {
    private let key: secp256k1.Signing.PrivateKey
    let compressedPublicKey: Data

    init() throws {
        let key = try secp256k1.Signing.PrivateKey()
        self.key = key
        compressedPublicKey = key.publicKey.rawRepresentation
    }

    func sign(digest: Data) async throws -> Data {
        // The digest is already SHA-256(SignDoc); signing it as Data would hash it twice.
        try Signer.sign(digest: digest, privateKey: key.rawRepresentation)
    }
}
