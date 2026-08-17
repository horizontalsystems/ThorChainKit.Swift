enum Bech32Codec {
    private static let charset = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")
    private static let generators = [0x3B6A_57B2, 0x2650_8E6D, 0x1EA1_19FA, 0x3D42_33DD, 0x2A14_62B3]

    static func decode(_ raw: String) throws -> (hrp: String, words: [UInt8]) {
        guard !raw.isEmpty else {
            throw AddressError.empty
        }
        guard raw.utf8.count <= 90 else {
            throw AddressError.tooLong
        }
        let lowercased = raw.lowercased()
        let uppercased = raw.uppercased()
        guard raw == lowercased || raw == uppercased else {
            throw AddressError.mixedCase
        }
        for scalar in raw.unicodeScalars where !(33 ... 126).contains(scalar.value) {
            throw AddressError.invalidCharacter(Character(String(scalar)))
        }

        guard let separator = lowercased.lastIndex(of: "1") else {
            throw AddressError.missingSeparator
        }
        let hrp = String(lowercased[..<separator])
        let encoded = lowercased[lowercased.index(after: separator)...]
        guard !hrp.isEmpty, encoded.count >= 6 else {
            throw AddressError.missingSeparator
        }

        var values = [UInt8]()
        for character in encoded {
            guard let index = charset.firstIndex(of: character) else {
                throw AddressError.invalidCharacter(character)
            }
            values.append(UInt8(index))
        }
        guard polymod(hrpExpand(hrp) + values) == 1 else {
            throw AddressError.invalidChecksum
        }
        return (hrp, Array(values.dropLast(6)))
    }

    static func encode(hrp: String, words: [UInt8]) -> String {
        let checksum = createChecksum(hrp: hrp, words: words)
        return hrp + "1" + (words + checksum).map { String(charset[Int($0)]) }.joined()
    }

    private static func createChecksum(hrp: String, words: [UInt8]) -> [UInt8] {
        let value = polymod(hrpExpand(hrp) + words + Array(repeating: 0, count: 6)) ^ 1
        return (0 ..< 6).map { UInt8((value >> (5 * (5 - $0))) & 31) }
    }

    private static func hrpExpand(_ hrp: String) -> [UInt8] {
        let scalars = hrp.unicodeScalars.map { UInt8($0.value) }
        return scalars.map { $0 >> 5 } + [0] + scalars.map { $0 & 31 }
    }

    private static func polymod(_ values: [UInt8]) -> Int {
        var checksum = 1
        for value in values {
            let top = checksum >> 25
            checksum = ((checksum & 0x1FFFFFF) << 5) ^ Int(value)
            for index in generators.indices where ((top >> index) & 1) == 1 {
                checksum ^= generators[index]
            }
        }
        return checksum
    }
}
