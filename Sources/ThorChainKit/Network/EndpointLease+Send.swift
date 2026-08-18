import Foundation

enum SendEndpointRole: String, Sendable { case rest, rpc }

enum SendRequestEncoding: String, Sendable { case jsonREST, protobufABCI }
enum SendResponseDecoder: String, Sendable { case accountQueryAny, network, mimir, constants }

struct SendManifestRecord: Equatable, Sendable {
    let familyID: String
    let role: SendEndpointRole
    let scheme: String
    let host: String
    let port: Int
    let path: String
}

struct SendManifestRoute: Equatable, Sendable {
    let record: SendManifestRecord
    let route: String
    let path: String
    let requestEncoding: SendRequestEncoding
    let decoder: SendResponseDecoder
    let proofMode: HeightProofMode
    let schemaRevision: String
    let supportedNodeRevision: String
    let historicalHeightParameter: String?
    let queryKey: String?
    let queryParameterName: String?
    let queryParameterValue: String?

    init(
        record: SendManifestRecord,
        route: String,
        path: String = "",
        requestEncoding: SendRequestEncoding = .jsonREST,
        decoder: SendResponseDecoder = .accountQueryAny,
        proofMode: HeightProofMode,
        schemaRevision: String,
        supportedNodeRevision: String = "3.19.0..3.19.3",
        historicalHeightParameter: String? = nil,
        queryKey: String? = nil,
        queryParameterName: String? = nil,
        queryParameterValue: String? = nil
    ) {
        self.record = record; self.route = route; self.path = path; self.requestEncoding = requestEncoding; self.decoder = decoder
        self.proofMode = proofMode; self.schemaRevision = schemaRevision; self.supportedNodeRevision = supportedNodeRevision
        self.historicalHeightParameter = historicalHeightParameter; self.queryKey = queryKey
        self.queryParameterName = queryParameterName; self.queryParameterValue = queryParameterValue
    }
}

// Send request shapes per chain. Routes are a property of the chain's node software, not
// of any particular provider: the app supplies the endpoints (its own hardcoded list, the
// pool verifies their chain identity), and the kit builds every preflight request from
// this table. Nothing here validates the app's configuration.
struct SendRouteTemplate: Equatable, Sendable {
    let route: String
    let path: String
    let requestEncoding: SendRequestEncoding
    let decoder: SendResponseDecoder
    let proofMode: HeightProofMode
    let role: SendEndpointRole
    let historicalHeightParameter: String?
}

enum SendRoutes {
    static func manifestRevision(chain: Network.Chain) -> String {
        switch chain {
        case .thor: return "s2-03-manifest-v3"
        case .maya: return "maya-manifest-v1"
        }
    }

    static func schemaRevision(chain: Network.Chain) -> String {
        switch chain {
        case .thor: return "s2-02-v2"
        case .maya: return "maya-s1-v1"
        }
    }

    static func nodeRevision(chain: Network.Chain) -> String {
        switch chain {
        case .thor: return "3.19.0..3.19.3"
        case .maya: return "mayanode-1.132"
        }
    }

