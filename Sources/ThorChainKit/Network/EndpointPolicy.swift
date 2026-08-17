import Foundation

public struct EndpointPolicy: Hashable, Sendable {
    public let maximumHeightLag: Int64
    public let identityRevalidationInterval: TimeInterval
    public let retryableStatusCodes: Set<Int>
    public let maximumAttempts: Int?
    public let maximumBalancePageCount: Int

    public init(
        maximumHeightLag: Int64 = 5,
        identityRevalidationInterval: TimeInterval = 300,
        retryableStatusCodes: Set<Int> = [408, 429, 502, 503, 504],
        maximumAttempts: Int? = nil,
        maximumBalancePageCount: Int = 100
    ) throws {
        guard maximumHeightLag >= 0 else {
            throw EndpointConfigurationError.invalidPolicyField("maximumHeightLag")
        }
        guard identityRevalidationInterval.isFinite, identityRevalidationInterval > 0 else {
            throw EndpointConfigurationError.invalidPolicyField("identityRevalidationInterval")
        }
        guard retryableStatusCodes.isSubset(of: [408, 429, 502, 503, 504]) else {
            throw EndpointConfigurationError.invalidPolicyField("retryableStatusCodes")
        }
        guard maximumAttempts.map({ $0 >= 1 }) ?? true else {
            throw EndpointConfigurationError.invalidPolicyField("maximumAttempts")
        }
        guard (1 ... 1000).contains(maximumBalancePageCount) else {
            throw EndpointConfigurationError.invalidPolicyField("maximumBalancePageCount")
        }
        self.maximumHeightLag = maximumHeightLag
        self.identityRevalidationInterval = identityRevalidationInterval
        self.retryableStatusCodes = retryableStatusCodes
        self.maximumAttempts = maximumAttempts
        self.maximumBalancePageCount = maximumBalancePageCount
    }

    public static let `default` = try! EndpointPolicy()
}
