import Foundation

struct LiveNodeProbe: INodeProber {
    private let transport: any IHttpTransport
    private let requestTimeout: TimeInterval
    private let clientId: String?

    init(
        transport: any IHttpTransport = URLSessionTransport(),
        requestTimeout: TimeInterval = 15,
        clientId: String? = nil
    ) {
        self.transport = transport
        self.requestTimeout = requestTimeout
        self.clientId = clientId
    }

    init(configuration: EndpointConfiguration, transport: any IHttpTransport = URLSessionTransport()) {
        self.init(
            transport: transport,
            requestTimeout: configuration.requestTimeout,
            clientId: configuration.clientId
        )
    }

    func probe(index: Int, family: EndpointFamilyDescriptor) async -> [IndexedProbeOutcome] {
        await withTaskGroup(of: IndexedProbeOutcome.self) { group in
            for request in ProbeRequestKind.allCases {
                group.addTask {
                    await outcome(index: index, family: family, request: request)
                }
            }
            var outcomes = [IndexedProbeOutcome]()
            for await outcome in group {
                outcomes.append(outcome)
            }
            return outcomes.sorted { $0.index.request.rawValue < $1.index.request.rawValue }
        }
    }

    func latestBlock(family: EndpointFamilyDescriptor) async -> Result<CosmosLatestBlockObservation, RoleProbeFailure> {
        let outcome = await outcome(index: 0, family: family, request: .cosmosLatestBlock)
        guard case let .cosmosLatestBlock(result) = outcome.result else {
            return .failure(.invalidResponse(field: .blockHeaderHeight))
        }
        return result
    }

    private func outcome(
        index: Int,
        family: EndpointFamilyDescriptor,
        request: ProbeRequestKind
    ) async -> IndexedProbeOutcome {
        let role: EndpointRole = request == .cometStatus ? .cometBft : .cosmosRest
        let baseURL = role == .cometBft ? family.cometBftURL : family.cosmosRestURL
        let cosmosOrigin = EndpointOrigin(url: family.cosmosRestURL)!
        let cometOrigin = EndpointOrigin(url: family.cometBftURL)!
        let result: ProbeRequestResult

        do {
            let urlRequest = RequestBuilder(
                baseURL: baseURL,
                requestTimeout: requestTimeout,
                clientId: clientId
            ).request(path: request.path.split(separator: "/").map(String.init))
            let (data, response) = try await transport.data(for: urlRequest)
            guard (200 ..< 300).contains(response.statusCode) else {
                let failure = RoleProbeFailure.httpStatus(
                    code: response.statusCode,
                    retryAfterSeconds: response.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
                )
                return indexed(
                    familyIndex: index,
                    family: family,
                    request: request,
                    cosmosOrigin: cosmosOrigin,
                    cometOrigin: cometOrigin,
                    result: request.failure(failure)
                )
            }
            result = decode(data, request: request)
        } catch is CancellationError {
            result = request.failure(.cancelled)
        } catch let error as URLError where error.code == .cancelled {
            result = request.failure(.cancelled)
        } catch let error as URLError {
            result = request.failure(.transport(kind: transportKind(error.code)))
        } catch {
            result = request.failure(.transport(kind: .other))
        }

        return indexed(
            familyIndex: index,
            family: family,
            request: request,
            cosmosOrigin: cosmosOrigin,
            cometOrigin: cometOrigin,
            result: result
        )
    }

    private func indexed(
        familyIndex: Int,
        family: EndpointFamilyDescriptor,
        request: ProbeRequestKind,
        cosmosOrigin: EndpointOrigin,
        cometOrigin: EndpointOrigin,
        result: ProbeRequestResult
    ) -> IndexedProbeOutcome {
        IndexedProbeOutcome(
            index: ProbeRequestIndex(
                familyIndex: familyIndex,
                familyId: family.id,
                role: request == .cometStatus ? .cometBft : .cosmosRest,
                request: request
            ),
            cosmosOrigin: cosmosOrigin,
            cometOrigin: cometOrigin,
            result: result
        )
    }

