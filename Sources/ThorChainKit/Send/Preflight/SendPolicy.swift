import Foundation
import CryptoKit
import BigInt

struct SendPolicy: Equatable, Sendable {
    let memoMaximumBytes: Int
    let revision: String

    static let standard = SendPolicy(uncheckedMemoMaximumBytes: 256, revision: "s2-02-v1")

    init(memoMaximumBytes: Int = 256, revision: String = "s2-02-v1") throws {
        guard memoMaximumBytes > 0, !revision.isEmpty else {
            throw SendError.policyUnavailable
        }
        self.memoMaximumBytes = memoMaximumBytes
        self.revision = revision
    }

    private init(uncheckedMemoMaximumBytes: Int, revision: String) {
        memoMaximumBytes = uncheckedMemoMaximumBytes; self.revision = revision
    }

    func validate(memo: String?, maximumBytes: Int? = nil) throws {
        let maximumBytes = maximumBytes ?? memoMaximumBytes
        guard maximumBytes > 0 else { throw SendError.providerUnavailable }
        guard let memo else { return }
        guard memo.utf8.count <= maximumBytes else {
            throw SendError.memoTooLong(maxUTF8Bytes: maximumBytes)
        }
    }

    /// The balance is not read here. It is the one the user was looking at when they
    /// chose the amount, and a second read moments later disagrees with the screen —
    /// which is how a send the wallet had shown as affordable failed after Face ID. The
    /// chain rejects a send it cannot cover, and the Android kit relies on exactly that.
    func resolve(amount: SendAmount) throws -> BigUInt {
        guard let exact = amount.exactAmount, exact > 0 else { throw SendError.invalidAmount }
        return exact
    }
}

struct MimirSnapshot: Equatable, Hashable, Sendable {
    let haltChainGlobal: Int64
    let nodePauseChainGlobal: Int64
    let haltTHORChain: Int64
    let solvencyHaltTHORChain: Int64
}

enum HaltDecision: Equatable, Sendable {
    case allowed
    case halted

    var isHalted: Bool { self == .halted }
}

enum HaltEvaluator {
    static func evaluate(height: Int64, mimir: MimirSnapshot) throws -> HaltDecision {
        guard height > 0,
              [mimir.haltChainGlobal, mimir.nodePauseChainGlobal, mimir.haltTHORChain, mimir.solvencyHaltTHORChain]
                .allSatisfy({ $0 >= -1 })
        else { throw SendError.policyUnavailable }

        let halted = (mimir.haltChainGlobal > 0 && mimir.haltChainGlobal <= height)
            || (mimir.nodePauseChainGlobal > 0 && mimir.nodePauseChainGlobal >= height)
            || (mimir.haltTHORChain > 0 && mimir.haltTHORChain <= height)
            || (mimir.solvencyHaltTHORChain > 0 && mimir.solvencyHaltTHORChain <= height)
        return halted ? .halted : .allowed
    }
}

struct ForbiddenModuleAddressSet: Sendable, Equatable {
    static let sourceTags = ["v3.19.0@5f2141c3", "v3.19.1@59a3e925", "v3.19.2@c6fa8caa", "v3.19.3@52e66ad9"]
    static let sourceFileSHA256 = "72ce4607cfcd45e1546e9c12d79afaeeb897946d0c9f3df31c14b8e05a3a98cf"
    static let pinnedModuleVectors: [(String, String)] = [
        ("asgard", "thor1g98cy3n9mmjrpn0sxmn63lztelera37n8n67c0"),
        ("bond", "thor17gw75axcnr8747pkanye45pnrwk7p9c3cqncsv"),
        ("reserve", "thor1dheycdevq39qlkxs2a6wuuzyn4aqxhve4qxtxt"),
        ("lending", "thor1x0kgm82cnj0vtmzdvz4avk3e7sj427t0egk70p"),
        ("affiliate_collector", "thor1dl7un46w7l7f3ewrnrm6nq58nerjtp0dradjtd"),
        ("thorchain", "thor1v8ppstuf6e3x0r4glqc68d5jqcs2tf38cg2q6y"),
        ("tcy_claim", "thor1ss8rrf3twa20kf9frdyru05dmu2kg9ll2efcyd"),
        ("tcy_stake", "thor128a8hqnkaxyqv7qwajpggmfyudh64jl3c32vyv"),
        ("treasury", "thor1vmafl8f3s6uuzwnxkqz0eza47v6ecn0t086r2p")
    ]
    let revision = "thorchain-3.19-module-addresses-v1"
    private let addresses: Set<String>

    init(network: Network = .mainnet) throws {
        let names = Self.pinnedModuleVectors.map { $0.0 }
        var values = Set<String>()
        for name in names {
            let digest = SHA256.hash(data: Data(name.utf8))
            let words = try BitConversion.convert(Array(digest.prefix(20)), fromBits: 8, toBits: 5, pad: true)
            values.insert(Bech32Codec.encode(hrp: network.accountHrp, words: words))
        }
        addresses = values
    }

    func contains(_ address: String) -> Bool { addresses.contains(address.lowercased()) }
}
