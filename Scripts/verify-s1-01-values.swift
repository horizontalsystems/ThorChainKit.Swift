import CryptoKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("FAIL verify-s1-01-values: \(message)\n".utf8))
    exit(1)
}

func parsedAST(_ path: String) -> Any {
    let process = Process()
    let output = Pipe()
    let errors = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = [
        "swiftc", "-frontend", "-dump-parse", "-dump-ast-format", "json", path,
    ]
    process.currentDirectoryURL = root
    process.standardOutput = output
    process.standardError = errors
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        fail("could not launch the Swift parser: \(error)")
    }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    guard process.terminationStatus == 0 else {
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        fail("Swift parser rejected \(path): \(message)")
    }
    do {
        return try JSONSerialization.jsonObject(with: data)
    } catch {
        fail("invalid parser JSON for \(path): \(error)")
    }
}

let unstableKeys: Set<String> = ["compiler_version", "decl_context", "filename", "range"]

func isPersistenceKey(_ object: [String: Any]) -> Bool {
    guard object["_kind"] as? String == "var_decl",
          let declarationName = object["name"] as? [String: Any],
          let baseName = declarationName["base_name"] as? [String: Any]
    else {
        return false
    }
    return baseName["name"] as? String == "persistenceKey"
}

func normalized(_ value: Any, excludingPersistenceKey: Bool = false) -> Any? {
    if let object = value as? [String: Any] {
        if excludingPersistenceKey, isPersistenceKey(object) {
            return nil
        }
        var result: [String: Any] = [:]
        for (key, child) in object
            where !unstableKeys.contains(key) && !key.hasSuffix("_context")
        {
            if let normalizedChild = normalized(
                child,
                excludingPersistenceKey: excludingPersistenceKey
            ) {
                result[key] = normalizedChild
            }
        }
        return result
    }
    if let array = value as? [Any] {
        return array.compactMap {
            normalized($0, excludingPersistenceKey: excludingPersistenceKey)
        }
    }
    if let string = value as? String, string.hasPrefix("0x") {
        return "<pointer>"
    }
    return value
}

func digest(_ value: Any, excludingPersistenceKey: Bool = false) -> String {
    guard let canonical = normalized(value, excludingPersistenceKey: excludingPersistenceKey) else {
        fail("normalization removed an entire syntax tree")
    }
    let data: Data
    do {
        data = try JSONSerialization.data(withJSONObject: canonical, options: [.sortedKeys])
    } catch {
        fail("could not canonicalize parser output: \(error)")
    }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

guard CommandLine.arguments.count == 2 else {
    fail("usage: verify-s1-01-values.swift <fixture>")
}

let files = [
    "Sources/ThorChainKit/Models/Network.swift",
    "Sources/ThorChainKit/Network/EndpointFamilyDescriptor.swift",
    "Sources/ThorChainKit/Network/EndpointPolicy.swift",
    "Sources/ThorChainKit/Models/EndpointConfiguration.swift",
    "Sources/ThorChainKit/Models/Denom.swift",
    "Sources/ThorChainKit/Models/Address.swift",
    "Sources/ThorChainKit/Address/AddressError.swift",
    "Sources/ThorChainKit/Address/Bech32Codec.swift",
    "Sources/ThorChainKit/Address/BitConversion.swift",
    "Sources/ThorChainKit/Core/KitConfigurationError.swift",
]
let actual = files.map { path in
    let hash = digest(
        parsedAST(path),
        excludingPersistenceKey: path.hasSuffix("/Network.swift")
    )
    return "\(path)\t\(hash)"
}.joined(separator: "\n") + "\n"

let fixtureURL = root.appendingPathComponent(CommandLine.arguments[1])
guard let expected = try? String(contentsOf: fixtureURL, encoding: .utf8) else {
    fail("fixture is unavailable at \(CommandLine.arguments[1])")
}

guard actual == expected else {
    fail("normalized syntax differs; actual fixture follows:\n\(actual)")
}

print("PASS verify-s1-01-values")
