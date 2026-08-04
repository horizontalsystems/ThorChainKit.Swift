import Foundation
import XCTest
import SwiftProtobuf
@testable import ThorChainKit

final class ThorNodeSendPreflightProviderTests: XCTestCase {
    func testATokenSendReadsNoBalanceAndStillEndsOnRecipientAccount() async throws {
        let sender = "thor1x0jkvqdh2hlpeztd5zyyk70n3efx6mhudkmnn2"
        let recipient = "thor1tgxm5jw6hrlvslrd6lqpk4jwuu4g29dxytrean"
        var account = Cosmos_Auth_V1beta1_BaseAccount(); account.address = sender; account.accountNumber = 7; account.sequence = 9
        var accountResponse = Cosmos_Auth_V1beta1_QueryAccountResponse(); accountResponse.account.typeURL = "/cosmos.auth.v1beta1.BaseAccount"; accountResponse.account.value = try account.serializedData()
        var recipientResponse = Cosmos_Auth_V1beta1_QueryAccountResponse(); recipientResponse.account.typeURL = "/cosmos.auth.v1beta1.BaseAccount"; var recipientAccount = account; recipientAccount.address = recipient; recipientResponse.account.value = try recipientAccount.serializedData()
        var network = Types_QueryNetworkResponse(); network.nativeTxFeeRune = "7"

        let family = try XCTUnwrap(NativeRuneEndpointRegistry.families().first)
        let lease = EndpointLease(family: family, verifiedChainId: "thorchain-1", cosmosReadHeight: 42, cometReferenceHeight: 42, poolGeneration: 1)
        let transport = MatrixSendTransport(account: try accountResponse.serializedData(), recipient: try recipientResponse.serializedData(), network: try network.serializedData())
        let capabilities = NativeRuneEndpointRegistry.capabilities().map { capability in
            SendFamilyCapability(familyID: capability.familyID, manifestRevision: capability.manifestRevision, routes: capability.routes.map { route in
                SendManifestRoute(record: route.record, route: route.route, path: route.path, requestEncoding: route.requestEncoding, decoder: route.decoder, proofMode: route.proofMode, schemaRevision: route.schemaRevision, supportedNodeRevision: route.supportedNodeRevision, historicalHeightParameter: route.historicalHeightParameter, queryKey: route.queryKey, queryParameterName: route.queryParameterName, queryParameterValue: route.queryParameterValue, capabilityStatus: .pass)
            })
        }
        let provider = ThorNodeSendPreflightProvider(node: ThorNodeSendClient(transport: transport), leaseProvider: { lease }, capabilities: capabilities)
        let request = SendQuoteRequest(
            sender: try Address(sender, network: .mainnet), recipient: try Address(recipient, network: .mainnet),
            amount: .exact(100), memo: nil, denom: try Denom(rawValue: "tcy")
        )

        let snapshot = try await provider.snapshot(request: request, lease: lease, height: 42, policy: .standard, attempt: SendPreflightAttempt(clientID: UUID(), generation: 1, attemptID: UUID(), familyID: family.id, routeID: nil))

        XCTAssertEqual(snapshot.denom.rawValue, "tcy")
        // No balance is read for either denom, and recipient-account stays last: the
        // preflight binds the attempt to that route, so slipping a read in after it
        // fails closed.
        XCTAssertEqual(transport.routeNames, ["account", "network-fee", "mimir", "recipient-account"])
        let denoms = transport.requests.compactMap { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "denom" })?.value }
        XCTAssertEqual(denoms, [])
    }

    func testSendManifestRejectsUnregisteredFixtureFamily() throws {
        let registered = try XCTUnwrap(NativeRuneEndpointRegistry.families().first { $0.id == "rorcual-mainnet" })
        let route = try XCTUnwrap(NativeRuneEndpointRegistry.capabilities().first { $0.familyID == registered.id }?.routes.first)
        XCTAssertTrue(NativeRuneEndpointRegistry.matches(route, family: registered))

        let unregistered = try EndpointFamilyDescriptor(
            id: "example-mainnet",
            cosmosRestURL: URL(string: "https://rest.invalid")!,
            cometBftURL: URL(string: "https://rpc.invalid")!
        )
        XCTAssertFalse(NativeRuneEndpointRegistry.matches(route, family: unregistered))
    }

    func testCompletePinnedRouteMatrixBuildsOneSnapshotForEachFamilyManifest() async throws {
        let sender = "thor1x0jkvqdh2hlpeztd5zyyk70n3efx6mhudkmnn2"
        let recipient = "thor1tgxm5jw6hrlvslrd6lqpk4jwuu4g29dxytrean"
        var account = Cosmos_Auth_V1beta1_BaseAccount(); account.address = sender; account.accountNumber = 7; account.sequence = 9
        var accountResponse = Cosmos_Auth_V1beta1_QueryAccountResponse(); accountResponse.account.typeURL = "/cosmos.auth.v1beta1.BaseAccount"; accountResponse.account.value = try account.serializedData()
        var recipientResponse = Cosmos_Auth_V1beta1_QueryAccountResponse(); recipientResponse.account.typeURL = "/cosmos.auth.v1beta1.BaseAccount"; var recipientAccount = account; recipientAccount.address = recipient; recipientResponse.account.value = try recipientAccount.serializedData()
        var network = Types_QueryNetworkResponse(); network.nativeTxFeeRune = "7"
        for family in try NativeRuneEndpointRegistry.families() {
        let lease = EndpointLease(family: family, verifiedChainId: "thorchain-1", cosmosReadHeight: 42, cometReferenceHeight: 42, poolGeneration: 1)
        let transport = MatrixSendTransport(account: try accountResponse.serializedData(), recipient: try recipientResponse.serializedData(), network: try network.serializedData())
        let capabilities = NativeRuneEndpointRegistry.capabilities().map { capability in
            SendFamilyCapability(familyID: capability.familyID, manifestRevision: capability.manifestRevision, routes: capability.routes.map { route in
                SendManifestRoute(record: route.record, route: route.route, path: route.path, requestEncoding: route.requestEncoding, decoder: route.decoder, proofMode: route.proofMode, schemaRevision: route.schemaRevision, supportedNodeRevision: route.supportedNodeRevision, historicalHeightParameter: route.historicalHeightParameter, queryKey: route.queryKey, queryParameterName: route.queryParameterName, queryParameterValue: route.queryParameterValue, capabilityStatus: .pass)
            })
        }
        let provider = ThorNodeSendPreflightProvider(node: ThorNodeSendClient(transport: transport), leaseProvider: { lease }, capabilities: capabilities)
        let request = SendQuoteRequest(sender: try Address(sender, network: .mainnet), recipient: try Address(recipient, network: .mainnet), amount: .exact(100), memo: nil)
        let snapshot = try await provider.snapshot(request: request, lease: lease, height: 42, policy: .standard, attempt: SendPreflightAttempt(clientID: UUID(), generation: 1, attemptID: UUID(), familyID: "rorcual-mainnet", routeID: nil))
        XCTAssertEqual(snapshot.height, 42)
        XCTAssertEqual(snapshot.accountNumber, 7)
        XCTAssertEqual(snapshot.sequence, 9)
        XCTAssertEqual(snapshot.nativeFee, 7)
        XCTAssertEqual(transport.routeNames, ["account", "network-fee", "mimir", "recipient-account"])
        XCTAssertEqual(transport.requests.count, 4)
        XCTAssertFalse(transport.bulkModuleAccountsCalled, "the broken bulk ModuleAccounts route is a regression counterexample")
        for request in transport.requests {
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            let path = components.queryItems?.first(where: { $0.name == "path" })?.value
            if let path {
                XCTAssertEqual(components.host, family.cometBftURL.host)
                XCTAssertTrue(["\"/cosmos.auth.v1beta1.Query/Account\"", "\"/types.Query/Network\""].contains(path))
                XCTAssertTrue(CometABCIEncoding.isCanonicalHex(components.queryItems!.first(where: { $0.name == "data" })!.value!))
            } else {
                XCTAssertEqual(components.host, family.cosmosRestURL.host)
                if components.path.contains("spendable_balances") || components.path.hasSuffix("/params") {
                    XCTAssertNil(components.queryItems?.first(where: { $0.name == "height" }))
                } else {
                    XCTAssertEqual(components.queryItems?.first(where: { $0.name == "height" })?.value, "42")
                }
            }
        }
        let runtime = SendRuntime(address: try Address(sender, network: .mainnet))
        await runtime.activate(generation: 1)
        let productionTransport = MatrixSendTransport(account: try accountResponse.serializedData(), recipient: try recipientResponse.serializedData(), network: try network.serializedData())
        let productionProvider = ThorNodeSendPreflightProvider(node: ThorNodeSendClient(transport: productionTransport), leaseProvider: { lease }, capabilities: capabilities, runtime: runtime)
        let coordinator = SendPreflightCoordinator(runtime: runtime, provider: productionProvider)
        let prepared = try await coordinator.prepareQuote(request: request)
        XCTAssertEqual(prepared.snapshot.familyID, family.id)
        let activeAttempts = await runtime.activePreflightAttemptCount()
        XCTAssertEqual(activeAttempts, 0)
        }
    }

    func testManifestMutationsFailClosedAcrossAllThreeFamilies() async throws {
        for family in try NativeRuneEndpointRegistry.families() {
            let lease = EndpointLease(family: family, verifiedChainId: "thorchain-1", cosmosReadHeight: 42, cometReferenceHeight: 42, poolGeneration: 1)
            let valid = passingCapabilities()
            let canonical = valid.first { $0.familyID == family.id }!
            let mutations: [[SendFamilyCapability]] = [
                valid.map { $0.familyID == family.id ? SendFamilyCapability(familyID: $0.familyID, manifestRevision: $0.manifestRevision, routes: Array($0.routes.dropLast())) : $0 },
                valid.map { $0.familyID == family.id ? SendFamilyCapability(familyID: $0.familyID, manifestRevision: "wrong", routes: $0.routes) : $0 },
                valid.map { $0.familyID == family.id ? SendFamilyCapability(familyID: $0.familyID, manifestRevision: $0.manifestRevision, routes: $0.routes.map { route in routeCopy(route, path: "") }) : $0 },
                valid.map { $0.familyID == family.id ? SendFamilyCapability(familyID: $0.familyID, manifestRevision: $0.manifestRevision, routes: $0.routes.map { route in routeCopy(route, schemaRevision: "wrong") }) : $0 },
                valid.map { $0.familyID == family.id ? SendFamilyCapability(familyID: $0.familyID, manifestRevision: $0.manifestRevision, routes: $0.routes.map { route in routeCopy(route, record: SendManifestRecord(familyID: family.id, role: route.record.role == .rest ? .rpc : .rest, scheme: route.record.scheme, host: route.record.host, port: route.record.port, path: route.record.path)) }) : $0 },
                valid.map { $0.familyID == family.id ? SendFamilyCapability(familyID: $0.familyID, manifestRevision: $0.manifestRevision, routes: $0.routes.map { route in routeCopy(route, record: SendManifestRecord(familyID: family.id, role: route.record.role, scheme: route.record.scheme, host: "wrong.example", port: route.record.port, path: route.record.path)) }) : $0 }
            ]
            XCTAssertEqual(canonical.routes.count, 4)
            for capabilities in mutations {
                let provider = ThorNodeSendPreflightProvider(node: ThorNodeSendClient(transport: MatrixSendTransport(account: Data(), recipient: Data(), network: Data())), leaseProvider: { lease }, capabilities: capabilities)
                do {
                    _ = try await provider.lease(minimumHeight: nil)
                    XCTFail("manifest mutation for \(family.id) must fail closed")
                } catch let error as SendError {
                    XCTAssertEqual(error, .policyUnavailable)
                }
            }
        }
    }

    func testProviderCancellationAtEveryPinnedRouteReturnsPromptlyAndDoesNotContinue() async throws {
        let sender = "thor1x0jkvqdh2hlpeztd5zyyk70n3efx6mhudkmnn2"
        let recipient = "thor1tgxm5jw6hrlvslrd6lqpk4jwuu4g29dxytrean"
        let request = SendQuoteRequest(sender: try Address(sender, network: .mainnet), recipient: try Address(recipient, network: .mainnet), amount: .exact(100))
        var account = Cosmos_Auth_V1beta1_BaseAccount(); account.address = sender; account.accountNumber = 7; account.sequence = 9
        var accountResponse = Cosmos_Auth_V1beta1_QueryAccountResponse(); accountResponse.account.typeURL = "/cosmos.auth.v1beta1.BaseAccount"; accountResponse.account.value = try account.serializedData()
        var recipientResponse = Cosmos_Auth_V1beta1_QueryAccountResponse(); recipientResponse.account.typeURL = "/cosmos.auth.v1beta1.BaseAccount"; var recipientAccount = account; recipientAccount.address = recipient; recipientResponse.account.value = try recipientAccount.serializedData()
        var network = Types_QueryNetworkResponse(); network.nativeTxFeeRune = "7"

        for family in try NativeRuneEndpointRegistry.families() {
            for route in NativeRuneEndpointRegistry.capabilities().first(where: { $0.familyID == family.id })!.routes {
                let blocked = expectation(description: "(family.id)/(route.route) dependency started")
                let transport = MatrixSendTransport(account: try accountResponse.serializedData(), recipient: try recipientResponse.serializedData(), network: try network.serializedData(), blockedRoute: route.route, blockedExpectation: blocked)
                let provider = ThorNodeSendPreflightProvider(
                    node: ThorNodeSendClient(transport: transport),
                    leaseProvider: { EndpointLease(family: family, verifiedChainId: "thorchain-1", cosmosReadHeight: 42, cometReferenceHeight: 42, poolGeneration: 1) },
                    capabilities: passingCapabilities(),
                    runtime: nil,
                    operationDeadline: route.route == "account" ? 0.001 : 0.25
                )
                let lease = try await provider.lease(minimumHeight: nil)
                let operation = Task { try await provider.snapshotResult(request: request, lease: lease, height: 42, policy: .standard, attempt: SendPreflightAttempt(clientID: UUID(), generation: 1, attemptID: UUID(), familyID: family.id, routeID: nil)) }
                await fulfillment(of: [blocked], timeout: 1)
                if route.route != "account" { operation.cancel() }

                let outcome = await operation.result
                guard case let .failure(error) = outcome else {
                    XCTFail("\(family.id)/\(route.route) cancellation must fail")
                    transport.releaseBlocked()
                    continue
                }
                guard let operationError = error as? EndpointOperationError else {
                    XCTFail("\(family.id)/\(route.route) returned unexpected error: \(error)")
                    transport.releaseBlocked()
                    continue
                }
                XCTAssertEqual(operationError, route.route == "account" ? .deadlineExceeded : .cancelled, "\(family.id)/\(route.route)")
                let beforeRelease = transport.routeNames
                XCTAssertEqual(beforeRelease.last, route.route)
                transport.releaseBlocked()
                for _ in 0..<4 { await Task.yield() }
                XCTAssertEqual(transport.routeNames, beforeRelease, "late route result must not start a subsequent endpoint")
            }
        }
    }

    private func passingCapabilities() -> [SendFamilyCapability] {
        NativeRuneEndpointRegistry.capabilities().map { capability in
            SendFamilyCapability(familyID: capability.familyID, manifestRevision: capability.manifestRevision, routes: capability.routes.map { routeCopy($0, capabilityStatus: .pass) })
        }
    }

    private func routeCopy(_ route: SendManifestRoute, record: SendManifestRecord? = nil, path: String? = nil, schemaRevision: String? = nil, capabilityStatus: SendCapabilityStatus? = nil) -> SendManifestRoute {
        SendManifestRoute(record: record ?? route.record, route: route.route, path: path ?? route.path, requestEncoding: route.requestEncoding, decoder: route.decoder, proofMode: route.proofMode, schemaRevision: schemaRevision ?? route.schemaRevision, supportedNodeRevision: route.supportedNodeRevision, historicalHeightParameter: route.historicalHeightParameter, queryKey: route.queryKey, queryParameterName: route.queryParameterName, queryParameterValue: route.queryParameterValue, capabilityStatus: capabilityStatus ?? route.capabilityStatus)
    }
}

