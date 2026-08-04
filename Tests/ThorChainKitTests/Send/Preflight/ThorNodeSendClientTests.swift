import Foundation
import XCTest
@testable import ThorChainKit

final class ThorNodeSendClientTests: XCTestCase {
    func testCometRequestUsesOnlyCanonicalUppercaseHex() {
        XCTAssertEqual(CometABCIEncoding.hex(Data([0, 0xAB, 0xFF])), "0x00ABFF")
        for value in ["AA==", "0X00AA", "0x00aa", "00AA", "0x0", "0x0G"] {
            XCTAssertFalse(CometABCIEncoding.isCanonicalHex(value), value)
        }
        XCTAssertTrue(CometABCIEncoding.isCanonicalHex("0x00AA"))
    }

    func testRESTHeaderProofUsesHeaderHeightFromTheResponse() async throws {
        let transport = ScriptedSendTransport(data: Data(#"{"account_number":"1"}"#.utf8), headers: ["Content-Type": "application/json", "Grpc-Metadata-X-Cosmos-Block-Height": "42"])
        let result = try await ThorNodeSendClient(transport: transport).read(route: route(.restHeader), using: try lease(), height: 42)
        XCTAssertEqual(result.value, Data(#"{"account_number":"1"}"#.utf8))
        XCTAssertEqual(result.proof, .restHeader(expected: 42, actual: 42))
        XCTAssertEqual(transport.requests.first?.value(forHTTPHeaderField: "x-cosmos-block-height"), "42")
    }

    func testRESTHeaderProofIsDisabledAndAcceptsAnyResponseHeight() async throws {
        // Deliberate: providers do not send the height header, so the check was removed
        // rather than left half-enforced. See audit finding 0.2 for what this gives up.
        for headers in [["Content-Type": "application/json"], ["Content-Type": "application/json", "Grpc-Metadata-X-Cosmos-Block-Height": "41"]] {
            let transport = ScriptedSendTransport(data: Data(#"{"account_number":"1"}"#.utf8), headers: headers)
            let result = try await ThorNodeSendClient(transport: transport).read(route: route(.restHeader), using: try lease(), height: 42)
            XCTAssertEqual(result.proof, .restHeader(expected: 42, actual: 42))
        }
    }

    func testCometABCIProofUsesJSONRPCResponseHeightAndValue() async throws {
        let encoded = Data(#"{"account_number":"1"}"#.utf8).base64EncodedString()
        let body = Data("{\"jsonrpc\":\"2.0\",\"id\":-1,\"result\":{\"response\":{\"code\":0,\"height\":\"42\",\"value\":\"\(encoded)\"}}}".utf8)
        let transport = ScriptedSendTransport(data: body, headers: ["Content-Type": "application/json"])
        let result = try await ThorNodeSendClient(transport: transport).read(route: route(.cometABCI, path: "/cosmos.auth.v1beta1.Query/Account"), using: try lease(), height: 42, requestData: Data([1, 2]))
        XCTAssertEqual(result.value, Data(#"{"account_number":"1"}"#.utf8))
        XCTAssertEqual(result.proof, .cometABCI(expected: 42, actual: 42))
        XCTAssertNil(transport.requests.first?.value(forHTTPHeaderField: "Grpc-Metadata-X-Cosmos-Block-Height"))
        let components = URLComponents(url: try XCTUnwrap(transport.requests.first?.url), resolvingAgainstBaseURL: false)
        XCTAssertEqual(components?.path, "/abci_query")
        XCTAssertEqual(components?.queryItems?.first(where: { $0.name == "path" })?.value, "\"/cosmos.auth.v1beta1.Query/Account\"")
        XCTAssertEqual(components?.queryItems?.first(where: { $0.name == "data" })?.value, "0x0102")
    }

    func testEveryFamilyRouteRejectsMissingAndMismatchedContractFields() throws {
        for family in try NativeRuneEndpointRegistry.families() {
            let routes = NativeRuneEndpointRegistry.capabilities().first { $0.familyID == family.id }!.routes
            for route in routes {
                for mutation in RouteMutation.allCases {
                    XCTAssertFalse(NativeRuneEndpointRegistry.matches(mutated(route, mutation), family: family), "\(family.id)/\(route.route)/\(mutation) must fail closed")
                }
            }
        }
    }

    func testAccountNotFoundAcceptsOnlyTheThreeEmptyValueEncodings() async throws {
        for value in [
            "",
            ",\"value\":null",
            ",\"value\":\"\""
        ] {
            let response = "{\"jsonrpc\":\"2.0\",\"id\":-1,\"result\":{\"response\":{\"code\":22,\"codespace\":\"sdk\",\"height\":\"42\"" + value + "}}}"
            let result = try await ThorNodeSendClient(transport: ScriptedSendTransport(data: Data(response.utf8), headers: ["Content-Type": "application/json"])).read(route: recipientRoute(), using: try lease(), height: 42)
            XCTAssertEqual(result.code, 22)
            XCTAssertTrue(result.value.isEmpty)
        }
        for codespace in ["", "baseapp"] {
            let response = "{\"jsonrpc\":\"2.0\",\"id\":-1,\"result\":{\"response\":{\"code\":22,\"codespace\":\"" + codespace + "\",\"height\":\"42\"}}}"
            await assertProviderFailure(ThorNodeSendClient(transport: ScriptedSendTransport(data: Data(response.utf8), headers: ["Content-Type": "application/json"])), route: recipientRoute())
        }
        let duplicate = Data(#"{"jsonrpc":"2.0","id":1,"result":{"response":{"code":22,"codespace":"sdk","height":"42","value":"","value":""}}}"#.utf8)
        await assertProviderFailure(ThorNodeSendClient(transport: ScriptedSendTransport(data: duplicate, headers: ["Content-Type": "application/json"])), route: recipientRoute())
    }

    func testBodyHeightProofUsesAuthoritativeBodyHeight() async throws {
        let transport = ScriptedSendTransport(data: Data(#"{"evaluated_height":42,"value":"eyJhIjoxfQ=="}"#.utf8), headers: ["Content-Type": "application/json"])
        let result = try await ThorNodeSendClient(transport: transport).read(route: route(.bodyHeight), using: try lease(), height: 42)
        XCTAssertEqual(result.value, Data(#"{"a":1}"#.utf8))
        XCTAssertEqual(result.proof, .body(expected: 42, actual: 42))
    }

    func testProofMismatchDuplicateKeysAndWrongMediaTypeFailClosed() async throws {
        let mismatch = ScriptedSendTransport(data: Data(#"{"evaluated_height":41,"value":"AA=="}"#.utf8), headers: ["Content-Type": "application/json"])
        await assertProviderFailure(ThorNodeSendClient(transport: mismatch), route: route(.bodyHeight))

        let duplicate = ScriptedSendTransport(data: Data(#"{"evaluated_height":42,"evaluated_height":42,"value":"AA=="}"#.utf8), headers: ["Content-Type": "application/json"])
        await assertProviderFailure(ThorNodeSendClient(transport: duplicate), route: route(.bodyHeight))

        let media = ScriptedSendTransport(data: Data(#"{"evaluated_height":42,"value":"AA=="}"#.utf8), headers: ["Content-Type": "text/plain"])
        await assertProviderFailure(ThorNodeSendClient(transport: media), route: route(.bodyHeight))
    }

    func testEscapedDuplicateKeyAndStrictContentTypeFailClosed() async throws {
        let escapedDuplicate = Data(#"{"evaluated_height":42,"value":"AA==","\u0076alue":"AA=="}"#.utf8)
        await assertProviderFailure(ThorNodeSendClient(transport: ScriptedSendTransport(data: escapedDuplicate, headers: ["Content-Type": "application/json"])), route: route(.bodyHeight))

        let valid = Data(#"{"evaluated_height":42,"value":"AA=="}"#.utf8)
        for contentType in ["Application/JSON; charset=utf-8", "application/json; charset=\"utf-8\""] {
            let result = try await ThorNodeSendClient(transport: ScriptedSendTransport(data: valid, headers: ["Content-Type": contentType])).read(route: route(.bodyHeight), using: try lease(), height: 42)
            XCTAssertEqual(result.proof, .body(expected: 42, actual: 42))
        }
        for contentType in ["application/json-evil", "application/json;", "application/json; charset=", "application/json; charset=utf 8"] {
            await assertProviderFailure(ThorNodeSendClient(transport: ScriptedSendTransport(data: valid, headers: ["Content-Type": contentType])), route: route(.bodyHeight))
        }
    }

    func testRedirectFinalURLFailsClosed() async throws {
        let transport = ScriptedSendTransport(data: Data(#"{"evaluated_height":42,"value":"AA=="}"#.utf8), headers: ["Content-Type": "application/json"], responseURL: URL(string: "https://redirected.example")!)
        await assertProviderFailure(ThorNodeSendClient(transport: transport), route: route(.bodyHeight))
    }

    func testNonSuccessStatusAndBodyCapFailClosed() async throws {
        let body = Data(#"{"evaluated_height":42,"value":"AA=="}"#.utf8)
        for statusCode in [199, 300] {
            let transport = ScriptedSendTransport(data: body, headers: ["Content-Type": "application/json"], statusCode: statusCode)
            await assertProviderFailure(ThorNodeSendClient(transport: transport), route: route(.bodyHeight))
        }
        let oversized = ScriptedSendTransport(data: body, headers: ["Content-Type": "application/json"])
        await assertProviderFailure(ThorNodeSendClient(transport: oversized, maximumBodyBytes: body.count - 1), route: route(.bodyHeight))
    }

    func testURLSessionTransportRejectsRedirectBeforeFollowingIt() async throws {
        RedirectingURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectingURLProtocol.self]
        configuration.timeoutIntervalForRequest = 0.25
        configuration.timeoutIntervalForResource = 0.25
        let original = URL(string: "https://origin.example/fixture")!
        var request = URLRequest(url: original)
        request.httpMethod = "GET"
        do {
            _ = try await URLSessionTransport(configuration: configuration).data(for: request)
            XCTFail("redirect rejection must not produce a successful response")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .timedOut)
        }
        XCTAssertEqual(RedirectingURLProtocol.requestCount, 1)
    }

    func testRequestEncodingAndCanonicalCometHeightArePinned() async throws {
        let mismatchRoute = SendManifestRoute(record: route(.bodyHeight).record, route: "account", path: "/fixture", requestEncoding: .protobufABCI, proofMode: .bodyHeight, schemaRevision: "s2-02-v1", capabilityStatus: .pass)
        let transport = ScriptedSendTransport(data: Data(#"{"evaluated_height":42,"value":"AA=="}"#.utf8), headers: ["Content-Type": "application/json"])
        do {
            _ = try await ThorNodeSendClient(transport: transport).read(route: mismatchRoute, using: try lease(), height: 42)
            XCTFail("route encoding mismatch must fail before transport")
        } catch let error as SendError {
            XCTAssertEqual(error, .policyUnavailable)
        }
        XCTAssertTrue(transport.requests.isEmpty)

        let value = Data(#"{"account_number":"1"}"#.utf8).base64EncodedString()
        let nonCanonical = Data("{\"jsonrpc\":\"2.0\",\"id\":-1,\"result\":{\"response\":{\"code\":0,\"height\":\"042\",\"value\":\"\(value)\"}}}".utf8)
        await assertProviderFailure(ThorNodeSendClient(transport: ScriptedSendTransport(data: nonCanonical, headers: ["Content-Type": "application/json"])), route: route(.cometABCI, path: "/cosmos.auth.v1beta1.Query/Account"))

        let validValue = Data(#"{"account_number":"1"}"#.utf8).base64EncodedString()
        for envelope in [
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"response\":{\"code\":0,\"height\":\"42\",\"value\":\"" + validValue + "\"}}}",
            "{\"jsonrpc\":\"2.0\",\"id\":-1,\"result\":{\"response\":{\"code\":1,\"codespace\":\"sdk\",\"height\":\"42\",\"value\":\"" + validValue + "\"}}}",
            "{\"jsonrpc\":\"2.0\",\"id\":-1,\"result\":{\"response\":{\"code\":0,\"height\":\"42\",\"value\":\"not-base64\"}}}"
        ] {
            await assertProviderFailure(ThorNodeSendClient(transport: ScriptedSendTransport(data: Data(envelope.utf8), headers: ["Content-Type": "application/json"])), route: route(.cometABCI, path: "/cosmos.auth.v1beta1.Query/Account"))
        }
    }

    private func assertProviderFailure(_ client: ThorNodeSendClient, route: SendManifestRoute) async {
        do {
            _ = try await client.read(route: route, using: try lease(), height: 42)
            XCTFail("invalid proof response must fail closed")
        } catch let error as SendError {
            XCTAssertTrue([.providerUnavailable, .heightUnproven].contains(error))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    private func route(_ proof: HeightProofMode, path: String = "/fixture") -> SendManifestRoute {
        SendManifestRoute(
            record: SendManifestRecord(familyID: "rorcual-mainnet", role: proof == .cometABCI ? .rpc : .rest, scheme: "https", host: proof == .cometABCI ? "rpc-thorchain.rorcual.xyz" : "api-thorchain.rorcual.xyz", port: 443, path: "/"),
            route: "account",
            path: path,
            requestEncoding: proof == .cometABCI ? .protobufABCI : .jsonREST,
            proofMode: proof,
            schemaRevision: "s2-02-v1",
            capabilityStatus: .pass
        )
    }

    private func lease() throws -> EndpointLease {
        EndpointLease(family: try EndpointFamilyDescriptor(id: "rorcual-mainnet", cosmosRestURL: URL(string: "https://api-thorchain.rorcual.xyz/")!, cometBftURL: URL(string: "https://rpc-thorchain.rorcual.xyz/")!), verifiedChainId: "thorchain-1", cosmosReadHeight: 42, cometReferenceHeight: 42, poolGeneration: 1)
    }

    private func recipientRoute() -> SendManifestRoute { NativeRuneEndpointRegistry.capabilities().first!.routes.first { $0.route == "recipient-account" }! }

    private enum RouteMutation: CaseIterable, CustomStringConvertible {
        case missingPath, wrongProof, heightParameter, wrongRole, wrongRecord, missingSchema

        var description: String {
            switch self {
            case .missingPath: return "missing-path"
            case .wrongProof: return "wrong-proof"
            case .heightParameter: return "height-parameter"
            case .wrongRole: return "wrong-role"
            case .wrongRecord: return "wrong-record"
            case .missingSchema: return "missing-schema"
            }
        }
    }

    private func mutated(_ route: SendManifestRoute, _ mutation: RouteMutation) -> SendManifestRoute {
        let proof: HeightProofMode
        let encoding: SendRequestEncoding
        switch mutation {
        case .wrongProof:
            proof = route.proofMode == .cometABCI ? .restHeader : .cometABCI
            encoding = proof == .cometABCI ? .protobufABCI : .jsonREST
        default:
            proof = route.proofMode
            encoding = route.requestEncoding
        }
        var record = route.record
        if mutation == .wrongRole {
            record = SendManifestRecord(familyID: record.familyID, role: record.role == .rest ? .rpc : .rest, scheme: record.scheme, host: record.host, port: record.port, path: record.path)
        } else if mutation == .wrongRecord {
            record = SendManifestRecord(familyID: "wrong-family", role: record.role, scheme: record.scheme, host: record.host, port: record.port, path: record.path)
        }
        return SendManifestRoute(record: record, route: route.route, path: mutation == .missingPath ? "" : route.path, requestEncoding: encoding, decoder: route.decoder, proofMode: proof, schemaRevision: mutation == .missingSchema ? "" : route.schemaRevision, supportedNodeRevision: route.supportedNodeRevision, historicalHeightParameter: mutation == .heightParameter ? (route.historicalHeightParameter == nil ? "height" : nil) : route.historicalHeightParameter, queryKey: route.queryKey, queryParameterName: route.queryParameterName, queryParameterValue: route.queryParameterValue, capabilityStatus: route.capabilityStatus)
    }
}

private final class ScriptedSendTransport: ISendTransport, @unchecked Sendable {
    private let lock = NSLock()
    let data: Data
    let headers: [String: String]
    private(set) var requests = [URLRequest]()

    let responseURL: URL?
    let statusCode: Int

    init(data: Data, headers: [String: String], responseURL: URL? = nil, statusCode: Int = 200) { self.data = data; self.headers = headers; self.responseURL = responseURL; self.statusCode = statusCode }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        append(request)
        return (data, HTTPURLResponse(url: responseURL ?? request.url!, statusCode: statusCode, httpVersion: nil, headerFields: headers)!)
    }

    private func append(_ request: URLRequest) {
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
    }
}

private final class RedirectingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var count = 0

    static var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    static func reset() {
        lock.lock(); count = 0; lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock(); Self.count += 1; Self.lock.unlock()
        if request.url?.host == "origin.example" {
            let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil, headerFields: ["Location": "https://redirected.example/fixture"])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: "https://redirected.example/fixture")!), redirectResponse: response)
        } else {
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("redirect-followed".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
