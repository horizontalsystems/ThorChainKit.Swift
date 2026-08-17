import CoreFoundation
import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

private enum VerificationFailure: Error {
    case invalid
}

private struct Origin: Encodable {
    let scheme: String
    let host: String
    let port: Int?

    private enum CodingKeys: String, CodingKey { case scheme, host, port }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(scheme, forKey: .scheme)
        try container.encode(host, forKey: .host)
        if let port {
            try container.encode(port, forKey: .port)
        } else {
            try container.encodeNil(forKey: .port)
        }
    }
}

private struct FamilyEvidence: Encodable {
    let familyId: String
    let cosmosOrigin: Origin
    let cometOrigin: Origin
    let identityClassification: String
    let cosmosHeight: Int64
    let cometHeight: Int64
    let heightSkew: Int64
    let catchingUp: Bool
    let outcome: String
}

private struct Selection: Encodable {
    let familyId: String
    let poolGeneration: UInt64
}

private struct Evidence: Encodable {
    let schemaVersion: Int
    let source: String
    let implementationHead: String
    let generatedAt: String
    let expectedChainId: String
    let families: [FamilyEvidence]
    let selection: Selection
}

private let expectedChainId = "thorchain-1"
private let forbidden = [
    "url", "userinfo", "path", "query", "fragment", "response", "body", "error",
    "actual", "observed", "raw", "mnemonic", "seed phrase", "private key", "api key",
    "foreign-secret-chain",
]

private func require(_ condition: Bool) throws {
    guard condition else { throw VerificationFailure.invalid }
}

private func dictionary(_ value: Any, keys: Set<String>) throws -> [String: Any] {
    guard let value = value as? [String: Any] else { throw VerificationFailure.invalid }
    try require(Set(value.keys) == keys)
    return value
}

private func integer(_ value: Any) throws -> Int64 {
    guard let number = value as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID(),
          !CFNumberIsFloatType(number)
    else {
        throw VerificationFailure.invalid
    }
    return number.int64Value
}

private func string(_ value: Any) throws -> String {
    guard let value = value as? String else { throw VerificationFailure.invalid }
    return value
}

private func boolean(_ value: Any) throws -> Bool {
    guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
        throw VerificationFailure.invalid
    }
    return number.boolValue
}

private func rejectForbidden(_ value: Any) throws {
    if let object = value as? [String: Any] {
        for (key, child) in object {
            let lowered = key.lowercased()
            try require(!forbidden.contains(where: lowered.contains))
            try rejectForbidden(child)
        }
    } else if let values = value as? [Any] {
        try values.forEach(rejectForbidden)
    } else if let value = value as? String {
        let lowered = value.lowercased()
        try require(!forbidden.contains(where: lowered.contains))
    }
}

private func validateOrigin(_ value: Any) throws {
    let object = try dictionary(value, keys: ["scheme", "host", "port"])
    try require(string(object["scheme"] as Any) == "https")
    let host = try string(object["host"] as Any)
    try require(!host.isEmpty && host == host.lowercased())
    if !(object["port"] is NSNull) {
        let port = try integer(object["port"] as Any)
        try require((1 ... 65535).contains(port))
    }
}

private func occurrences(of key: String, in source: String) -> Int {
    let pattern = "\\\"" + NSRegularExpression.escapedPattern(for: key) + "\\\"\\s*:"
    let expression = try! NSRegularExpression(pattern: pattern)
    return expression.numberOfMatches(in: source, range: NSRange(source.startIndex..., in: source))
}

