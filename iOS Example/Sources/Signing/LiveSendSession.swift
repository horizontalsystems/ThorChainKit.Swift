import Foundation
import LiveSupport
import ThorChainKit
#if canImport(CryptoKit)
    import CryptoKit
#endif
#if canImport(HdWalletKit)
    import HdWalletKit
#endif
#if canImport(HsCryptoKit)
    import HsCryptoKit
#endif

public final class LiveSigner: Signer, @unchecked Sendable {
    public let compressedPublicKey: Data
    private let privateKey: Data

    public init(privateKey: Data, compressedPublicKey: Data) {
        self.privateKey = privateKey
        self.compressedPublicKey = compressedPublicKey
    }

    public func sign(_ request: SigningRequest) async throws -> Data {
        #if canImport(HsCryptoKit)
            try Crypto.ellipticSign(request.digest, privateKey: privateKey)
        #else
            throw LiveSecretError.unavailable
        #endif
    }
}

public struct LiveSendSession {
    public let kit: Kit
    public let signer: LiveSigner
    public let address: Address
    public let recipient: Address

    public init(secretURL: URL, endpoints: EndpointConfiguration) throws {
        #if canImport(HdWalletKit) && canImport(HsCryptoKit)
            let secret = try LiveSecretLoader().load(from: secretURL)
            guard (try? Mnemonic.validate(words: secret.words)) != nil else {
                throw LiveSecretError.malformed
            }
            let recipient = try Address(secret.recipient, network: .mainnet)
            guard let seed = Mnemonic.seed(mnemonic: secret.words, passphrase: "", iterations: 2048) else {
                throw LiveSecretError.malformed
            }
            let wallet = HDWallet(seed: seed, coinType: 931, xPrivKey: 0x0488_ADE4, purpose: .bip44, curve: .secp256k1)
            let privateKey = try wallet.privateKey(account: 0, index: 0, chain: .external)
            let publicKey = privateKey.publicKey(compressed: true).raw
            let payload = Crypto.ripeMd160Sha256(publicKey)
            let address = try AddressCodec().encode(payload: payload, network: .mainnet)
            let walletID = "thor-example/live/" + SHA256.hex(publicKey)
            let signer = LiveSigner(privateKey: privateKey.raw, compressedPublicKey: publicKey)
            let kit = try Kit.instance(address: address, walletId: walletID, endpoints: endpoints)
            self.address = address
            self.recipient = recipient
            self.signer = signer
            self.kit = kit
        #else
            _ = secretURL
            _ = endpoints
            throw LiveSecretError.unavailable
        #endif
    }
}

private extension SHA256 {
    static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
