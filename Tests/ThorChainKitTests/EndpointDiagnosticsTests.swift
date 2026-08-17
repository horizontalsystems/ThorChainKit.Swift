import Foundation
@testable import ThorChainKit
import XCTest

final class EndpointDiagnosticsTests: XCTestCase {
    func testOriginAndErrorsExposeOnlySanitizedFields() throws {
        let origin = try XCTUnwrap(
            EndpointOrigin(url: URL(string: "https://User:Pass@EXAMPLE.com:8443/secret-path?token=secret#fragment")!)
        )
        XCTAssertEqual(origin, EndpointOrigin(scheme: "https", host: "example.com", port: 8443))

        let diagnostic = EndpointDiagnostic(
            familyId: "family-a",
            role: .cosmosRest,
            request: .cosmosNodeInfo,
            origin: origin,
            expectedChainId: "thorchain-1",
            identityClassification: .foreign,
            reason: .identity(.foreign)
        )
        let description = String(describing: diagnostic)

        XCTAssertTrue(description.contains("family-a"))
        XCTAssertTrue(description.contains("example.com"))
        XCTAssertTrue(description.contains("thorchain-1"))
        for sentinel in ["User", "Pass", "secret-path", "token", "fragment", "foreign-secret-chain"] {
            XCTAssertFalse(description.contains(sentinel))
        }
    }

    func testProviderErrorContainsNoObservedIdentityValue() {
        let error = ProviderError.identityFailure(
            expected: "thorchain-1",
            familyId: "family-a",
            role: .cometBft,
            request: .cometStatus,
            code: .foreign
        )
        let description = String(describing: error)

        XCTAssertTrue(description.contains("thorchain-1"))
        XCTAssertFalse(description.contains("foreign-secret-chain"))
        XCTAssertFalse(description.contains("http"))
    }
}