private func validate(
    input: String,
    finalOutput: String,
    repositoryRoot: String,
    head: String,
    familyIDs: [String]
) throws {
    try require(head.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil)
    try require(familyIDs.count == 2 && Set(familyIDs).count == 2)
    try familyIDs.forEach {
        try require($0.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil)
    }
    let expectedOutput = URL(fileURLWithPath: repositoryRoot)
        .appendingPathComponent("build/s1-02-live/\(head)/evidence.json").standardizedFileURL.path
    try require(URL(fileURLWithPath: finalOutput).standardizedFileURL.path == expectedOutput)

    let data = try Data(contentsOf: URL(fileURLWithPath: input))
    guard let sourceText = String(data: data, encoding: .utf8) else { throw VerificationFailure.invalid }
    let expectedCounts = [
        "schemaVersion": 1, "source": 1, "implementationHead": 1, "generatedAt": 1,
        "expectedChainId": 1, "families": 1, "selection": 1, "familyId": 3,
        "cosmosOrigin": 2, "cometOrigin": 2, "identityClassification": 2,
        "cosmosHeight": 2, "cometHeight": 2, "heightSkew": 2, "catchingUp": 2,
        "outcome": 2, "scheme": 4, "host": 4, "port": 4, "poolGeneration": 1,
    ]
    for (key, count) in expectedCounts {
        try require(occurrences(of: key, in: sourceText) == count)
    }

    let root = try JSONSerialization.jsonObject(with: data)
    try rejectForbidden(root)
    let object = try dictionary(root, keys: [
        "schemaVersion", "source", "implementationHead", "generatedAt", "expectedChainId",
        "families", "selection",
    ])
    try require(integer(object["schemaVersion"] as Any) == 1)
    try require(string(object["source"] as Any) == "thorchainkit-s1-02-live")
    try require(string(object["implementationHead"] as Any) == head)
    try require(string(object["expectedChainId"] as Any) == expectedChainId)
    let generatedAt = try string(object["generatedAt"] as Any)
    try require(generatedAt.range(
        of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$",
        options: .regularExpression
    ) != nil)

    guard let familyValues = object["families"] as? [Any], familyValues.count == 2 else {
        throw VerificationFailure.invalid
    }
    var cometHeights = [Int64]()
    for (index, value) in familyValues.enumerated() {
        let family = try dictionary(value, keys: [
            "familyId", "cosmosOrigin", "cometOrigin", "identityClassification",
            "cosmosHeight", "cometHeight", "heightSkew", "catchingUp", "outcome",
        ])
        try require(string(family["familyId"] as Any) == familyIDs[index])
        try validateOrigin(family["cosmosOrigin"] as Any)
        try validateOrigin(family["cometOrigin"] as Any)
        try require(string(family["identityClassification"] as Any) == "expected")
        try require(string(family["outcome"] as Any) == "eligible")
        let cosmos = try integer(family["cosmosHeight"] as Any)
        let comet = try integer(family["cometHeight"] as Any)
        let skew = try integer(family["heightSkew"] as Any)
        try require(cosmos > 0 && comet > 0 && skew == abs(cosmos - comet) && skew <= 5)
        try require(boolean(family["catchingUp"] as Any) == false)
        cometHeights.append(comet)
    }

    let selection = try dictionary(object["selection"] as Any, keys: ["familyId", "poolGeneration"])
    let generation = try integer(selection["poolGeneration"] as Any)
    try require(generation >= 0)
    let winner = cometHeights[1] > cometHeights[0] ? familyIDs[1] : familyIDs[0]
    try require(string(selection["familyId"] as Any) == winner)
}

private func origin(_ url: URL) throws -> Origin {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          components.scheme?.lowercased() == "https",
          let host = components.host?.lowercased(),
          !host.isEmpty,
          components.user == nil,
          components.password == nil,
          components.query == nil,
          components.fragment == nil
    else {
        throw VerificationFailure.invalid
    }
    return Origin(scheme: "https", host: host, port: components.port)
}

private func append(_ path: String, to base: URL) throws -> URL {
    guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
        throw VerificationFailure.invalid
    }
    let prefix = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    components.percentEncodedPath = "/" + [prefix, path].filter { !$0.isEmpty }.joined(separator: "/")
    guard let result = components.url else { throw VerificationFailure.invalid }
    return result
}

private func fetch(_ url: URL) async throws -> [String: Any] {
    var request = URLRequest(url: url)
    request.timeoutInterval = 15
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let response = response as? HTTPURLResponse, (200 ..< 300).contains(response.statusCode),
          let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        throw VerificationFailure.invalid
    }
    return object
}

