import Combine
import Foundation
import ThorChainKit

@MainActor
final class AddressViewModel: ObservableObject {
    @Published private(set) var derivedAddress = "unavailable"
    @Published private(set) var canonicalUppercase = "unavailable"
    @Published private(set) var mixedCaseResult = "unavailable"
    @Published private(set) var badChecksumResult = "unavailable"
    @Published private(set) var wrongHrpResult = "unavailable"

    init(network: Network) {
        let publicKey = Data([
            0x02, 0xA9, 0xAC, 0x9F, 0x7A, 0x97, 0xDA, 0x41, 0x55, 0x9E, 0x16,
            0x84, 0x01, 0x1B, 0x6A, 0x9B, 0x0B, 0x9C, 0x04, 0x45, 0x29, 0x7D,
            0x5F, 0x51, 0xDE, 0xA0, 0x89, 0x7F, 0xD4, 0xA3, 0x9C, 0x31, 0xC7,
        ])
        do {
            let address = try AccountAddressFactory.address(
                compressedPublicKey: publicKey,
                network: network
            )
            let codec = AddressCodec()
            derivedAddress = address.raw
            canonicalUppercase = try codec.decode(address.raw.uppercased(), network: network).raw
            mixedCaseResult = Self.failureName {
                try codec.decode(
                    address.raw.prefix(6).uppercased() + String(address.raw.dropFirst(6)),
                    network: network
                )
            }
            badChecksumResult = Self.failureName {
                try codec.decode(address.raw.dropLast() + "q", network: network)
            }
            let stagenet = try Network.stagenet(expectedChainId: "stage-1")
            let wrongNetworkAddress = try codec.encode(payload: Data(repeating: 0, count: 20), network: stagenet)
            wrongHrpResult = Self.failureName {
                try codec.decode(wrongNetworkAddress.raw, network: network)
            }
        } catch {
            derivedAddress = "unavailable"
        }
    }

    private static func failureName(_ operation: () throws -> Address) -> String {
        do {
            _ = try operation()
            return "accepted"
        } catch let error as AddressError {
            switch error {
            case .mixedCase: return "mixedCase"
            case .wrongHrp: return "wrongHrp"
            default: return "invalidAddress"
            }
        } catch {
            return "invalidAddress"
        }
    }
}
