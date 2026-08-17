import Foundation
@testable import ThorChainKit
import XCTest

final class MainnetReadTests: XCTestCase {
    func testOptInMainnetReadRequiresExplicitInputs() async throws {
        guard ProcessInfo.processInfo.environment["THORCHAIN_RUN_LIVE"] == "1" else {
            XCTFail("THORCHAIN_RUN_LIVE=1 is required for the explicit live target")
            return
        }
        XCTAssertNil(ProcessInfo.processInfo.environment["THORCHAIN_PROVIDER_CREDENTIAL"])

        guard let expectedHead = required("THORCHAIN_S1_04_EXPECTED_HEAD"),
              let familyId = required("THORCHAIN_S1_04_FAMILY_ID"),
              let cosmosURL = required("THORCHAIN_S1_04_COSMOS_URL").flatMap(URL.init(string:)),
              let cometURL = required("THORCHAIN_S1_04_COMET_URL").flatMap(URL.init(string:)),
              let existingAddress = required("THORCHAIN_S1_04_EXISTING_ADDRESS").flatMap({ try? Address($0, network: .mainnet) }),
              let absentAddress = required("THORCHAIN_S1_04_ABSENT_ADDRESS").flatMap({ try? Address($0, network: .mainnet) }),
              let evidencePath = required("THORCHAIN_S1_04_EVIDENCE_PATH")
        else { return }

        let family = try EndpointFamilyDescriptor(
            id: familyId,
            cosmosRestURL: cosmosURL,
            cometBftURL: cometURL
        )
        let policy = try EndpointPolicy(maximumAttempts: 1, maximumBalancePageCount: 100)
        let configuration = try EndpointConfiguration(
            families: [family],
            policy: policy
        )
        let transport = LiveEvidenceTransport()
        let pool = EndpointPool(
            network: .mainnet,
            configuration: configuration,
            probe: LiveNodeProbe(configuration: configuration, transport: transport)
        )
        let lease = try await pool.lease(excludingFamilyIds: [])
        XCTAssertEqual(lease.family.id, familyId)
        XCTAssertEqual(lease.verifiedChainId, "thorchain-1")
        XCTAssertGreaterThan(lease.cosmosReadHeight, 0)
        XCTAssertGreaterThan(lease.cometReferenceHeight, 0)
        XCTAssertLessThanOrEqual(
            abs(lease.cosmosReadHeight - lease.cometReferenceHeight),
            policy.maximumHeightLag
        )

        let client = LiveThorNodeClient(
            transport: transport,
            requestTimeout: configuration.requestTimeout,
            clientId: configuration.clientId,
            maximumBalancePageCount: policy.maximumBalancePageCount
        )
        let coordinator = ReadOperationCoordinator(
            pool: pool,
            client: client,
            configuration: configuration
        )
        let existing = try await coordinator.read(address: existingAddress)
        let absent = try await coordinator.read(address: absentAddress)
        guard let rawRuneAmount = await transport.runeAmount,
              let implementationRuneAmount = existing.balances.first(where: {
                  $0.denom.rawValue == "rune"
              })?.amountDecimal
        else {
            XCTFail("Existing live account must expose a RUNE balance")
            return
        }

        XCTAssertNotNil(existing.account)
        XCTAssertEqual(existing.familyId, familyId)
        XCTAssertEqual(existing.acceptedHeight, lease.cosmosReadHeight)
        XCTAssertEqual(rawRuneAmount, implementationRuneAmount)
        XCTAssertNil(absent.account)
        XCTAssertTrue(absent.balances.isEmpty)

        let evidence = LiveEvidence(
            schemaVersion: 1,
            head: expectedHead,
            familyId: familyId,
            chainId: lease.verifiedChainId,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            cosmosHeight: lease.cosmosReadHeight,
            cometHeight: lease.cometReferenceHeight,
            acceptedHeight: existing.acceptedHeight,
            existing: .init(
                class: "existing",
                accountExists: existing.account != nil,
                rawRuneAmount: rawRuneAmount,
                implementationRuneAmount: implementationRuneAmount
            ),
            absent: .init(
                class: "absent",
                accountExists: absent.account != nil,
                balanceCount: absent.balances.count
            )
        )
        let output = URL(fileURLWithPath: evidencePath)
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(evidence).write(to: output, options: .atomic)
    }

    private func required(_ name: String) -> String? {
        guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
            XCTFail("\(name) is required for the explicit live target")
            return nil
        }
        return value
    }
}

private struct LiveEvidence: Encodable {
    struct Existing: Encodable {
        let `class`: String
        let accountExists: Bool
        let rawRuneAmount: String
        let implementationRuneAmount: String
    }

    struct Absent: Encodable {
        let `class`: String
        let accountExists: Bool
        let balanceCount: Int
    }

    let schemaVersion: Int
    let head: String
    let familyId: String
    let chainId: String
    let timestamp: String
    let cosmosHeight: Int64
    let cometHeight: Int64
    let acceptedHeight: Int64
    let existing: Existing
    let absent: Absent
}

private actor LiveEvidenceTransport: IHttpTransport {
    private let base = URLSessionTransport()
    private(set) var runeAmount: String?

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let result = try await base.data(for: request)
        guard request.url?.path.contains("/cosmos/bank/v1beta1/balances/") == true,
              let object = try? JSONSerialization.jsonObject(with: result.0) as? [String: Any],
              let balances = object["balances"] as? [[String: Any]]
        else { return result }

        if let amount = balances.first(where: {
            ($0["denom"] as? String) == "rune"
        })?["amount"] as? String {
            runeAmount = amount
        }
        return result
    }
}
