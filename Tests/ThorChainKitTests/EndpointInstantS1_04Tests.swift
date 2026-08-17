@testable import ThorChainKit
import XCTest

final class EndpointInstantS1_04Tests: XCTestCase {
    func testAdvancedRejectsInvalidAndSaturatesOverflow() {
        let instant = EndpointInstant(nanoseconds: 10)
        XCTAssertEqual(instant.advanced(seconds: -1), instant)
        XCTAssertEqual(instant.advanced(seconds: .infinity), instant)
        XCTAssertEqual(
            EndpointInstant(nanoseconds: UInt64.max - 1).advanced(seconds: 1).nanoseconds,
            UInt64.max
        )
    }
}
