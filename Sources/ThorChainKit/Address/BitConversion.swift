enum BitConversion {
    static func convert(
        _ values: [UInt8],
        fromBits: Int,
        toBits: Int,
        pad: Bool
    ) throws -> [UInt8] {
        var accumulator = 0
        var bitCount = 0
        var result = [UInt8]()
        let outputMask = (1 << toBits) - 1
        let accumulatorMask = (1 << (fromBits + toBits - 1)) - 1

        for value in values {
            guard value >> fromBits == 0 else {
                throw AddressError.invalidPadding
            }
            accumulator = ((accumulator << fromBits) | Int(value)) & accumulatorMask
            bitCount += fromBits
            while bitCount >= toBits {
                bitCount -= toBits
                result.append(UInt8((accumulator >> bitCount) & outputMask))
            }
        }

        if pad {
            if bitCount > 0 {
                result.append(UInt8((accumulator << (toBits - bitCount)) & outputMask))
            }
        } else if bitCount >= fromBits
            || ((accumulator << (toBits - bitCount)) & outputMask) != 0
        {
            throw AddressError.invalidPadding
        }
        return result
    }
}
