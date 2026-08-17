import Foundation

// LiveSupport resolves HdWalletKit.Swift at 2fc0dbfc089f78a9804baafe8e1bc4aab69cbad1;
// its signing closure uses the package-pinned HsCryptoKit 1.3.2 and secp256k1 0.10.0.

public enum LiveSecretError: Error, Equatable {
    case unavailable
    case malformed
    case invalidRecipient
}

public struct LiveSecretLoader {
    public init() {}

    public func load(from url: URL) throws -> (words: [String], recipient: String) {
        let fileManager = FileManager.default
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              (1 ... 4096).contains(size.intValue)
        else { throw LiveSecretError.unavailable }
        if let permissions = attributes[.posixPermissions] as? NSNumber,
           permissions.intValue & 0o777 != 0o600
        {
            throw LiveSecretError.unavailable
        }
        defer { try? fileManager.removeItem(at: url) }
        let data: Data
        do { data = try Data(contentsOf: url, options: [.uncached]) } catch { throw LiveSecretError.unavailable }
        guard let text = String(data: data, encoding: .utf8) else { throw LiveSecretError.malformed }
        let allowedKeys = Set([
            "THORCHAIN_NETWORK",
            "THORCHAIN_MAINNET_MNEMONIC",
            "THORCHAIN_MAINNET_RECIPIENT_ADDRESS",
        ])
        var values = [String: String]()
        for line in text.split(whereSeparator: \.isNewline) {
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty else { throw LiveSecretError.malformed }
            let key = String(parts[0])
            guard allowedKeys.contains(key), values[key] == nil else { throw LiveSecretError.malformed }
            values[key] = String(parts[1])
        }
        guard values["THORCHAIN_NETWORK"] == "mainnet",
              let mnemonic = values["THORCHAIN_MAINNET_MNEMONIC"],
              let recipient = values["THORCHAIN_MAINNET_RECIPIENT_ADDRESS"]
        else { throw LiveSecretError.unavailable }
        let words = mnemonic.split(separator: " ").map(String.init)
        guard words.count == 12,
              words.allSatisfy({ $0 == $0.lowercased() && !$0.isEmpty }),
              words.joined(separator: " ") == mnemonic
        else { throw LiveSecretError.malformed }
        return (words, recipient)
    }
}
