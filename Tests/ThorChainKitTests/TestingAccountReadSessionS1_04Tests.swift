import Foundation
@testable import ThorChainKit
import XCTest

final class TestingAccountReadSessionS1_04Tests: XCTestCase {
    func testSessionReturnsProjectionFromTheRealReadPath() async throws {
        let family = try EndpointFamilyDescriptor(
            id: "fixture-primary",
            cosmosRestURL: URL(string: "https://cosmos.example")!,
            cometBftURL: URL(string: "https://comet.example")!
        )
        let configuration = try EndpointConfiguration(families: [family])
        let projection = try await TestingAccountReadSession(
            address: Address("thor166aczv0jatlnyzz8zsczdzk9xxxgppfpu530jl", network: .mainnet),
            configuration: configuration,
            transport: FixtureReadTransport()
        ).read()
        XCTAssertEqual(projection.providerFamilyId, "fixture-primary")
        XCTAssertEqual(projection.runeAmountDecimal, "3")
    }
}

private actor FixtureReadTransport: TestingHTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.path
        let body: String
        if path.hasSuffix("node_info") {
            body = #"{"default_node_info":{"network":"thorchain-1"}}"#
        } else if path.hasSuffix("blocks/latest") {
            body = #"{"block":{"header":{"chain_id":"thorchain-1","height":"100"}}}"#
        } else if path == "/status" {
            body = #"{"result":{"node_info":{"network":"thorchain-1"},"sync_info":{"latest_block_height":"100","catching_up":false}}}"#
        } else if path.contains("/accounts/") {
            body = #"{"account":{"@type":"/cosmos.auth.v1beta1.BaseAccount","account_number":"1","sequence":"2"}}"#
        } else {
            body = #"{"balances":[{"denom":"rune","amount":"3"}],"pagination":{"next_key":null}}"#
        }
        let headers = path.contains("/accounts/") || path.contains("/balances/")
            ? ["Grpc-Metadata-X-Cosmos-Block-Height": "100"]
            : [:]
        return (
            Data(body.utf8),
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!
        )
    }
}
