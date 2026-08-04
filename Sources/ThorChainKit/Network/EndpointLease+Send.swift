import Foundation

enum SendEndpointRole: String, Sendable { case rest, rpc }

enum SendRequestEncoding: String, Sendable { case jsonREST, protobufABCI }
enum SendResponseDecoder: String, Sendable { case accountQueryAny, network, mimir }

enum SendCapabilityStatus: String, Sendable, Equatable { case pass, fail, unrun }

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
    let capabilityStatus: SendCapabilityStatus

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
        queryParameterValue: String? = nil,
        capabilityStatus: SendCapabilityStatus
    ) {
        self.record = record; self.route = route; self.path = path; self.requestEncoding = requestEncoding; self.decoder = decoder
        self.proofMode = proofMode; self.schemaRevision = schemaRevision; self.supportedNodeRevision = supportedNodeRevision
        self.historicalHeightParameter = historicalHeightParameter; self.queryKey = queryKey
        self.queryParameterName = queryParameterName; self.queryParameterValue = queryParameterValue; self.capabilityStatus = capabilityStatus
    }
}

struct SendFamilyCapability: Equatable, Sendable {
    let familyID: String
    let manifestRevision: String
    let routes: [SendManifestRoute]
    var status: SendCapabilityStatus {
        guard routes.count == 4 else { return .unrun }
        if routes.contains(where: { $0.capabilityStatus == .fail }) { return .fail }
        return routes.allSatisfy { $0.capabilityStatus == .pass } ? .pass : .unrun
    }
    var isSendCapable: Bool { status == .pass }
}

enum NativeRuneEndpointRegistry {
    static let familyIDs = ["rorcual-mainnet", "ibs-mainnet", "keplr-mainnet"]

    static func families() throws -> [EndpointFamilyDescriptor] {
        try [
            EndpointFamilyDescriptor(id: "rorcual-mainnet", cosmosRestURL: URL(string: "https://api-thorchain.rorcual.xyz/")!, cometBftURL: URL(string: "https://rpc-thorchain.rorcual.xyz/")!),
            EndpointFamilyDescriptor(id: "ibs-mainnet", cosmosRestURL: URL(string: "https://thorchain.ibs.team/api")!, cometBftURL: URL(string: "https://thorchain.ibs.team/rpc")!),
            EndpointFamilyDescriptor(id: "keplr-mainnet", cosmosRestURL: URL(string: "https://lcd-thorchain.keplr.app/")!, cometBftURL: URL(string: "https://rpc-thorchain.keplr.app/")!)
        ]
    }

    static func records() -> [SendManifestRecord] {
        [
            .init(familyID: "rorcual-mainnet", role: .rest, scheme: "https", host: "api-thorchain.rorcual.xyz", port: 443, path: "/"),
            .init(familyID: "rorcual-mainnet", role: .rpc, scheme: "https", host: "rpc-thorchain.rorcual.xyz", port: 443, path: "/"),
            .init(familyID: "ibs-mainnet", role: .rest, scheme: "https", host: "thorchain.ibs.team", port: 443, path: "/api"),
            .init(familyID: "ibs-mainnet", role: .rpc, scheme: "https", host: "thorchain.ibs.team", port: 443, path: "/rpc"),
            .init(familyID: "keplr-mainnet", role: .rest, scheme: "https", host: "lcd-thorchain.keplr.app", port: 443, path: "/"),
            .init(familyID: "keplr-mainnet", role: .rpc, scheme: "https", host: "rpc-thorchain.keplr.app", port: 443, path: "/")
        ]
    }

    static func capabilities() -> [SendFamilyCapability] {
        familyIDs.map { familyID in
            let familyRecords = records().filter { $0.familyID == familyID }
            let definitions: [(String, String, SendRequestEncoding, SendResponseDecoder, HeightProofMode, SendEndpointRole, String?, String?, String?, String?)] = [
                ("account", "/cosmos.auth.v1beta1.Query/Account", .protobufABCI, .accountQueryAny, .cometABCI, .rpc, nil, nil, nil, nil),
                ("network-fee", "/types.Query/Network", .protobufABCI, .network, .cometABCI, .rpc, nil, nil, nil, nil),
                // The node returns every mimir key in one response; reading four keys
                // one at a time cost four requests for the same data.
                ("mimir", "/thorchain/mimir", .jsonREST, .mimir, .restHeader, .rest, "height", nil, nil, nil),
                ("recipient-account", "/cosmos.auth.v1beta1.Query/Account", .protobufABCI, .accountQueryAny, .cometABCI, .rpc, nil, nil, nil, nil)
            ]
            let routes = definitions.map { name, path, encoding, decoder, proofMode, role, historicalHeightParameter, queryKey, queryParameterName, queryParameterValue in
                let record = familyRecords.first { $0.role == role }!
                return SendManifestRoute(record: record, route: name, path: path, requestEncoding: encoding, decoder: decoder, proofMode: proofMode, schemaRevision: "s2-02-v2", historicalHeightParameter: historicalHeightParameter, queryKey: queryKey, queryParameterName: queryParameterName, queryParameterValue: queryParameterValue, capabilityStatus: .unrun)
            }
            return SendFamilyCapability(familyID: familyID, manifestRevision: "s2-03-manifest-v2", routes: routes)
        }
    }

    static func matches(_ route: SendManifestRoute, family: EndpointFamilyDescriptor) -> Bool {
        guard let expected = capabilities().first(where: { $0.familyID == family.id })?.routes.first(where: { $0.route == route.route }) else { return false }
        let endpoint = expected.record.role == .rest ? family.cosmosRestURL : family.cometBftURL
        let record = SendManifestRecord(familyID: family.id, role: expected.record.role, scheme: endpoint.scheme?.lowercased() ?? "", host: endpoint.host?.lowercased() ?? "", port: endpoint.port ?? (endpoint.scheme?.lowercased() == "http" ? 80 : 443), path: endpoint.path.isEmpty ? "/" : endpoint.path)
        return route.record == record
            && route.path == expected.path
            && route.requestEncoding == expected.requestEncoding
            && route.decoder == expected.decoder
            && route.proofMode == expected.proofMode
            && route.schemaRevision == expected.schemaRevision
            && route.supportedNodeRevision == expected.supportedNodeRevision
            && route.historicalHeightParameter == expected.historicalHeightParameter
            && route.queryKey == expected.queryKey
            && route.queryParameterName == expected.queryParameterName
            && route.queryParameterValue == expected.queryParameterValue
    }

    static func validate(_ families: [EndpointFamilyDescriptor]) -> Bool {
        let actual = families.flatMap { family in
            [record(family: family, role: .rest, url: family.cosmosRestURL), record(family: family, role: .rpc, url: family.cometBftURL)]
        }
        return actual == records()
    }

    private static func record(family: EndpointFamilyDescriptor, role: SendEndpointRole, url: URL) -> SendManifestRecord {
        .init(familyID: family.id, role: role, scheme: url.scheme?.lowercased() ?? "", host: url.host?.lowercased() ?? "", port: url.port ?? (url.scheme?.lowercased() == "http" ? 80 : 443), path: url.path.isEmpty ? "/" : url.path)
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
