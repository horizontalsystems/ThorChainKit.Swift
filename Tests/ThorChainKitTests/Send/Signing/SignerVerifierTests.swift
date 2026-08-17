import Foundation
@testable import ThorChainKit
import XCTest

final class SignerVerifierTests: XCTestCase {
    func testCompactSignatureRules() throws {
        XCTAssertNoThrow(try CompactSignature(Data([1]) + Data(repeating: 0, count: 31) + Data([1]) + Data(repeating: 0, count: 31)))
        XCTAssertThrowsError(try CompactSignature(Data(repeating: 0, count: 63)))
        XCTAssertThrowsError(try CompactSignature(Data(repeating: 0xFF, count: 64)))
    }
}
