@testable import ThorChainKit
import XCTest

final class EndpointManifestTests: XCTestCase {
    func testEveryProofModeRequiresExactPositiveHeight() {
        XCTAssertTrue(HeightProof.restHeader(expected: 10, actual: 10).isExact)
        XCTAssertTrue(HeightProof.cometABCI(expected: 10, actual: 10).isExact)
        XCTAssertTrue(HeightProof.body(expected: 10, actual: 10).isExact)
        XCTAssertFalse(HeightProof.restHeader(expected: 10, actual: 11).isExact)
        XCTAssertFalse(HeightProof.body(expected: 10, actual: nil).isExact)
    }

    func testChainTemplatesPinFourReadOnlyRoutes() {
        for chain in [Network.Chain.thor, .maya] {
            let templates = SendRoutes.templates(chain: chain)
            XCTAssertEqual(templates.map(\.route), ["account", "network-fee", "mimir", "recipient-account"])
            XCTAssertTrue(templates.allSatisfy { !$0.path.isEmpty })
            XCTAssertTrue(templates.allSatisfy { $0.requestEncoding == ($0.proofMode == .cometABCI ? .protobufABCI : .jsonREST) })
            XCTAssertFalse(SendRoutes.manifestRevision(chain: chain).isEmpty)
            XCTAssertFalse(SendRoutes.schemaRevision(chain: chain).isEmpty)
        }

        XCTAssertEqual(SendRoutes.templates(chain: .thor).first { $0.route == "mimir" }?.path, "/thorchain/mimir")
        XCTAssertEqual(SendRoutes.templates(chain: .thor).first { $0.route == "network-fee" }?.proofMode, .cometABCI)
        XCTAssertEqual(SendRoutes.templates(chain: .maya).first { $0.route == "network-fee" }?.path, "/mayachain/constants")
        XCTAssertEqual(SendRoutes.templates(chain: .maya).first { $0.route == "mimir" }?.path, "/mayachain/mimir")
        // mayanode ignores a historical ?height= query; the pin rides the header
        XCTAssertTrue(SendRoutes.templates(chain: .maya).allSatisfy { $0.historicalHeightParameter == nil })
    }

    // Routes are a property of the chain, not of a provider: any family from the app's
    // configuration gets the same pinned request shapes.
    func testRouteBuilderServesAnyConfiguredFamily() throws {
        let liquify = try EndpointFamilyDescriptor(
            id: "Liquify",
            cosmosRestURL: URL(string: "https://gateway.liquify.com/chain/thorchain_api")!,
            cometBftURL: URL(string: "https://gateway.liquify.com/chain/thorchain_rpc")!
        )

        let mimir = try SendRoutes.route("mimir", family: liquify, chain: .thor)
        XCTAssertEqual(mimir.record.familyID, "Liquify")
        XCTAssertEqual(mimir.record.role, .rest)
        XCTAssertEqual(mimir.record.host, "gateway.liquify.com")
        XCTAssertEqual(mimir.record.path, "/chain/thorchain_api")
        XCTAssertEqual(mimir.path, "/thorchain/mimir")

        let account = try SendRoutes.route("account", family: liquify, chain: .thor)
        XCTAssertEqual(account.record.role, .rpc)
        XCTAssertEqual(account.record.path, "/chain/thorchain_rpc")

        XCTAssertThrowsError(try SendRoutes.route("unknown", family: liquify, chain: .thor))
    }

    func testMayaRouteBuilderUsesFamilyEndpoints() throws {
        let mayanode = try EndpointFamilyDescriptor(
            id: "Mayanode",
            cosmosRestURL: URL(string: "https://mayanode.mayachain.info")!,
            cometBftURL: URL(string: "https://tendermint.mayachain.info")!
        )

        let fee = try SendRoutes.route("network-fee", family: mayanode, chain: .maya)
        XCTAssertEqual(fee.record.role, .rest)
        XCTAssertEqual(fee.record.host, "mayanode.mayachain.info")
        XCTAssertEqual(fee.path, "/mayachain/constants")
        XCTAssertEqual(fee.requestEncoding, .jsonREST)

        let recipient = try SendRoutes.route("recipient-account", family: mayanode, chain: .maya)
        XCTAssertEqual(recipient.record.role, .rpc)
        XCTAssertEqual(recipient.record.host, "tendermint.mayachain.info")
        XCTAssertEqual(recipient.path, "/cosmos.auth.v1beta1.Query/Account")
    }
}
