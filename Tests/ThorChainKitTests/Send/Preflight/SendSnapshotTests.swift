import BigInt
import XCTest
@testable import ThorChainKit

final class SendSnapshotTests: XCTestCase {
    func testDigestIsStableForTheSameCanonicalSnapshot() throws {
        let first = try SendSnapshot.fixture(height: 42)
        let second = try SendSnapshot.fixture(height: 42)
        XCTAssertEqual(first.digest, second.digest)
        XCTAssertNotEqual(first.digest, try SendSnapshot.fixture(height: 43).digest)
        XCTAssertEqual(first.amount + first.nativeFee, first.totalDebit)
    }

    func testDigestIncludesPublicKeyAndPolicyState() throws {
        let base = try SendSnapshot.fixture(height: 42)
        let withKey = try SendSnapshot(
            familyID: base.familyID, chainID: base.chainID, height: base.height, sender: base.sender, recipient: base.recipient,
            accountNumber: base.accountNumber, sequence: base.sequence, amount: base.amount, nativeFee: base.nativeFee, mimir: base.mimir, memoMaximumBytes: base.memoMaximumBytes,
            policyRevision: base.policyRevision, accountPublicKey: "/cosmos.crypto.secp256k1.PubKey", accountPublicKeyData: Data([2] + Array(repeating: 1, count: 32))
        )
        XCTAssertNotEqual(base.digest, withKey.digest)
        XCTAssertEqual(withKey.digestHex, "cfe885d3c24d80d774f97810b2cac37fecf291e17d779b2377e91f324ff4d18c")
    }

    func testDigestMatchesTheApprovedFixedVector() throws {
        // Re-approved when the balances left the snapshot: the preflight no longer reads
        // them, so the digest cannot bind what it never saw.
        XCTAssertEqual(try SendSnapshot.fixture(height: 42).digestHex, "329049031ca55e169e2017006425f49cbbca55059aacea1b36b9f29c0015d6c3")
    }

    func testPublicKeyStateRejectsImpossibleAndUncompressedValues() throws {
        let base = try SendSnapshot.fixture(height: 42)
        for (typeURL, data) in [
            ("/cosmos.crypto.secp256k1.PubKey" as String?, nil as Data?),
            (nil as String?, Data([2] + Array(repeating: 1, count: 32))),
            ("/cosmos.crypto.secp256k1.PubKey" as String?, Data([4] + Array(repeating: 1, count: 32)))
        ] {
            XCTAssertThrowsError(try SendSnapshot(
                familyID: base.familyID, chainID: base.chainID, height: base.height, sender: base.sender, recipient: base.recipient,
                accountNumber: base.accountNumber, sequence: base.sequence, amount: base.amount, nativeFee: base.nativeFee, mimir: base.mimir, memoMaximumBytes: base.memoMaximumBytes,
                policyRevision: base.policyRevision, accountPublicKey: typeURL, accountPublicKeyData: data
            ))
        }
    }
}
