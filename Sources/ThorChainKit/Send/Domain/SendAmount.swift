import BigInt
import Foundation

struct SendMagnitude: Sendable, Hashable {
    let data: Data

    init(_ value: BigUInt) {
        data = value == 0 ? Data() : value.serialize()
    }

    var value: BigUInt { data.isEmpty ? 0 : BigUInt(data) }
}

public struct SendAmount: Sendable {
    private let exactMagnitude: Data

    private init(exactMagnitude: Data) {
        self.exactMagnitude = exactMagnitude
    }

    public static func exact(_ amount: BigUInt) -> SendAmount {
        SendAmount(exactMagnitude: SendMagnitude(amount).data)
    }

    // There is no maximum: resolving one needs a balance, and the balance the caller was
    // showing is the one that must be spent from. The caller subtracts the fee itself,
    // as the Android wallet does on its send screen.
    public var exactAmount: BigUInt? {
        exactMagnitude.isEmpty ? 0 : BigUInt(exactMagnitude)
    }
}
