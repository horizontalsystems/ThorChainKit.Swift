import Foundation
@testable import ThorChainKit
import XCTest

final class TestingEndpointPolicySessionTests: XCTestCase {
    func testFixtureScriptsExecuteTheRealPoolAndReturnSanitizedSnapshots() async throws {
        let configuration = try EndpointConfiguration(families: [
            EndpointFamilyDescriptor(
                id: "fixture-a",
                cosmosRestURL: URL(string: "https://cosmos.example/proxy-secret")!,
                cometBftURL: URL(string: "https://comet.example/rpc-secret")!
            ),
        ])

        let healthy = await TestingEndpointPolicySession(
            network: .mainnet,
            configuration: configuration,
            script: .healthy
        ).snapshot()
        XCTAssertEqual(healthy.selectedFamilyId, "fixture-a")
        XCTAssertEqual(healthy.identityClassification, "expected")
        XCTAssertEqual(healthy.cosmosHeight, 100)
        XCTAssertEqual(healthy.cometHeight, 102)
        XCTAssertNil(healthy.rejectionReason)

        let mixed = await TestingEndpointPolicySession(
            network: .mainnet,
            configuration: configuration,
            script: .mixedIdentity
        ).snapshot()
        XCTAssertNil(mixed.selectedFamilyId)
        XCTAssertEqual(mixed.identityClassification, "mixed")
        XCTAssertEqual(mixed.rejectionReason, "identity_mixed")

        let catchingUp = await TestingEndpointPolicySession(
            network: .mainnet,
            configuration: configuration,
            script: .catchingUp
        ).snapshot()
        XCTAssertEqual(catchingUp.rejectionReason, "catching_up")
        XCTAssertTrue(catchingUp.catchingUp)

        let stale = await TestingEndpointPolicySession(
            network: .mainnet,
            configuration: configuration,
            script: .staleCosmos
        ).snapshot()
        XCTAssertEqual(stale.rejectionReason, "stale")
        XCTAssertEqual(stale.cosmosHeight, 80)
        XCTAssertEqual(stale.cometHeight, 100)

        let chainnet = try await TestingEndpointPolicySession(
            network: .chainnet(expectedChainId: "chainnet-fixture"),
            configuration: configuration,
            script: .healthy
        ).snapshot()
        XCTAssertEqual(chainnet.expectedChainId, "chainnet-fixture")
        XCTAssertEqual(chainnet.identityClassification, "expected")

        for snapshot in [healthy, mixed, catchingUp, stale, chainnet] {
            let description = String(describing: snapshot)
            XCTAssertFalse(description.contains("proxy-secret"))
            XCTAssertFalse(description.contains("rpc-secret"))
            XCTAssertFalse(description.contains("foreign-secret-chain"))
        }
    }
}