    private func decode(_ data: Data, request: ProbeRequestKind) -> ProbeRequestResult {
        let decoder = JSONDecoder()
        switch request {
        case .cosmosNodeInfo:
            guard let envelope = try? decoder.decode(NodeInfoEnvelope.self, from: data),
                  let chainId = envelope.defaultNodeInfo?.network,
                  !chainId.isEmpty
            else {
                return request.failure(.invalidResponse(field: .nodeInfoNetwork))
            }
            return .cosmosNodeInfo(.success(.init(chainId: chainId)))
        case .cosmosLatestBlock:
            guard let envelope = try? decoder.decode(LatestBlockEnvelope.self, from: data),
                  let chainId = envelope.block?.header?.chainId,
                  !chainId.isEmpty
            else {
                return request.failure(.invalidResponse(field: .blockHeaderChainId))
            }
            guard let rawHeight = envelope.block?.header?.height,
                  let height = Int64(rawHeight)
            else {
                return request.failure(.invalidResponse(field: .blockHeaderHeight))
            }
            return .cosmosLatestBlock(.success(.init(chainId: chainId, latestHeight: height)))
        case .cometStatus:
            guard let envelope = try? decoder.decode(CometStatusEnvelope.self, from: data),
                  let chainId = envelope.result?.nodeInfo?.network,
                  !chainId.isEmpty
            else {
                return request.failure(.invalidResponse(field: .cometNetwork))
            }
            guard let rawHeight = envelope.result?.syncInfo?.latestBlockHeight,
                  let height = Int64(rawHeight)
            else {
                return request.failure(.invalidResponse(field: .cometHeight))
            }
            guard let catchingUp = envelope.result?.syncInfo?.catchingUp else {
                return request.failure(.invalidResponse(field: .cometCatchingUp))
            }
            return .cometStatus(.success(.init(
                chainId: chainId,
                latestHeight: height,
                catchingUp: catchingUp
            )))
        }
    }

    private func transportKind(_ code: URLError.Code) -> TransportFailureKind {
        switch code {
        case .cannotFindHost, .dnsLookupFailed: .dns
        case .cannotConnectToHost, .networkConnectionLost: .connection
        case .timedOut: .timeout
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .clientCertificateRejected: .tls
        case .notConnectedToInternet: .offline
        default: .other
        }
    }
}

private extension ProbeRequestKind {
    var path: String {
        switch self {
        case .cosmosNodeInfo: "cosmos/base/tendermint/v1beta1/node_info"
        case .cosmosLatestBlock: "cosmos/base/tendermint/v1beta1/blocks/latest"
        case .cometStatus: "status"
        }
    }

    func failure(_ failure: RoleProbeFailure) -> ProbeRequestResult {
        switch self {
        case .cosmosNodeInfo: .cosmosNodeInfo(.failure(failure))
        case .cosmosLatestBlock: .cosmosLatestBlock(.failure(failure))
        case .cometStatus: .cometStatus(.failure(failure))
        }
    }
}

private struct NodeInfoEnvelope: Decodable {
    struct NodeInfo: Decodable { let network: String? }
    let defaultNodeInfo: NodeInfo?

    enum CodingKeys: String, CodingKey { case defaultNodeInfo = "default_node_info" }
}

private struct LatestBlockEnvelope: Decodable {
    struct Block: Decodable { let header: Header? }
    struct Header: Decodable {
        let chainId: String?
        let height: String?

        enum CodingKeys: String, CodingKey {
            case chainId = "chain_id"
            case height
        }
    }

    let block: Block?
}

private struct CometStatusEnvelope: Decodable {
    struct Result: Decodable {
        struct NodeInfo: Decodable { let network: String? }
        struct SyncInfo: Decodable {
            let latestBlockHeight: String?
            let catchingUp: Bool?

            enum CodingKeys: String, CodingKey {
                case latestBlockHeight = "latest_block_height"
                case catchingUp = "catching_up"
            }
        }

        let nodeInfo: NodeInfo?
        let syncInfo: SyncInfo?

        enum CodingKeys: String, CodingKey {
            case nodeInfo = "node_info"
            case syncInfo = "sync_info"
        }
    }

    let result: Result?
}
