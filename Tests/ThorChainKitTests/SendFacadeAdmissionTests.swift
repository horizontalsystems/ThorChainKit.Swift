import BigInt
import Combine
import Foundation
@testable import ThorChainKit
import XCTest

final class SendFacadeAdmissionTests: XCTestCase {
    func testRetryAdmissionIsLifecycleFirstAndDeferredEngineFailsClosed() async throws {
        let address = try sendTestAddress()
        let runtime = SendRuntime(address: address)
        let kit = makeTestKit(address: address, transactionSender: runtime, persistenceNamespace: "admission")
        let transactionId = try XCTUnwrap(TransactionID(hash: String(repeating: "A", count: 64)))

        do {
            _ = try await kit.retryBroadcast(transactionId: transactionId, acceptingNativeFee: 1)
            XCTFail("inactive kit must reject retry")
        } catch let error as SendError {
            XCTAssertEqual(error, .kitNotStarted)
        }

        await runtime.activate(generation: 1)
        do {
            _ = try await kit.retryBroadcast(transactionId: transactionId, acceptingNativeFee: 1)
            XCTFail("deferred retry engine must fail closed")
        } catch let error as SendError {
            XCTAssertEqual(error, .operationUnavailable)
        }
    }
}

private final class AdmissionSigner: ISigner, @unchecked Sendable {
    let compressedPublicKey = Data()
    private(set) var signCallCount = 0
    func sign(digest _: Data) async throws -> Data {
        signCallCount += 1
        return Data()
    }
}