    static func templates(chain: Network.Chain) -> [SendRouteTemplate] {
        switch chain {
        case .thor:
            return [
                SendRouteTemplate(route: "account", path: "/cosmos.auth.v1beta1.Query/Account", requestEncoding: .protobufABCI, decoder: .accountQueryAny, proofMode: .cometABCI, role: .rpc, historicalHeightParameter: nil),
                SendRouteTemplate(route: "network-fee", path: "/types.Query/Network", requestEncoding: .protobufABCI, decoder: .network, proofMode: .cometABCI, role: .rpc, historicalHeightParameter: nil),
                // The node returns every mimir key in one response; reading four keys
                // one at a time cost four requests for the same data.
                SendRouteTemplate(route: "mimir", path: "/thorchain/mimir", requestEncoding: .jsonREST, decoder: .mimir, proofMode: .restHeader, role: .rest, historicalHeightParameter: "height"),
                SendRouteTemplate(route: "recipient-account", path: "/cosmos.auth.v1beta1.Query/Account", requestEncoding: .protobufABCI, decoder: .accountQueryAny, proofMode: .cometABCI, role: .rpc, historicalHeightParameter: nil),
            ]
        case .maya:
            // Account reads share the Cosmos ABCI surface with THOR; the fee comes from
            // REST `constants` because mayanode serves no `/types.Query/Network` (verified
            // live 2026-08-17), matching thorchain-kit-android. Neither REST route declares
            // a historical `height` query parameter — mayanode ignores it; height pinning
            // rides the x-cosmos-block-height header instead.
            let protocolPath = Network.Chain.maya.protocolPath
            return [
                SendRouteTemplate(route: "account", path: "/cosmos.auth.v1beta1.Query/Account", requestEncoding: .protobufABCI, decoder: .accountQueryAny, proofMode: .cometABCI, role: .rpc, historicalHeightParameter: nil),
                SendRouteTemplate(route: "network-fee", path: "/\(protocolPath)/constants", requestEncoding: .jsonREST, decoder: .constants, proofMode: .restHeader, role: .rest, historicalHeightParameter: nil),
                SendRouteTemplate(route: "mimir", path: "/\(protocolPath)/mimir", requestEncoding: .jsonREST, decoder: .mimir, proofMode: .restHeader, role: .rest, historicalHeightParameter: nil),
                SendRouteTemplate(route: "recipient-account", path: "/cosmos.auth.v1beta1.Query/Account", requestEncoding: .protobufABCI, decoder: .accountQueryAny, proofMode: .cometABCI, role: .rpc, historicalHeightParameter: nil),
            ]
        }
    }

    static func route(_ name: String, family: EndpointFamilyDescriptor, chain: Network.Chain) throws -> SendManifestRoute {
        guard let template = templates(chain: chain).first(where: { $0.route == name }) else { throw SendError.policyUnavailable }
        let endpoint = template.role == .rest ? family.cosmosRestURL : family.cometBftURL
        let record = SendManifestRecord(
            familyID: family.id,
            role: template.role,
            scheme: endpoint.scheme?.lowercased() ?? "",
            host: endpoint.host?.lowercased() ?? "",
            port: endpoint.port ?? (endpoint.scheme?.lowercased() == "http" ? 80 : 443),
            path: endpoint.path.isEmpty ? "/" : endpoint.path
        )
        return SendManifestRoute(
            record: record,
            route: template.route,
            path: template.path,
            requestEncoding: template.requestEncoding,
            decoder: template.decoder,
            proofMode: template.proofMode,
            schemaRevision: schemaRevision(chain: chain),
            supportedNodeRevision: nodeRevision(chain: chain),
            historicalHeightParameter: template.historicalHeightParameter
        )
    }
}

extension EndpointLease {
    var sendFamilyID: String { family.id }
    var commonReadHeight: Int64 { min(cosmosReadHeight, cometReferenceHeight) }
}

enum HeightProofMode: String, Equatable, Sendable { case restHeader, cometABCI, bodyHeight }

enum HeightProof: Equatable, Sendable {
    case restHeader(expected: Int64, actual: Int64?)
    case cometABCI(expected: Int64, actual: Int64?)
    case body(expected: Int64, actual: Int64?)

    var isExact: Bool {
        switch self {
        case let .restHeader(expected, actual), let .cometABCI(expected, actual), let .body(expected, actual): actual == expected && expected > 0
        }
    }
}

enum HeightProofValidator {
    static func validate(mode: HeightProofMode, expected: Int64, headerHeight: Int64? = nil, responseHeight: Int64? = nil, bodyHeight: Int64? = nil) -> HeightProof {
        switch mode {
        case .restHeader: return .restHeader(expected: expected, actual: headerHeight)
        case .cometABCI: return .cometABCI(expected: expected, actual: responseHeight)
        case .bodyHeight: return .body(expected: expected, actual: bodyHeight)
        }
    }
}
