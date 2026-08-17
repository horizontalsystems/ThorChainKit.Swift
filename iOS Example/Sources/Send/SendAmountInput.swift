import BigInt
import Foundation

enum SendAmountInput {
    static let unitsPerRune = BigUInt(100_000_000)
    static let maximum = (BigUInt(1) << 256) - 1

    static func parse(_ text: String) -> BigUInt? {
        guard !text.isEmpty, text.unicodeScalars.allSatisfy({ $0.value < 128 }) else { return nil }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, !parts[0].isEmpty,
              parts[0].allSatisfy(\.isNumber),
              parts[0].first != "-" else { return nil }
        let fraction = parts.count == 2 ? String(parts[1]) : ""
        guard parts.count == 1 || !fraction.isEmpty, fraction.count <= 8,
              fraction.allSatisfy(\.isNumber)
        else {
            return nil
        }
        let integer = BigUInt(String(parts[0]), radix: 10) ?? 0
        let fractional = BigUInt(fraction.padding(toLength: 8, withPad: "0", startingAt: 0), radix: 10) ?? 0
        let value = integer * unitsPerRune + fractional
        guard value > 0, value <= maximum, value.serialize().count <= 32 else { return nil }
        return value
    }
}