private func nested(_ object: [String: Any], _ keys: String...) throws -> Any {
    var value: Any = object
    for key in keys {
        guard let dictionary = value as? [String: Any], let next = dictionary[key] else {
            throw VerificationFailure.invalid
        }
        value = next
    }
    return value
}

private func probeFamily(id: String, cosmos: URL, comet: URL) async throws -> FamilyEvidence {
    async let node = try fetch(append("cosmos/base/tendermint/v1beta1/node_info", to: cosmos))
    async let block = try fetch(append("cosmos/base/tendermint/v1beta1/blocks/latest", to: cosmos))
    async let status = try fetch(append("status", to: comet))
    let (nodeValue, blockValue, statusValue) = try await (node, block, status)
    let identities = try [
        string(nested(nodeValue, "default_node_info", "network")),
        string(nested(blockValue, "block", "header", "chain_id")),
        string(nested(statusValue, "result", "node_info", "network")),
    ]
    try require(identities.allSatisfy { $0 == expectedChainId })
    guard let cosmosHeight = try Int64(string(nested(blockValue, "block", "header", "height"))),
          let cometHeight = try Int64(string(nested(statusValue, "result", "sync_info", "latest_block_height")))
    else {
        throw VerificationFailure.invalid
    }
    let catchingUp = try boolean(nested(statusValue, "result", "sync_info", "catching_up"))
    let skew = abs(cosmosHeight - cometHeight)
    try require(cosmosHeight > 0 && cometHeight > 0 && skew <= 5 && !catchingUp)
    return try FamilyEvidence(
        familyId: id,
        cosmosOrigin: origin(cosmos),
        cometOrigin: origin(comet),
        identityClassification: "expected",
        cosmosHeight: cosmosHeight,
        cometHeight: cometHeight,
        heightSkew: skew,
        catchingUp: false,
        outcome: "eligible"
    )
}

private func environment(_ name: String) throws -> String {
    guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
        throw VerificationFailure.invalid
    }
    return value
}

