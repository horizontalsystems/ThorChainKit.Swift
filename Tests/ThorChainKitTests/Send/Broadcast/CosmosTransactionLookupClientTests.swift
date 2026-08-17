import Foundation
@testable import ThorChainKit
import XCTest

final class CosmosTransactionLookupClientTests: XCTestCase {
    func testMatchingHashAndExactNotFoundAreTheOnlyRetryAuthorities() async throws {
        let transactionID = try XCTUnwrap(TransactionID(hash: String(repeating: "A", count: 64)))
        let found = try makeResponse(
            status: 200,
            body: "{\"tx_response\":{\"txhash\":\"\(transactionID.hash)\",\"height\":\"12\"}}"
        )
        let foundClient = CosmosTransactionLookupClient(baseURL: URL(string: "https://fixture.example")!, transport: LookupTransport(result: found))
        let foundResult = await foundClient.lookup(transactionID: transactionID)
        XCTAssertEqual(foundResult, .found(transactionID: transactionID, height: 12))

        let notFoundBody = "{\"code\":5,\"message\":\"rpc error: code = NotFound desc = tx not found: \(transactionID.hash): key not found\",\"details\":[]}"
        let notFound = try makeResponse(status: 404, body: notFoundBody)
        let notFoundClient = CosmosTransactionLookupClient(baseURL: URL(string: "https://fixture.example")!, transport: LookupTransport(result: notFound))
        let notFoundResult = await notFoundClient.lookup(transactionID: transactionID)
        XCTAssertEqual(notFoundResult, .notFound)

        let mismatched = try makeResponse(
            status: 200,
            body: "{\"tx_response\":{\"txhash\":\"\(String(repeating: "B", count: 64))\",\"height\":\"12\"}}"
        )
        let mismatchedClient = CosmosTransactionLookupClient(baseURL: URL(string: "https://fixture.example")!, transport: LookupTransport(result: mismatched))
        let mismatchedResult = await mismatchedClient.lookup(transactionID: transactionID)
        XCTAssertEqual(mismatchedResult, .providerInconsistent)
    }

    func testMalformedOrWrongMediaResponsesRemainNonAuthoritative() async throws {
        let transactionID = try XCTUnwrap(TransactionID(hash: String(repeating: "A", count: 64)))
        let response = try makeResponse(
            status: 200,
            body: "{\"tx_response\":{\"txhash\":\"\(transactionID.hash)\",\"height\":\"12\"}}",
            contentType: "text/plain"
        )
        let client = CosmosTransactionLookupClient(baseURL: URL(string: "https://fixture.example")!, transport: LookupTransport(result: response))
        let result = await client.lookup(transactionID: transactionID)
        XCTAssertEqual(result, .transportFailure)
    }

    private func makeResponse(status: Int, body: String, contentType: String = "application/json") throws -> (Data, HTTPURLResponse) {
        let url = try XCTUnwrap(URL(string: "https://fixture.example/tx"))
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": contentType]))
        return (Data(body.utf8), response)
    }
}

private actor LookupTransport: IHttpTransport {
    let result: (Data, HTTPURLResponse)

    init(result: (Data, HTTPURLResponse)) {
        self.result = result
    }

    func data(for _: URLRequest) async throws -> (Data, HTTPURLResponse) {
        result
    }
}
