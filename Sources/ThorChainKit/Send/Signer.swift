import Foundation
import HdWalletKit
import HsCryptoKit

/// The seam the send pipeline signs through.
///
/// `Signer` below is the conventional implementation and is what callers use.
/// The protocol exists so the pipeline can be driven by a substitute — an
/// external device, or a test double that cancels, stalls, or returns a
/// mismatched key. Those cases are what the send tests exercise, so this stays
/// a protocol rather than collapsing into the concrete type.
public protocol ISigner: Sendable {
    var compressedPublicKey: Data { get }
    func sign(digest: Data) async throws -> Data
}

public final class Signer: ISigner, @unchecked Sendable {
    public let compressedPublicKey: Data
    private let privateKey: Data

    init(privateKey: Data) throws {
        self.privateKey = privateKey
        compressedPublicKey = Crypto.publicKey(privateKey: privateKey, compressed: true)
    }

    public func sign(digest: Data) async throws -> Data {
        try Self.sign(digest: digest, privateKey: privateKey)
    }
}

public extension Signer {
    static func instance(seed: Data) throws -> Signer {
        try Signer(privateKey: privateKey(seed: seed))
    }

    static func instance(privateKey: Data) throws -> Signer {
        try Signer(privateKey: privateKey)
    }

    static func address(seed: Data, network: Network = .mainnet) throws -> Address {
        try address(privateKey: privateKey(seed: seed), network: network)
    }

    static func address(privateKey: Data, network: Network = .mainnet) throws -> Address {
        try AccountAddressFactory.address(
            compressedPublicKey: Crypto.publicKey(privateKey: privateKey, compressed: true),
            network: network
        )
    }

    static func privateKey(seed: Data) throws -> Data {
        let wallet = HDWallet(
            seed: seed,
            coinType: Network.mainnet.coinType,
            xPrivKey: HDExtendedKeyVersion.xprv.rawValue,
            purpose: .bip44,
            curve: .secp256k1
        )

        return try wallet.privateKey(path: DerivationPath.defaultAccount.rawValue).raw
    }

    static func sign(digest: Data, privateKey: Data) throws -> Data {
        try Crypto.sign(data: digest, privateKey: privateKey, compact: true)
    }
}
