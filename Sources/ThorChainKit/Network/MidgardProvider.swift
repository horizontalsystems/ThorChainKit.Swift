import Foundation

enum MidgardProviderError: Error, Equatable, Sendable {
    case invalidResponse
    case clientStatus(Int)
    case unavailable
}

struct MidgardActionPage: Sendable {
    let actions: [MidgardAction]
    let nextPageToken: String?
}

protocol IHistoryProvider: Sendable {
    func fetchActions(address: String, limit: Int, nextPageToken: String?, transactionID: TransactionID?) async throws -> MidgardActionPage
}

/// THOR-specific historical transport. Unlike a THORNode endpoint family,
/// Midgard only supplies indexed actions and cannot provide a chain-height lease.
struct MidgardProvider: IHistoryProvider, Sendable {
    private let baseURLs: [URL]
    private let requestTimeout: TimeInterval
    private let clientId: String?
    private let transport: any IHttpTransport

    init(
        baseURLs: [URL],
        requestTimeout: TimeInterval,
        clientId: String?,
        transport: any IHttpTransport = URLSessionTransport()
    ) {
        self.baseURLs = baseURLs
        self.requestTimeout = requestTimeout
        self.clientId = clientId
        self.transport = transport
    }

    func fetchActions(address: String, limit: Int = 50, nextPageToken: String? = nil, transactionID: TransactionID? = nil) async throws -> MidgardActionPage {
        guard !address.isEmpty, (1 ... 50).contains(limit), !baseURLs.isEmpty else {
            throw MidgardProviderError.invalidResponse
        }
        var lastFailure: MidgardProviderError = .unavailable
        for baseURL in baseURLs {
            do {
                return try await fetchActions(
                    baseURL: baseURL,
                    address: address,
                    limit: limit,
                    nextPageToken: nextPageToken,
                    transactionID: transactionID
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let failure as MidgardProviderError {
                if case .clientStatus = failure { throw failure }
                lastFailure = failure
            } catch {
                lastFailure = .unavailable
            }
        }
        throw lastFailure
    }

    private func fetchActions(
        baseURL: URL,
        address: String,
        limit: Int,
        nextPageToken: String?,
        transactionID: TransactionID?
    ) async throws -> MidgardActionPage {
        let request = RequestBuilder(baseURL: baseURL, requestTimeout: requestTimeout, clientId: clientId).request(
            path: ["v2", "actions"],
            queryItems: [
                URLQueryItem(name: "address", value: address),
                URLQueryItem(name: "limit", value: String(limit)),
                nextPageToken.map { URLQueryItem(name: "nextPageToken", value: $0) },
                transactionID.map { URLQueryItem(name: "txid", value: $0.hash) },
            ].compactMap { $0 }
        )
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MidgardProviderError.unavailable
        }
        switch response.statusCode {
        case 200:
            guard Self.isJSON(response.value(forHTTPHeaderField: "Content-Type")) else {
                throw MidgardProviderError.invalidResponse
            }
        case 400 ..< 500: throw MidgardProviderError.clientStatus(response.statusCode)
        case 500 ... 599: throw MidgardProviderError.unavailable
        default: throw MidgardProviderError.invalidResponse
        }
        do {
            let envelope = try JSONDecoder().decode(MidgardActionsEnvelope.self, from: data)
            guard let actions = envelope.actions else { throw MidgardProviderError.invalidResponse }
            return MidgardActionPage(
                actions: actions,
                nextPageToken: envelope.meta?.nextPageToken?.isEmpty == false ? envelope.meta?.nextPageToken : nil
            )
        } catch let error as MidgardProviderError {
            throw error
        } catch {
            throw MidgardProviderError.invalidResponse
        }
    }

    private static func isJSON(_ value: String?) -> Bool {
        guard let value else { return false }
        return value.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "application/json"
    }
}

struct MidgardAction: Decodable, Sendable {
    let type: String?
    let status: String?
    let date: Int64?
    let height: Int64?
    let incoming: [MidgardActionTransaction]?
    let outgoing: [MidgardActionTransaction]?
    let metadata: MidgardJSONValue?

    enum CodingKeys: String, CodingKey {
        case type, status, date, height, metadata
        case incoming = "in"
        case outgoing = "out"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        date = try container.decodeIfPresent(FlexibleInt64.self, forKey: .date)?.value
        height = try container.decodeIfPresent(FlexibleInt64.self, forKey: .height)?.value
        incoming = try container.decodeIfPresent([MidgardActionTransaction].self, forKey: .incoming)
        outgoing = try container.decodeIfPresent([MidgardActionTransaction].self, forKey: .outgoing)
        metadata = try container.decodeIfPresent(MidgardJSONValue.self, forKey: .metadata)
    }
}

struct MidgardActionTransaction: Decodable, Sendable {
    let address: String?
    let transactionHash: String?
    let coins: [MidgardActionCoin]?

    enum CodingKeys: String, CodingKey { case address, coins; case transactionHash = "txID" }
}

struct MidgardActionCoin: Decodable, Sendable {
    let asset: String?
    let amount: String?
}

private struct MidgardActionsEnvelope: Decodable {
    struct Meta: Decodable { let nextPageToken: String? }
    let actions: [MidgardAction]?
    let meta: Meta?
}

private struct FlexibleInt64: Decodable {
    let value: Int64

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int64.self) {
            self.value = value
            return
        }
        let string = try container.decode(String.self)
        guard let value = Int64(string), String(value) == string else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected decimal Int64")
        }
        self.value = value
    }
}

indirect enum MidgardJSONValue: Decodable, Sendable {
    case object([String: MidgardJSONValue])
    case array([MidgardJSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: MidgardJSONValue].self) { self = .object(value) }
        else { self = try .array(container.decode([MidgardJSONValue].self)) }
    }

    var object: [String: MidgardJSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    var array: [MidgardJSONValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    var string: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }
}
