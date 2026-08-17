import SwiftProtobuf
@testable import ThorChainKit
import XCTest

final class CosmosQueryCodecTests: XCTestCase {
    func testGeneratedQueryCodecRoundTripsTypedAccountMessages() throws {
        let request = try CosmosQueryCodec.accountRequest(address: "thor1recipient")
        let decodedRequest = try Cosmos_Auth_V1beta1_QueryAccountRequest(serializedBytes: request)
        XCTAssertEqual(decodedRequest.address, "thor1recipient")

        var response = Cosmos_Auth_V1beta1_QueryAccountResponse()
        response.account.typeURL = "/cosmos.auth.v1beta1.BaseAccount"
        response.account.value = Data(#"{"account_number":"1"}"#.utf8)
        let value = try CosmosQueryCodec.decodeAccountResponse(response.serializedData())
        XCTAssertEqual(value, response.account.value)
    }

    func testAccountAnyAndNumericBoundaryMatrixFailsClosed() throws {
        var response = Cosmos_Auth_V1beta1_QueryAccountResponse()
        for typeURL in ["", "/cosmos.auth.v1beta1.Unknown", "/cosmos.auth.v1beta1.BaseAccount"] {
            response.account.typeURL = typeURL
            response.account.value = Data([0xFF])
            XCTAssertThrowsError(try CosmosQueryCodec.decodeAccountPayload(response.serializedData()))
        }

        for field in [UInt8(0x18), UInt8(0x20)] {
            response.account.typeURL = "/cosmos.auth.v1beta1.BaseAccount"
            response.account.value = Data([field] + Array(repeating: 0x80, count: 10) + [0x01])
            XCTAssertThrowsError(try CosmosQueryCodec.decodeAccountPayload(response.serializedData()))
        }
    }

    func testAccountPayloadDecodesPinnedBaseAccountAndPublicKeyState() throws {
        var account = Cosmos_Auth_V1beta1_BaseAccount()
        account.address = "thor1sender"
        account.accountNumber = 7
        account.sequence = 9
        account.pubKey.typeURL = "/cosmos.crypto.secp256k1.PubKey"
        var publicKey = Cosmos_Crypto_Secp256k1_PubKey()
        publicKey.key = Data([2] + Array(repeating: 1, count: 32))
        account.pubKey.value = try publicKey.serializedData()

        var response = Cosmos_Auth_V1beta1_QueryAccountResponse()
        response.account.typeURL = "/cosmos.auth.v1beta1.BaseAccount"
        response.account.value = try account.serializedData()
        let payload = try XCTUnwrap(CosmosQueryCodec.decodeAccountPayload(response.serializedData()))
        XCTAssertEqual(payload.typeURL, "/cosmos.auth.v1beta1.BaseAccount")
        XCTAssertEqual(payload.address, "thor1sender")
        XCTAssertEqual(payload.accountNumber, 7)
        XCTAssertEqual(payload.sequence, 9)
        XCTAssertEqual(payload.publicKeyTypeURL, "/cosmos.crypto.secp256k1.PubKey")
        XCTAssertEqual(payload.publicKeyData, Data([2] + Array(repeating: 1, count: 32)))
    }

    func testAllFiveVestingWrappersUnwrapTheSameBaseAccount() throws {
        let types = [
            "/cosmos.vesting.v1beta1.BaseVestingAccount",
            "/cosmos.vesting.v1beta1.ContinuousVestingAccount",
            "/cosmos.vesting.v1beta1.DelayedVestingAccount",
            "/cosmos.vesting.v1beta1.PeriodicVestingAccount",
            "/cosmos.vesting.v1beta1.PermanentLockedAccount",
        ]
        var base = Cosmos_Auth_V1beta1_BaseAccount()
        base.address = "thor1sender"
        base.accountNumber = 7
        base.sequence = 9
        for type in types {
            var response = Cosmos_Auth_V1beta1_QueryAccountResponse()
            response.account.typeURL = type
            switch type {
            case "/cosmos.vesting.v1beta1.BaseVestingAccount":
                var wrapper = Cosmos_Vesting_V1beta1_BaseVestingAccount(); wrapper.baseAccount = base
                response.account.value = try wrapper.serializedData()
            case "/cosmos.vesting.v1beta1.ContinuousVestingAccount":
                var wrapper = Cosmos_Vesting_V1beta1_ContinuousVestingAccount(); wrapper.baseVestingAccount.baseAccount = base; wrapper.startTime = 10
                response.account.value = try wrapper.serializedData()
            case "/cosmos.vesting.v1beta1.DelayedVestingAccount":
                var wrapper = Cosmos_Vesting_V1beta1_DelayedVestingAccount(); wrapper.baseVestingAccount.baseAccount = base
                response.account.value = try wrapper.serializedData()
            case "/cosmos.vesting.v1beta1.PeriodicVestingAccount":
                var period = Cosmos_Vesting_V1beta1_Period(); period.length = 1
                var wrapper = Cosmos_Vesting_V1beta1_PeriodicVestingAccount(); wrapper.baseVestingAccount.baseAccount = base; wrapper.vestingPeriods = [period]
                response.account.value = try wrapper.serializedData()
            default:
                var wrapper = Cosmos_Vesting_V1beta1_PermanentLockedAccount(); wrapper.baseVestingAccount.baseAccount = base
                response.account.value = try wrapper.serializedData()
            }
            let payload = try XCTUnwrap(CosmosQueryCodec.decodeAccountPayload(response.serializedData()))
            XCTAssertEqual(payload.typeURL, type)
            XCTAssertEqual(payload.address, "thor1sender")
        }
    }

    func testModuleAccountUnwrapsItsEmbeddedBaseAccount() throws {
        var base = Cosmos_Auth_V1beta1_BaseAccount()
        base.address = "thor1module"
        var module = Cosmos_Auth_V1beta1_ModuleAccount()
        module.baseAccount = base
        var response = Cosmos_Auth_V1beta1_QueryAccountResponse()
        response.account.typeURL = "/cosmos.auth.v1beta1.ModuleAccount"
        response.account.value = try module.serializedData()
        let payload = try XCTUnwrap(CosmosQueryCodec.decodeAccountPayload(response.serializedData()))
        XCTAssertEqual(payload.typeURL, "/cosmos.auth.v1beta1.ModuleAccount")
        XCTAssertEqual(payload.address, "thor1module")
    }

    func testVestingWrappersRequireTheExactEmbeddedBaseAccount() throws {
        let missing = Cosmos_Vesting_V1beta1_ContinuousVestingAccount()
        var response = Cosmos_Auth_V1beta1_QueryAccountResponse()
        response.account.typeURL = "/cosmos.vesting.v1beta1.ContinuousVestingAccount"
        response.account.value = try missing.serializedData()
        XCTAssertThrowsError(try CosmosQueryCodec.decodeAccountPayload(response.serializedData()))

        var wrong = Cosmos_Auth_V1beta1_BaseAccount(); wrong.address = "thor1other"
        var wrapper = Cosmos_Vesting_V1beta1_DelayedVestingAccount(); wrapper.baseVestingAccount.baseAccount = wrong
        response.account.typeURL = "/cosmos.vesting.v1beta1.DelayedVestingAccount"
        response.account.value = try wrapper.serializedData()
        let payload = try XCTUnwrap(CosmosQueryCodec.decodeAccountPayload(response.serializedData()))
        XCTAssertEqual(payload.address, "thor1other")
    }

    func testSecp256k1PublicKeyMustBeThePinnedCompressedShape() throws {
        var key = Cosmos_Crypto_Secp256k1_PubKey(); key.key = Data([4] + Array(repeating: 1, count: 32))
        var account = Cosmos_Auth_V1beta1_BaseAccount(); account.address = "thor1sender"; account.pubKey.typeURL = "/cosmos.crypto.secp256k1.PubKey"; account.pubKey.value = try key.serializedData()
        var response = Cosmos_Auth_V1beta1_QueryAccountResponse(); response.account.typeURL = "/cosmos.auth.v1beta1.BaseAccount"; response.account.value = try account.serializedData()
        XCTAssertThrowsError(try CosmosQueryCodec.decodeAccountPayload(response.serializedData()))
    }
}