private func probe(output: String, finalOutput: String, repositoryRoot: String, head: String) async throws {
    let ids = try [environment("THORCHAIN_S1_02_FAMILY_A_ID"), environment("THORCHAIN_S1_02_FAMILY_B_ID")]
    guard let cosmosA = try URL(string: environment("THORCHAIN_S1_02_FAMILY_A_COSMOS_URL")),
          let cometA = try URL(string: environment("THORCHAIN_S1_02_FAMILY_A_COMET_URL")),
          let cosmosB = try URL(string: environment("THORCHAIN_S1_02_FAMILY_B_COSMOS_URL")),
          let cometB = try URL(string: environment("THORCHAIN_S1_02_FAMILY_B_COMET_URL"))
    else {
        throw VerificationFailure.invalid
    }
    let first = try await probeFamily(id: ids[0], cosmos: cosmosA, comet: cometA)
    let second = try await probeFamily(id: ids[1], cosmos: cosmosB, comet: cometB)
    let winner = second.cometHeight > first.cometHeight ? second.familyId : first.familyId
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    let evidence = Evidence(
        schemaVersion: 1,
        source: "thorchainkit-s1-02-live",
        implementationHead: head,
        generatedAt: formatter.string(from: Date()),
        expectedChainId: expectedChainId,
        families: [first, second],
        selection: Selection(familyId: winner, poolGeneration: 0)
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(evidence).write(to: URL(fileURLWithPath: output), options: .atomic)
    try validate(input: output, finalOutput: finalOutput, repositoryRoot: repositoryRoot, head: head, familyIDs: ids)
}

private func selfTest(repositoryRoot: String, head: String) throws {
    let ids = ["provider-a", "provider-b"]
    let output = URL(fileURLWithPath: repositoryRoot)
        .appendingPathComponent("build/s1-02-live/\(head)/evidence.json").path
    let temporary = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString + ".json")
    defer { try? FileManager.default.removeItem(at: temporary) }
    let evidence = Evidence(
        schemaVersion: 1,
        source: "thorchainkit-s1-02-live",
        implementationHead: head,
        generatedAt: "2026-07-19T00:00:00Z",
        expectedChainId: expectedChainId,
        families: [
            FamilyEvidence(familyId: ids[0], cosmosOrigin: Origin(scheme: "https", host: "a.invalid", port: nil), cometOrigin: Origin(scheme: "https", host: "ra.invalid", port: 443), identityClassification: "expected", cosmosHeight: 100, cometHeight: 101, heightSkew: 1, catchingUp: false, outcome: "eligible"),
            FamilyEvidence(familyId: ids[1], cosmosOrigin: Origin(scheme: "https", host: "b.invalid", port: nil), cometOrigin: Origin(scheme: "https", host: "rb.invalid", port: nil), identityClassification: "expected", cosmosHeight: 101, cometHeight: 102, heightSkew: 1, catchingUp: false, outcome: "eligible"),
        ],
        selection: Selection(familyId: ids[1], poolGeneration: 0)
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let baseline = try encoder.encode(evidence)
    try baseline.write(to: temporary)
    try validate(input: temporary.path, finalOutput: output, repositoryRoot: repositoryRoot, head: head, familyIDs: ids)

    func reject(_ mutate: (inout [String: Any]) -> Void) throws {
        var object = try JSONSerialization.jsonObject(with: baseline) as! [String: Any]
        mutate(&object)
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: temporary)
        var rejected = false
        do {
            try validate(input: temporary.path, finalOutput: output, repositoryRoot: repositoryRoot, head: head, familyIDs: ids)
        } catch {
            rejected = true
        }
        try require(rejected)
    }
    try reject { $0["source"] = "thorchainkit-s1-02-fixture" }
    try reject { $0["implementationHead"] = String(repeating: "0", count: 40) }
    try reject { $0["unexpected"] = true }
    try reject { $0.removeValue(forKey: "generatedAt") }
    try reject { $0["schemaVersion"] = "1" }
    try reject {
        var selection = $0["selection"] as! [String: Any]
        selection["familyId"] = ids[0]
        $0["selection"] = selection
    }
    try reject {
        var families = $0["families"] as! [[String: Any]]
        families[0]["cometHeight"] = 102
        families[0]["cosmosHeight"] = 101
        families[1]["cometHeight"] = 102
        families[1]["cosmosHeight"] = 101
        var selection = $0["selection"] as! [String: Any]
        selection["familyId"] = ids[1]
        $0["families"] = families
        $0["selection"] = selection
    }
    try baseline.write(to: temporary)
    var wrongPathRejected = false
    do {
        try validate(input: temporary.path, finalOutput: output + ".fixture", repositoryRoot: repositoryRoot, head: head, familyIDs: ids)
    } catch {
        wrongPathRejected = true
    }
    try require(wrongPathRejected)

    var duplicate = String(decoding: baseline, as: UTF8.self)
    duplicate = duplicate.replacingOccurrences(of: "\"source\" :", with: "\"source\" : \"thorchainkit-s1-02-live\", \"source\" :", options: [], range: duplicate.range(of: "\"source\" :"))
    try Data(duplicate.utf8).write(to: temporary)
    var duplicateRejected = false
    do {
        try validate(input: temporary.path, finalOutput: output, repositoryRoot: repositoryRoot, head: head, familyIDs: ids)
    } catch {
        duplicateRejected = true
    }
    try require(duplicateRejected)
}

@main
private enum Main {
    static func main() async {
        do {
            let arguments = CommandLine.arguments
            switch arguments.dropFirst().first {
            case "probe" where arguments.count == 6:
                try await probe(output: arguments[2], finalOutput: arguments[3], repositoryRoot: arguments[4], head: arguments[5])
            case "validate" where arguments.count == 8:
                try validate(input: arguments[2], finalOutput: arguments[3], repositoryRoot: arguments[4], head: arguments[5], familyIDs: [arguments[6], arguments[7]])
            case "self-test" where arguments.count == 4:
                try selfTest(repositoryRoot: arguments[2], head: arguments[3])
            default:
                throw VerificationFailure.invalid
            }
        } catch {
            FileHandle.standardError.write(Data("S1-02 live evidence verification failed\n".utf8))
            exit(1)
        }
    }
}
