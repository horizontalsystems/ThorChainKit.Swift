import Foundation
@testable import ThorChainKit
import XCTest

final class DerivationTests: XCTestCase {
    func testDefaultPathIsExactAndImmutable() throws {
        XCTAssertEqual(DerivationPath.defaultAccount.rawValue, "m/44'/931'/0'/0/0")
        XCTAssertEqual(try DerivationPath("m/44'/931'/0'/0/0"), .defaultAccount)
    }

    func testPathRejectsNonCanonicalComponents() {
        let cases: [(String, DerivationPathError)] = [
            ("m/44'/931'/0'/0", .invalidComponentCount),
            ("m/45'/931'/0'/0/0", .invalidPurpose),
            ("m/44'/930'/0'/0/0", .invalidCoinType),
            ("m/44'/931'/0/0/0", .invalidAccount),
            ("m/44'/931'/0'/1'/0", .invalidChain),
            ("m/44'/931'/0'/0/-1", .invalidIndex),
            ("m/44'/931'/00'/0/0", .malformedComponent),
            ("m/44'/931'/٠'/0/0", .malformedComponent),
            ("m /44'/931'/0'/0/0", .malformedComponent),
        ]

        for (raw, expected) in cases {
            XCTAssertThrowsError(try DerivationPath(raw)) { error in
                XCTAssertEqual(error as? DerivationPathError, expected, raw)
            }
        }
    }

    func testIndependentPublicKeyVectorProducesThorAddress() throws {
        let publicKey = Data(hex: "02a9ac9f7a97da41559e1684011b6a9b0b9c0445297d5f51dea0897fd4a39c31c7")
        XCTAssertEqual(AccountAddressHasher.hash160(Data("abc".utf8)).map { String(format: "%02x", $0) }.joined(), "bb1be98c142444d7a56aa3981c3942a978e4dc33")
        let address = try AccountAddressFactory.address(
            compressedPublicKey: publicKey,
            network: .mainnet
        )
        XCTAssertEqual(address.raw, "thor1tgxm5jw6hrlvslrd6lqpk4jwuu4g29dxytrean")
    }

    func testValidatorRejectsMalformedAndOffCurveKeys() {
        let validator = Secp256k1PublicKeyValidator()
        XCTAssertThrowsError(try validator.validate(Data(repeating: 0x02, count: 32))) { error in
            XCTAssertEqual(error as? AccountAddressError, .invalidCompressedPublicKeyLength(32))
        }
        XCTAssertThrowsError(try validator.validate(Data(repeating: 0x04, count: 33))) { error in
            XCTAssertEqual(error as? AccountAddressError, .invalidCompressedPublicKeyPrefix(0x04))
        }
        XCTAssertThrowsError(try validator.validate(Data([0x02] + Array(repeating: 0, count: 32)))) { error in
            XCTAssertEqual(error as? AccountAddressError, .invalidSecp256k1Point)
        }
    }

    func testValidatorMapsContextFailureToTypedError() {
        let validator = Secp256k1PublicKeyValidator(contextProvider: FailingContextProvider())
        XCTAssertThrowsError(try validator.validate(Data(repeating: 0x02, count: 33))) { error in
            XCTAssertEqual(error as? AccountAddressError, .secp256k1ContextUnavailable)
        }
    }
}

private struct FailingContextProvider: ISecp256k1ContextProvider {
    func makeContext() throws -> OpaquePointer {
        throw ContextFailure.unavailable
    }
}

private enum ContextFailure: Error {
    case unavailable
}

private extension Data {
    init(hex: String) {
        self.init(hex.chunked(2).map { UInt8($0, radix: 16)! })
    }
}

private extension String {
    func chunked(_ size: Int) -> [String] {
        stride(from: 0, to: count, by: size).map { offset in
            let start = index(startIndex, offsetBy: offset)
            let end = index(start, offsetBy: min(size, distance(from: start, to: endIndex)))
            return String(self[start ..< end])
        }
    }
}
