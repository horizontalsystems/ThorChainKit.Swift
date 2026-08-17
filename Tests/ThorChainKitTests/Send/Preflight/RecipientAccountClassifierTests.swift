@testable import ThorChainKit
import XCTest

final class RecipientAccountClassifierTests: XCTestCase {
    func testSupportedAccountAtExactHeightIsAUser() throws {
        let recipient = "thor1tgxm5jw6hrlvslrd6lqpk4jwuu4g29dxytrean"
        let set = try ForbiddenModuleAddressSet()
        let response = RecipientAccountResponse(height: 10, type: "/cosmos.auth.v1beta1.BaseAccount", address: recipient)
        XCTAssertEqual(try RecipientAccountClassifier.classify(response, expectedHeight: 10, recipient: recipient, forbidden: set), .user)
    }

    func testExactSdkNotFoundIsAbsentAndWrongProofFails() throws {
        let recipient = "thor1tgxm5jw6hrlvslrd6lqpk4jwuu4g29dxytrean"
        let set = try ForbiddenModuleAddressSet()
        let absent = RecipientAccountResponse(height: 10, code: 22, codespace: "sdk", type: nil)
        XCTAssertEqual(try RecipientAccountClassifier.classify(absent, expectedHeight: 10, recipient: recipient, forbidden: set), .absent)
        XCTAssertThrowsError(try RecipientAccountClassifier.classify(absent, expectedHeight: 11, recipient: recipient, forbidden: set)) { error in
            XCTAssertEqual(error as? SendError, .heightUnproven)
        }
    }

    func testReservedModuleAddressIsRejectedEvenAsAUserAccount() throws {
        let set = try ForbiddenModuleAddressSet()
        let address = "thor1v8ppstuf6e3x0r4glqc68d5jqcs2tf38cg2q6y"
        let response = RecipientAccountResponse(height: 10, address: address)
        XCTAssertThrowsError(try RecipientAccountClassifier.classify(response, expectedHeight: 10, recipient: address, forbidden: set)) { error in
            XCTAssertEqual(error as? SendError, .recipientIsModule)
        }
    }

    func testTypedModuleAccountIsClassifiedBeforeSendAdmission() throws {
        let recipient = "thor1tgxm5jw6hrlvslrd6lqpk4jwuu4g29dxytrean"
        let set = try ForbiddenModuleAddressSet()
        let response = RecipientAccountResponse(height: 10, type: "/cosmos.auth.v1beta1.ModuleAccount", address: recipient)
        XCTAssertEqual(try RecipientAccountClassifier.classify(response, expectedHeight: 10, recipient: recipient, forbidden: set), .module)
    }

    func testRecipientAccountNegativeMatrixFailsClosed() throws {
        let recipient = "thor1tgxm5jw6hrlvslrd6lqpk4jwuu4g29dxytrean"
        let set = try ForbiddenModuleAddressSet()
        let cases = [
            RecipientAccountResponse(height: 10, type: nil, address: recipient),
            RecipientAccountResponse(height: 10, type: "/cosmos.auth.v1beta1.Unknown", address: recipient),
            RecipientAccountResponse(height: 10, type: "/cosmos.auth.v1beta1.BaseAccount", address: nil),
            RecipientAccountResponse(height: 10, type: "/cosmos.auth.v1beta1.BaseAccount", address: "thor1other"),
            RecipientAccountResponse(height: 10, code: 22, codespace: nil, value: Data()),
            RecipientAccountResponse(height: 10, code: 22, codespace: "sdk", value: Data([1])),
            RecipientAccountResponse(height: 10, code: 22, codespace: "baseapp", value: Data()),
        ]
        for response in cases {
            XCTAssertThrowsError(try RecipientAccountClassifier.classify(response, expectedHeight: 10, recipient: recipient, forbidden: set)) { error in
                XCTAssertEqual(error as? SendError, .accountUnavailable)
            }
        }
    }

    func testReservedAddressRejectsAbsentAndUnexpectedPayloads() throws {
        let address = "thor1v8ppstuf6e3x0r4glqc68d5jqcs2tf38cg2q6y"
        let set = try ForbiddenModuleAddressSet()
        for response in [
            RecipientAccountResponse(height: 10, address: address),
            RecipientAccountResponse(height: 10, code: 22, codespace: "sdk"),
        ] {
            XCTAssertThrowsError(try RecipientAccountClassifier.classify(response, expectedHeight: 10, recipient: address, forbidden: set)) { error in
                XCTAssertEqual(error as? SendError, .recipientIsModule)
            }
        }
    }
}
