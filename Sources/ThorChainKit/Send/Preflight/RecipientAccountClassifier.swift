import Foundation

enum RecipientAccountClassification: String, Equatable, Hashable, Sendable {
    case user
    case absent
    case module
}

struct RecipientAccountResponse: Equatable, Sendable, Decodable {
    let height: Int64
    let code: Int
    let codespace: String?
    let type: String?
    let address: String?
    let value: Data

    init(height: Int64, code: Int = 0, codespace: String? = nil, type: String? = "/cosmos.auth.v1beta1.BaseAccount", address: String? = nil, value: Data = Data()) {
        self.height = height; self.code = code; self.codespace = codespace; self.type = type; self.address = address; self.value = value
    }

    private enum CodingKeys: String, CodingKey { case height, code, codespace, type, address, value }
}

enum RecipientAccountClassifier {
    static let supportedTypes: Set<String> = [
        "/cosmos.auth.v1beta1.BaseAccount",
        "/cosmos.auth.v1beta1.ModuleAccount",
        "/cosmos.vesting.v1beta1.BaseVestingAccount",
        "/cosmos.vesting.v1beta1.ContinuousVestingAccount",
        "/cosmos.vesting.v1beta1.DelayedVestingAccount",
        "/cosmos.vesting.v1beta1.PeriodicVestingAccount",
        "/cosmos.vesting.v1beta1.PermanentLockedAccount",
    ]

    static func classify(_ response: RecipientAccountResponse, expectedHeight: Int64, recipient: String, forbidden: ForbiddenModuleAddressSet) throws -> RecipientAccountClassification {
        guard response.height == expectedHeight else { throw SendError.heightUnproven }
        if forbidden.contains(recipient) { throw SendError.recipientIsModule }
        if response.code == 22, response.codespace == "sdk", response.value.isEmpty { return .absent }
        guard response.code == 0, let type = response.type, supportedTypes.contains(type), response.address == recipient else {
            throw SendError.accountUnavailable
        }
        if type == "/cosmos.auth.v1beta1.ModuleAccount" { return .module }
        return .user
    }
}
