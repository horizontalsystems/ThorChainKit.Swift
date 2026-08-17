import Foundation
@testable import ThorChainKit
import XCTest

final class LiveNodeProbeTests: XCTestCase {
    func testProbeRetainsThreeIndependentObservationsAndBasePath() async throws {
        let transport = ProbeTransport(responses: [
            "/proxy%2Fv1/cosmos/base/tendermint/v1beta1/node_info": .json(
                #"{"default_node_info":{"network":"thorchain-1"}}"#
            ),
            "/proxy%2Fv1/cosmos/base/tendermint/v1beta1/blocks/latest": .json(
                #"{"block":{"header":{"chain_id":"thorchain-1","height":"101"}}}"#
            ),
            "/rpc%2Fv1/status": .json(
                #"{"result":{"node_info":{"network":"thorchain-1"},"sync_info":{"latest_block_height":"103","catching_up":false}}}"#
            ),
        ])
        let probe = LiveNodeProbe(
            transport: transport,
            requestTimeout: 7,
            clientId: "fixture-client"
        )

        let outcomes = try await probe.probe(index: 2, family: family())

        XCTAssertEqual(outcomes.count, 3)
        XCTAssertEqual(outcomes.map(\.index.request), ProbeRequestKind.allCases)
        XCTAssertEqual(outcomes.map(\.index.familyIndex), [2, 2, 2])
        XCTAssertEqual(
            outcomes.map(\.result),
            [
                .cosmosNodeInfo(.success(.init(chainId: "thorchain-1"))),
                .cosmosLatestBlock(.success(.init(chainId: "thorchain-1", latestHeight: 101))),
                .cometStatus(.success(.init(chainId: "thorchain-1", latestHeight: 103, catchingUp: false))),
            ]
        )

        let requests = await transport.requests
        XCTAssertEqual(Set(requests.map { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)!.percentEncodedPath }), [
            "/proxy%2Fv1/cosmos/base/tendermint/v1beta1/node_info",
            "/proxy%2Fv1/cosmos/base/tendermint/v1beta1/blocks/latest",
            "/rpc%2Fv1/status",
        ])
        XCTAssertTrue(requests.allSatisfy { $0.timeoutInterval == 7 })
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "X-Client-ID") == "fixture-client" })
    }

    func testProbeClassifiesStatusAndInvalidFieldWithoutThrowing() async throws {
        let transport = ProbeTransport(responses: [
            "/cosmos/base/tendermint/v1beta1/node_info": .status(429, retryAfter: "12"),
            "/cosmos/base/tendermint/v1beta1/blocks/latest": .json(
                #"{"block":{"header":{"chain_id":"thorchain-1","height":"invalid"}}}"#
            ),
            "/status": .json(
                #"{"result":{"node_info":{"network":"thorchain-1"},"sync_info":{"latest_block_height":"9"}}}"#
            ),
        ])

        let outcomes = try await LiveNodeProbe(transport: transport).probe(
            index: 0,
            family: plainFamily()
        )

        XCTAssertEqual(outcomes.map(\.result), [
            .cosmosNodeInfo(.failure(.httpStatus(code: 429, retryAfterSeconds: 12))),
            .cosmosLatestBlock(.failure(.invalidResponse(field: .blockHeaderHeight))),
            .cometStatus(.failure(.invalidResponse(field: .cometCatchingUp))),
        ])
    }

    func testProbeMapsCancellationAndMakesNoAdditionalRequests() async throws {
        let transport = CancellingTransport()
        let outcomes = try await LiveNodeProbe(transport: transport).probe(
            index: 0,
            family: plainFamily()
        )

        XCTAssertEqual(outcomes.map(\.result), [
            .cosmosNodeInfo(.failure(.cancelled)),
            .cosmosLatestBlock(.failure(.cancelled)),
            .cometStatus(.failure(.cancelled)),
        ])
        let requestCount = await transport.requestCount
        XCTAssertEqual(requestCount, 3)
    }

    func testProbeClassifiesTransportKindsAndMissingRetryAfter() async throws {
        let transport = ProbeTransport(responses: [
            "/cosmos/base/tendermint/v1beta1/node_info": .status(429, retryAfter: nil),
            "/cosmos/base/tendermint/v1beta1/blocks/latest": .failure(.timedOut),
            "/status": .failure(.secureConnectionFailed),
        ])

        let outcomes = try await LiveNodeProbe(transport: transport).probe(
            index: 0,
            family: plainFamily()
        )

        XCTAssertEqual(outcomes.map(\.result), [
            .cosmosNodeInfo(.failure(.httpStatus(code: 429, retryAfterSeconds: nil))),
            .cosmosLatestBlock(.failure(.transport(kind: .timeout))),
            .cometStatus(.failure(.transport(kind: .tls))),
        ])
    }

    func testProbeKeepsDecoderFailuresRequestTyped() async throws {
        let transport = ProbeTransport(responses: [
            "/cosmos/base/tendermint/v1beta1/node_info": .json(#"{"default_node_info":{}}"#),
            "/cosmos/base/tendermint/v1beta1/blocks/latest": .json(
                #"{"block":{"header":{"height":"10"}}}"#
            ),
            "/status": .json(
                #"{"result":{"node_info":{},"sync_info":{"latest_block_height":"10","catching_up":false}}}"#
            ),
        ])

        let outcomes = try await LiveNodeProbe(transport: transport).probe(
            index: 0,
            family: plainFamily()
        )

        XCTAssertEqual(outcomes.map(\.result), [
            .cosmosNodeInfo(.failure(.invalidResponse(field: .nodeInfoNetwork))),
            .cosmosLatestBlock(.failure(.invalidResponse(field: .blockHeaderChainId))),
            .cometStatus(.failure(.invalidResponse(field: .cometNetwork))),
        ])
    }

    private func family() throws -> EndpointFamilyDescriptor {
        try EndpointFamilyDescriptor(
            id: "family",
            cosmosRestURL: URL(string: "https://cosmos.example/proxy%2Fv1")!,
            cometBftURL: URL(string: "https://comet.example/rpc%2Fv1/")!
        )
    }

    private func plainFamily() throws -> EndpointFamilyDescriptor {
        try EndpointFamilyDescriptor(
            id: "family",
            cosmosRestURL: URL(string: "https://cosmos.example")!,
            cometBftURL: URL(string: "https://comet.example")!
        )
    }
}

private actor ProbeTransport: IHttpTransport {
    enum Response: Sendable {
        case json(String)
        case status(Int, retryAfter: String?)
        case failure(URLError.Code)
    }

    private let responses: [String: Response]
    private(set) var requests = [URLRequest]()

    init(responses: [String: Response]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let path = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.percentEncodedPath
        let response = responses[path]!
        let status: Int
        let headers: [String: String]?
        let data: Data
        switch response {
        case let .json(value):
            status = 200
            headers = nil
            data = Data(value.utf8)
        case let .status(code, retryAfter):
            status = code
            headers = retryAfter.map { ["Retry-After": $0] }
            data = Data()
        case let .failure(code):
            throw URLError(code)
        }
        return (
            data,
            HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: headers
            )!
        )
    }
}

private actor CancellingTransport: IHttpTransport {
    private(set) var requestCount = 0

    func data(for _: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestCount += 1
        throw CancellationError()
    }
}
