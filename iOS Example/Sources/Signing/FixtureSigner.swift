import Foundation
import ThorChainKit

public final class FixtureSigner: Signer, @unchecked Sendable {
    public let compressedPublicKey: Data
    public let signature: Data
    private let expectedDigest: Data

    public init(expectedDigest: Data, signature: Data, compressedPublicKey: Data) {
        self.expectedDigest = expectedDigest
        self.signature = signature
        self.compressedPublicKey = compressedPublicKey
    }

    public static func golden() -> FixtureSigner {
        FixtureSigner(
            expectedDigest: Data(hex: "1ff56dd4c3627af0cee040965178f50c8d7c854e909d7b54aedbd1b7bf110b68"),
            signature: Data(hex: "23103daa64330d051da3bfa85ea7c8af9080edf19b19a306403303634b0992a32cc1b9061b2e76cd245edb2976bb437bc6636dfb23deae31e38508c5478dae45"),
            compressedPublicKey: Data(hex: "0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798")
        )
    }

    public func sign(_ request: SigningRequest) async throws -> Data {
        guard request.digest == expectedDigest else { throw SendError.signerFailed }
        return signature
    }
}

private extension Data {
    init(hex: String) {
        self.init(stride(from: 0, to: hex.count, by: 2).compactMap {
            let start = hex.index(hex.startIndex, offsetBy: $0)
            let end = hex.index(start, offsetBy: 2)
            return UInt8(hex[start ..< end], radix: 16)
        })
    }
}
