import BigInt
import Combine
import Foundation
@testable import ThorChainKit
import XCTest

final class SendPublicApiTests: XCTestCase {
    func testFallbackQuotePathRefusesANonRuneDenom() async throws {
        // Without a preflight the quote is built by a path that predates denoms and would
        // return a RUNE quote whatever was asked for. Refusing is the only safe answer:
        // silently quoting the wrong asset is how the user ends up signing it.
        let kit = try makeTestKit(address: sendTestAddress(), persistenceNamespace: "fallback-denom")

        do {
            _ = try await kit.quote(to: sendOtherAddress(), amount: .exact(1), denom: Denom(rawValue: "tcy"))
            XCTFail("expected the fallback path to refuse a token quote")
        } catch {
            XCTAssertEqual(error as? SendError, .operationUnavailable)
        }
    }

    func testLifecycleAdmissionPrecedesValidationAndDeferredEnginesFailClosed() async throws {
        let address = try sendTestAddress()
        let runtime = SendRuntime(address: address)
        let kit = makeTestKit(address: address, transactionSender: runtime, persistenceNamespace: "send-admission")

        do {
            _ = try await kit.quote(to: address, amount: .exact(0))
            XCTFail("inactive kit must reject before validation")
        } catch let error as SendError {
            XCTAssertEqual(error, .kitNotStarted)
        }

        await runtime.activate(generation: 1)
        let otherRecipient = try Address(
            "thor1tgxm5jw6hrlvslrd6lqpk4jwuu4g29dxytrean",
            network: .mainnet
        )
        do {
            _ = try await kit.quote(to: otherRecipient, amount: .exact(0))
            XCTFail("invalid amount must be rejected before deferred engine")
        } catch let error as SendError {
            XCTAssertEqual(error, .invalidAmount)
        }
    }

    func testQuoteZeroAmountPrecedesRecipientChecks() async throws {
        let address = try sendTestAddress()
        let runtime = SendRuntime(address: address)
        let kit = makeTestKit(address: address, transactionSender: runtime, persistenceNamespace: "send-validation-order")

        await runtime.activate(generation: 1)
        do {
            _ = try await kit.quote(to: address, amount: .exact(0))
            XCTFail("invalid amount must be rejected before recipient checks")
        } catch let error as SendError {
            XCTAssertEqual(error, .invalidAmount)
        }
    }
}
