import Foundation

public struct FixtureScenario: Sendable {
    public let namespace: String
    public let expectedDigest: Data
    public let expectedSignedBytes: Data
    public let expectedTransactionHash: String

    public init() {
        namespace = "thor-example/fixture/send-checktx-accepted"
        expectedDigest = Data(hex: "1ff56dd4c3627af0cee040965178f50c8d7c854e909d7b54aedbd1b7bf110b68")
        expectedSignedBytes = Data(hex: "0a530a510a0e2f74797065732e4d736753656e64123f0a14751e76e8199196d454941c45d1b3a323f1433bd612145a0dba49dab8fec87c6dd7c01b564ee72a8515a61a110a0472756e65120931303030303030303012590a500a460a1f2f636f736d6f732e63727970746f2e736563703235366b312e5075624b657912230a210279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f8179812040a0208011801120510c08db7011a4023103daa64330d051da3bfa85ea7c8af9080edf19b19a306403303634b0992a32cc1b9061b2e76cd245edb2976bb437bc6636dfb23deae31e38508c5478dae45")
        expectedTransactionHash = "3685BF7AD0C65889B763D4B6D1F1EDEEC96E9B63B63F8DB992D00757EB5F136E"
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
