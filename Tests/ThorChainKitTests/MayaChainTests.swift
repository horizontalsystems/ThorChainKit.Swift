import BigInt
import Foundation
@testable import ThorChainKit
import XCTest

final class MayaChainTests: XCTestCase {
    func testMayaMainnetNetworkConstants() {
        let network = Network.mayaMainnet

        XCTAssertEqual(network.environment, .mainnet)
        XCTAssertEqual(network.expectedChainId, "mayachain-mainnet-v1")
        XCTAssertEqual(network.accountHrp, "maya")
        XCTAssertEqual(network.coinType, 931)
        XCTAssertEqual(network.chain, .maya)
        XCTAssertEqual(network.nativeDenom, .cacao)
        XCTAssertEqual(network.decimals, 10)
        XCTAssertEqual(network.protocolPath, "mayachain")
        XCTAssertEqual(network.chain.assetChainTag, "MAYA")
        XCTAssertNotEqual(network.persistenceKey, Network.mainnet.persistenceKey)
    }

    // Parity with thorchain-kit-android MayaAssetResolver: the irregular native map,
    // the plain-denom rule (no Rujira x/ namespace on Maya), and the shared delimiter grammar.
    func testMayaAssetResolver() throws {
        XCTAssertEqual(try Network.Chain.maya.asset(for: "cacao"), .cacao)
        XCTAssertEqual(try Network.Chain.maya.asset(for: "maya"), Asset(chain: "MAYA", symbol: "MAYA", ticker: "MAYA"))
        XCTAssertEqual(try Network.Chain.maya.asset(for: "guru"), Asset(chain: "MAYA", symbol: "GURU", ticker: "GURU"))

        let synth = try Network.Chain.maya.asset(for: "btc/btc")
        XCTAssertTrue(synth.synth)
        XCTAssertEqual(synth.chain, "BTC")

        XCTAssertEqual(Network.Chain.maya.denom(for: .cacao), "cacao")
        XCTAssertEqual(Network.Chain.maya.denom(for: Asset(chain: "MAYA", symbol: "MAYA", ticker: "MAYA")), "maya")
        XCTAssertEqual(try Network.Chain.maya.denom(for: Asset(notation: "ARB-ETH")), "arb-eth")
    }

    func testThorChainResolverIsUnchangedByDispatch() throws {
        XCTAssertEqual(try Network.Chain.thor.asset(for: "rune"), .rune)
        XCTAssertEqual(try Network.Chain.thor.asset(for: "x/ruji"), Asset(chain: "THOR", symbol: "RUJI", ticker: "RUJI"))
        XCTAssertEqual(Network.Chain.thor.denom(for: .rune), "rune")
    }

    // The pinned vectors are the verification record (mayanode isModuleAccAddressV127,
    // checked against mainnet 2026-08-17); the init re-derives every address from the
    // module name and the network hrp and must agree with them.
    func testForbiddenModuleAddressesDeriveForBothChains() throws {
        let thor = try ForbiddenModuleAddressSet(network: .mainnet)
        XCTAssertEqual(thor.revision, "thorchain-3.19-module-addresses-v1")
        XCTAssertTrue(thor.contains("thor1g98cy3n9mmjrpn0sxmn63lztelera37n8n67c0"))
        XCTAssertFalse(thor.contains("maya1g98cy3n9mmjrpn0sxmn63lztelera37n8yyjwl"))

        let maya = try ForbiddenModuleAddressSet(network: .mayaMainnet)
        XCTAssertEqual(maya.revision, "mayachain-1.132-module-addresses-v1")
        for (_, address) in ForbiddenModuleAddressSet.mayaPinnedModuleVectors {
            XCTAssertTrue(maya.contains(address))
        }
        XCTAssertFalse(maya.contains("thor1g98cy3n9mmjrpn0sxmn63lztelera37n8n67c0"))
        // A user address must never match
        XCTAssertFalse(maya.contains("maya10sy79jhw9hw9sqwdgu0k4mw4qawzl7czewzs47"))
    }

