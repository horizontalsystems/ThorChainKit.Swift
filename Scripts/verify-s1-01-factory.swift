import CryptoKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("FAIL verify-s1-01-factory: \(message)\n".utf8))
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

func namedVariable(_ name: String, in value: Any) -> Any? {
    if let object = value as? [String: Any] {
        if object["_kind"] as? String == "var_decl",
           let declarationName = object["name"] as? [String: Any],
           let baseName = declarationName["base_name"] as? [String: Any],
           baseName["name"] as? String == name
        {
            return object
        }
        for child in object.values {
            if let match = namedVariable(name, in: child) {
                return match
            }
        }
    } else if let array = value as? [Any] {
        for child in array {
            if let match = namedVariable(name, in: child) {
                return match
            }
        }
    }
    return nil
}

let unstableKeys: Set<String> = ["compiler_version", "decl_context", "filename", "range"]

func normalized(_ value: Any) -> Any {
    if let object = value as? [String: Any] {
        return Dictionary(uniqueKeysWithValues: object.compactMap { key, child in
            unstableKeys.contains(key) || key.hasSuffix("_context")
                ? nil
                : (key, normalized(child))
        })
    }
    if let array = value as? [Any] {
        return array.map(normalized)
    }
    if let string = value as? String, string.hasPrefix("0x") {
        return "<pointer>"
    }
    return value
}

func digest(_ value: Any) -> String {
    let data: Data
    do {
        data = try JSONSerialization.data(withJSONObject: normalized(value), options: [.sortedKeys])
    } catch {
        fail("could not canonicalize parser output: \(error)")
    }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

guard CommandLine.arguments.count == 2 else {
    fail("usage: verify-s1-01-factory.swift <fixture>")
}

let files = [
    "Sources/ThorChainKit/Core/KitFactory.swift",
    "Sources/ThorChainKit/Core/KitDependencies.swift",
    "Sources/ThorChainKit/Core/Kit.swift",
]
var actual = files.map { "\($0)\t\(digest(parsedAST($0)))" }
let networkPath = "Sources/ThorChainKit/Models/Network.swift"
guard let persistenceKey = namedVariable("persistenceKey", in: parsedAST(networkPath)) else {
    fail("Network.persistenceKey declaration is absent")
}

actual.append("\(networkPath)#persistenceKey\t\(digest(persistenceKey))")

let fixtureURL = root.appendingPathComponent(CommandLine.arguments[1])
guard let expected = try? String(contentsOf: fixtureURL, encoding: .utf8) else {
    fail("fixture is unavailable at \(CommandLine.arguments[1])")
}

let result = actual.joined(separator: "\n") + "\n"
guard result == expected else {
    fail("normalized syntax differs; actual fixture follows:\n\(result)")
}

print("PASS verify-s1-01-factory")
