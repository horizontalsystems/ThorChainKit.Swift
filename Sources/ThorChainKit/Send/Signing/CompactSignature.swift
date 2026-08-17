import Foundation

struct CompactSignature: Sendable, Equatable {
    let rawValue: Data

    init(_ rawValue: Data) throws {
        guard rawValue.count == 64 else { throw SendError.invalidSignature }
        let r = Array(rawValue.prefix(32))
        let s = Array(rawValue.suffix(32))
        guard Self.isValidScalar(r), Self.isValidScalar(s), s.lexicographicallyPrecedes(Self.halfOrder) || s == Self.halfOrder else {
            throw SendError.invalidSignature
        }
        self.rawValue = rawValue
    }

    private static let order = bytes("FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141")
    private static let halfOrder = bytes("7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0")

    private static func isValidScalar(_ scalar: [UInt8]) -> Bool {
        scalar.contains(where: { $0 != 0 }) && scalar.lexicographicallyPrecedes(order)
    }

    private static func bytes(_ value: String) -> [UInt8] {
        stride(from: 0, to: value.count, by: 2).map { index in
            let start = value.index(value.startIndex, offsetBy: index)
            let end = value.index(start, offsetBy: 2)
            return UInt8(value[start ..< end], radix: 16)!
        }
    }
}