    func testConstantsNativeFeeDecoder() throws {
        let data = Data(#"{"int_64_values":{"NativeTransactionFee":2000000000,"BlocksPerYear":5256000},"string_values":{}}"#.utf8)
        let fee = try SendRouteDecoders.constantsNativeFee(data)
        XCTAssertEqual(fee, BigUInt(2_000_000_000))

        XCTAssertThrowsError(try SendRouteDecoders.constantsNativeFee(Data(#"{"int_64_values":{}}"#.utf8)))
        // Zero is a legitimate fee — it must agree with the mimir-override semantics
        let zero = try SendRouteDecoders.constantsNativeFee(Data(#"{"int_64_values":{"NativeTransactionFee":0}}"#.utf8))
        XCTAssertEqual(zero, BigUInt(0))
        XCTAssertThrowsError(try SendRouteDecoders.constantsNativeFee(Data(#"{"int_64_values":{"NativeTransactionFee":-1}}"#.utf8)))
    }

    // GetConfigInt64 semantics: a non-negative mimir NATIVETRANSACTIONFEE overrides the
    // constant; -1 or absence falls back.
    func testNativeFeeMimirOverride() {
        XCTAssertEqual(ThorNodeSendPreflightProvider.nativeFee(constantsFee: 100, mimirValues: [:]), 100)
        XCTAssertEqual(ThorNodeSendPreflightProvider.nativeFee(constantsFee: 100, mimirValues: ["NATIVETRANSACTIONFEE": -1]), 100)
        XCTAssertEqual(ThorNodeSendPreflightProvider.nativeFee(constantsFee: 100, mimirValues: ["NATIVETRANSACTIONFEE": 0]), 0)
        XCTAssertEqual(ThorNodeSendPreflightProvider.nativeFee(constantsFee: 100, mimirValues: ["NATIVETRANSACTIONFEE": 2_500_000_000]), BigUInt(2_500_000_000))
    }

    func testMayaRegistryRoutes() {
        let capabilities = NativeCacaoEndpointRegistry.capabilities()
        XCTAssertEqual(capabilities.count, 1)
        let capability = capabilities[0]
        XCTAssertEqual(capability.familyID, "mayanode-mainnet")
        XCTAssertEqual(capability.routes.map(\.route), ["account", "network-fee", "mimir", "recipient-account"])

        let fee = capability.routes.first { $0.route == "network-fee" }
        XCTAssertEqual(fee?.path, "/mayachain/constants")
        XCTAssertEqual(fee?.requestEncoding, .jsonREST)
        // mayanode ignores a historical ?height= query; the pin rides the header
        XCTAssertNil(fee?.historicalHeightParameter)

        let mimir = capability.routes.first { $0.route == "mimir" }
        XCTAssertEqual(mimir?.path, "/mayachain/mimir")
        XCTAssertNil(mimir?.historicalHeightParameter)

        let account = capability.routes.first { $0.route == "account" }
        XCTAssertEqual(account?.path, "/cosmos.auth.v1beta1.Query/Account")
        XCTAssertEqual(account?.requestEncoding, .protobufABCI)
    }

    // On Maya the THOR halt keys describe THORChain as an observed external L1; the
    // native pair is keyed by the chain tag. A THOR-halt on Maya must not gate CACAO.
    func testNativeHaltKeysAreChainTagged() {
        XCTAssertEqual("Halt\(Network.Chain.thor.assetChainTag)Chain".uppercased(), "HALTTHORCHAIN")
        XCTAssertEqual("Halt\(Network.Chain.maya.assetChainTag)Chain".uppercased(), "HALTMAYACHAIN")
        XCTAssertEqual("SolvencyHalt\(Network.Chain.maya.assetChainTag)Chain".uppercased(), "SOLVENCYHALTMAYACHAIN")
    }

    func testQuoteDenomDefaultIsNativePerNetwork() {
        // The compile-time contract: SendQuoteRequest carries whatever the kit passes,
        // and Kit.quote derives nil into network.nativeDenom. Guard the mapping here.
        XCTAssertEqual(Network.mainnet.nativeDenom, .rune)
        XCTAssertEqual(Network.mayaMainnet.nativeDenom, .cacao)
        XCTAssertEqual(Network.mayaMainnet.chain.nativeAsset, .cacao)
    }
}