private final class MatrixSendTransport: ISendTransport, @unchecked Sendable {
    let account: Data
    let recipient: Data
    let network: Data
    private(set) var routeNames = [String]()
    private(set) var requests = [URLRequest]()
    private(set) var bulkModuleAccountsCalled = false

    private let blockedRoute: String?
    private let blockedExpectation: XCTestExpectation?
    private let blockLock = NSLock()
    private var released = false
    private var dependencyWaiter: CheckedContinuation<Void, Never>?

    init(account: Data, recipient: Data, network: Data, blockedRoute: String? = nil, blockedExpectation: XCTestExpectation? = nil) {
        self.account = account; self.recipient = recipient; self.network = network; self.blockedRoute = blockedRoute; self.blockedExpectation = blockedExpectation
    }

    func releaseBlocked() {
        blockLock.lock(); released = true; let waiter = dependencyWaiter; dependencyWaiter = nil; blockLock.unlock()
        waiter?.resume()
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if request.url?.path.contains("module_accounts") == true { bulkModuleAccountsCalled = true }
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        let path = components.queryItems?.first(where: { $0.name == "path" })?.value?.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        let route: String
        let body: Data
        let headers: [String: String]
        if let path {
            route = path == "/types.Query/Network" ? "network-fee" : path.contains("Account") && routeNames.contains("account") ? "recipient-account" : "account"
            body = try comet(value: route == "network-fee" ? network : route == "recipient-account" ? recipient : account)
            headers = ["Content-Type": "application/json"]
        } else if components.path.contains("spendable_balances") {
            let denom = components.queryItems?.first(where: { $0.name == "denom" })?.value ?? "rune"
            route = "spendable"; body = Data("{\"balance\":{\"denom\":\"\(denom)\",\"amount\":\"\(denom == "rune" ? "1000" : "500")\"}}".utf8); headers = restHeaders
        } else {
            route = "mimir"; body = Data(#"{"HALTCHAINGLOBAL":-1,"NODEPAUSECHAINGLOBAL":-1,"HALTTHORCHAIN":-1}"#.utf8); headers = restHeaders
        }
        routeNames.append(route)
        if route == blockedRoute {
            await withCheckedContinuation { continuation in
                blockLock.lock()
                blockedExpectation?.fulfill()
                if released { blockLock.unlock(); continuation.resume() }
                else { dependencyWaiter = continuation; blockLock.unlock() }
            }
        }
        return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!)
    }

    private var restHeaders: [String: String] { ["Content-Type": "application/json", "Grpc-Metadata-X-Cosmos-Block-Height": "42"] }

    private func comet(value: Data) throws -> Data {
        let encoded = value.base64EncodedString()
        let body = "{\"jsonrpc\":\"2.0\",\"id\":-1,\"result\":{\"response\":{\"code\":0,\"height\":\"42\",\"value\":\"" + encoded + "\"}}}"
        return Data(body.utf8)
    }
}
