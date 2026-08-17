import Foundation

public struct DerivationPath: Hashable, Sendable {
    public static let defaultAccount = DerivationPath(rawValue: "m/44'/931'/0'/0/0")

    public let rawValue: String

    public init(_ raw: String) throws {
        let components = raw.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.count == 6 else {
            throw DerivationPathError.invalidComponentCount
        }
        guard components[0] == "m" else {
            throw DerivationPathError.malformedComponent
        }
        guard components[1] == "44'" else {
            throw DerivationPathError.invalidPurpose
        }
        guard components[2] == "931'" else {
            throw DerivationPathError.invalidCoinType
        }
        guard Self.isHardenedDecimal(components[3]) else {
            if components[3].hasSuffix("'") {
                throw DerivationPathError.malformedComponent
            }
            throw DerivationPathError.invalidAccount
        }
        guard Self.isDecimal(components[4]) else {
            throw DerivationPathError.invalidChain
        }
        guard Self.isDecimal(components[5]) else {
            throw DerivationPathError.invalidIndex
        }
        rawValue = raw
    }

    private init(rawValue: String) {
        self.rawValue = rawValue
    }

    private static func isHardenedDecimal(_ value: String) -> Bool {
        guard value.last == "'" else { return false }
        return isDecimal(String(value.dropLast()))
    }

    private static func isDecimal(_ value: String) -> Bool {
        guard !value.isEmpty, value.first != "0" || value.count == 1 else { return false }
        return value.unicodeScalars.allSatisfy { (48 ... 57).contains($0.value) }
    }
}

public enum DerivationPathError: Error, Equatable {
    case invalidComponentCount
    case invalidPurpose
    case invalidCoinType
    case invalidAccount
    case invalidChain
    case invalidIndex
    case malformedComponent
}
