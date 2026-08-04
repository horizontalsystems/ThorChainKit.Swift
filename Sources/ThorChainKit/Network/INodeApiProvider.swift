import Foundation

protocol INodeApiProvider: Sendable {
    func account(address: Address, using lease: EndpointLease, timeout: TimeInterval?) async throws -> AccountTransport?
    func balances(address: Address, using lease: EndpointLease, timeout: TimeInterval?) async throws -> [BalanceTransport]
}
