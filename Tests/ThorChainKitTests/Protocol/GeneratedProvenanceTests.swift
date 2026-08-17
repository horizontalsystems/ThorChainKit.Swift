import CryptoKit
import Foundation
import XCTest

final class GeneratedProvenanceTests: XCTestCase {
    func testTransactionCodecProvenanceAndGeneratedSurfaceArePinned() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let provenance = try String(contentsOf: root.appendingPathComponent("Sources/ThorChainKit/Protocol/Generated/PROVENANCE.md"))
        for marker in [
            "a759cb4f",
            "v0.53.0",
            "cosmossdk.io/api v0.9.2",
            "1.33.3",
            "c169a5744230951031770e27e475ff6eefe51f9d",
            "libprotoc 34.1",
            "59001d00d60e6ed0e6c49e2ae6591b58882cec5bf45402f937b22566be893d4e",
            "18bb412f527df413e3f0aacf20b6b8ab95ca99191b7c75a991505c6b25fd3d7a",
            "Sources/ThorChainKit/Protocol/Generated/upstream",
            "Sources/ThorChainKit/Network/Generated/Query/upstream",
            "cosmos/tx/signing/v1beta1/signing.proto",
            "cosmos/tx/v1beta1/tx.proto",
            "thorchain/v1/types/msg_send.proto",
            "cosmos/base/v1beta1/coin.proto",
            "google/protobuf/any.proto",
            "gogoproto/gogo.proto",
            "amino/amino.proto",
            "408b074f81f3dafb440cd61921bf244eab2ff20cb1f2a9f247265d031481c9ec",
            "d7c79a05a5c7fae89f0aff26d112e0b60f082fc7fc424e8910be99c86b656260",
            "a2bef0fb7e233ff2f442da08b3764be6ce59cc3f2df05cd1c9a44dbb5b55c18f",
            "bc4cb71a5b49ce23e7b9ff8e5cd9f42efa9527c8f2d2e3861c901c7e86be202e",
            "cmp \"$tmp/cosmos/tx/v1beta1/tx.pb.swift\"",
        ] {
            XCTAssertTrue(provenance.contains(marker), "missing provenance marker: \(marker)")
        }

        let inputHashes = [
            ("Sources/ThorChainKit/Protocol/Generated/upstream/cosmos/tx/signing/v1beta1/signing.proto", "744c8e2ed515a064abe34a9fe2ec23556dd8d52776e52cc8dbaed89999b7805a"),
            ("Sources/ThorChainKit/Protocol/Generated/upstream/cosmos/tx/v1beta1/tx.proto", "47cc8faa152137126a9fc7d30d0d146eb3500704990a0d6d6e6e9a3f2fd2523f"),
            ("Sources/ThorChainKit/Protocol/Generated/upstream/thorchain/v1/types/msg_send.proto", "3396f77b196748d187206dc4235eec9112bd9a914e84ca7ee4d466078a4ceff8"),
            ("Sources/ThorChainKit/Network/Generated/Query/upstream/cosmos/base/v1beta1/coin.proto", "408b074f81f3dafb440cd61921bf244eab2ff20cb1f2a9f247265d031481c9ec"),
            ("Sources/ThorChainKit/Network/Generated/Query/upstream/google/protobuf/any.proto", "d7c79a05a5c7fae89f0aff26d112e0b60f082fc7fc424e8910be99c86b656260"),
            ("Sources/ThorChainKit/Network/Generated/Query/upstream/gogoproto/gogo.proto", "a2bef0fb7e233ff2f442da08b3764be6ce59cc3f2df05cd1c9a44dbb5b55c18f"),
            ("Sources/ThorChainKit/Network/Generated/Query/upstream/amino/amino.proto", "bc4cb71a5b49ce23e7b9ff8e5cd9f42efa9527c8f2d2e3861c901c7e86be202e"),
        ]
        for (path, expectedHash) in inputHashes {
            let data = try Data(contentsOf: root.appendingPathComponent(path))
            let actualHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(actualHash, expectedHash, "unexpected provenance input: \(path)")
        }

        let generated = try String(contentsOf: root.appendingPathComponent("Sources/ThorChainKit/Protocol/Generated/Tx.pb.swift"))
        XCTAssertTrue(generated.contains("Cosmos_Tx_V1beta1_SignDoc"))
        XCTAssertTrue(generated.contains("Cosmos_Tx_V1beta1_TxRaw"))
    }
}
