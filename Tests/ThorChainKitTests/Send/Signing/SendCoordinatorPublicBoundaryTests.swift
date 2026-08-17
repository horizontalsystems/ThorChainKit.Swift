import Foundation
@testable import ThorChainKit
import XCTest

final class SendCoordinatorPublicBoundaryTests: XCTestCase {
    func testPublicSendIsUnavailableAndSideEffectFree() async throws {
        let runtime = try SendRuntime(address: sendTestAddress(), persistenceNamespace: "coordinator-public")
        await runtime.activate(generation: 1)
        let signer = PublicBoundarySigner()
        let quote = try issueTestQuote(in: QuoteStore(), clock: TestSendClock())

        do {
            _ = try await runtime.send(quote: quote, signer: signer)
            XCTFail("public S2-04 send must remain fail-closed")
        } catch let error as SendError {
            XCTAssertEqual(error, .operationUnavailable)
        }
        XCTAssertEqual(signer.callCount, 0)
    }
}

private final class PublicBoundarySigner: ISigner, @unchecked Sendable {
    let compressedPublicKey = Data(repeating: 0, count: 33)
    private(set) var callCount = 0

    func sign(digest _: Data) async throws -> Data {
        callCount += 1
        return Data()
    }
}
