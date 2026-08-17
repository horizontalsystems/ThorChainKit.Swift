@testable import ThorChainKit
import XCTest

final class PendingPublicationBarrierTests: XCTestCase {
    func testEveryGenerationIsPublishedBeforeTransport() async throws {
        let transactionID = try XCTUnwrap(TransactionID(hash: String(repeating: "A", count: 64)))
        let barrier = PendingPublicationBarrier()
        XCTAssertFalse(barrier.isAcknowledged(transactionID: transactionID, generation: 1))

        var events = [String]()
        events.append("journal")
        barrier.publish(transactionID: transactionID, generation: 1)
        events.append("published")
        let acknowledged = await barrier.wait(transactionID: transactionID, generation: 1)
        XCTAssertTrue(acknowledged)
        events.append("transport")
        XCTAssertEqual(events, ["journal", "published", "transport"])
    }

    func testObservationErrorInstallsReplacementGeneration() throws {
        let transactionID = try XCTUnwrap(TransactionID(hash: String(repeating: "B", count: 64)))
        let barrier = PendingPublicationBarrier()
        barrier.publish(transactionID: transactionID, generation: 1)
        barrier.reset()
        XCTAssertFalse(barrier.isAcknowledged(transactionID: transactionID, generation: 1))
        barrier.publish(transactionID: transactionID, generation: 2)
        XCTAssertTrue(barrier.isAcknowledged(transactionID: transactionID, generation: 2))
        XCTAssertFalse(barrier.isAcknowledged(transactionID: transactionID, generation: 1))
    }

    func testFailedPublicationAcknowledgementDoesNotPermitTransport() async throws {
        let transactionID = try XCTUnwrap(TransactionID(hash: String(repeating: "C", count: 64)))
        let barrier = PendingPublicationBarrier()
        barrier.fail(transactionID: transactionID, generation: 1)

        barrier.publish(transactionID: transactionID, generation: 1)
        let acknowledged = await barrier.wait(transactionID: transactionID, generation: 1)
        XCTAssertFalse(acknowledged)
        XCTAssertFalse(barrier.isAcknowledged(transactionID: transactionID, generation: 1))
    }
}
