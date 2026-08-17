import Foundation
@testable import ThorChainKit
import XCTest

final class AddressCodecTests: XCTestCase {
    private let payload = Data(hex: "5a0dba49dab8fec87c6dd7c01b564ee72a8515a6")

    func testEncodeAndDecodeBindsAllSupportedNetworks() throws {
        let codec = AddressCodec()
        let networks = try [
            Network.mainnet,
            Network.stagenet(expectedChainId: "stage-1"),
            Network.chainnet(expectedChainId: "chain-1"),
        ]

        for network in networks {
            let address = try codec.encode(payload: payload, network: network)
            XCTAssertEqual(address.network, network)
            XCTAssertEqual(try codec.decode(address.raw.uppercased(), network: network), address)
        }
    }

    func testEncodeRejectsWrongPayloadLength() {
        XCTAssertThrowsError(try AddressCodec().encode(payload: Data(repeating: 0, count: 19), network: .mainnet)) { error in
            XCTAssertEqual(error as? AddressError, .invalidPayloadLength(expected: 20, actual: 19))
        }
    }

    func testDecodeDelegatesInheritedValidation() throws {
        let codec = AddressCodec()
        let address = try codec.encode(payload: payload, network: .mainnet)
        let wrongNetworkAddress = try codec.encode(
            payload: payload,
            network: Network.stagenet(expectedChainId: "stage-1")
        )
        XCTAssertThrowsError(try codec.decode(wrongNetworkAddress.raw, network: .mainnet)) { error in
            XCTAssertEqual(error as? AddressError, .wrongHrp(expected: "thor", actual: "sthor"))
        }
        XCTAssertThrowsError(try codec.decode(address.raw.dropLast() + "q", network: .mainnet)) { error in
            XCTAssertEqual(error as? AddressError, .invalidChecksum)
        }
    }

    func testClassicBech32IsNotBech32m() throws {
        let address = try AddressCodec().encode(payload: payload, network: .mainnet)
        XCTAssertEqual(address.raw, "thor1tgxm5jw6hrlvslrd6lqpk4jwuu4g29dxytrean")
    }

    func testPayloadBoundaryLengthsFailClosed() {
        for length in [0, 19, 21, 256] {
            XCTAssertThrowsError(try AddressCodec().encode(
                payload: Data(repeating: 0, count: length),
                network: .mainnet
            )) { error in
                XCTAssertEqual(error as? AddressError, .invalidPayloadLength(expected: 20, actual: length))
            }
        }
    }

    func testBIP173Vectors() {
        let valid = [
            "A12UEL5L",
            "a12uel5l",
            "an83characterlonghumanreadablepartthatcontainsthenumber1andtheexcludedcharactersbio1tt5tgs",
            "abcdef1qpzry9x8gf2tvdw0s3jn54khce6mua7lmqqqxw",
        ]
        for vector in valid {
            XCTAssertNoThrow(try Bech32Codec.decode(vector), vector)
        }

        let invalid = [
            "an84characterslonghumanreadablepartthatcontainsthenumber1andtheexcludedcharactersbio1tt5tgs",
            "pzry9x0s0muk",
            "1pzry9x0s0muk",
            "x1b4n0q5v",
            "li1dgmt3",
            "A1G7SGD8",
            "10a06t8",
            "1qzzfhee",
        ]
        for vector in invalid {
            XCTAssertThrowsError(try Bech32Codec.decode(vector), vector)
        }
    }

    func testBitConversionPaddingKnownAnswers() throws {
        XCTAssertEqual(try BitConversion.convert([0xFF], fromBits: 8, toBits: 5, pad: true), [31, 28])
        XCTAssertEqual(try BitConversion.convert([31, 28], fromBits: 5, toBits: 8, pad: false), [255])
        XCTAssertThrowsError(try BitConversion.convert([31, 29], fromBits: 5, toBits: 8, pad: false)) { error in
            XCTAssertEqual(error as? AddressError, .invalidPadding)
        }
    }

    func testDeterministicFuzzReplay() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/S1-03-fuzz-seed.txt")
        let fixture = try String(contentsOf: fixtureURL, encoding: .utf8)
        let lines = fixture.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines, ["version=1", "algorithm=splitmix64", "seed=0x534c30332d46555a", "count=1024"])
        guard let seedText = lines.first(where: { $0.hasPrefix("seed=") })?.dropFirst(5),
              let seed = UInt64(seedText.dropFirst(2), radix: 16),
              let countText = lines.first(where: { $0.hasPrefix("count=") })?.dropFirst(6),
              let count = Int(countText)
        else {
            XCTFail("invalid deterministic fuzz fixture")
            return
        }

        var state = seed
        let codec = AddressCodec()
        for _ in 0 ..< count {
            var bytes = [UInt8]()
            for _ in 0 ..< 3 {
                state &+= 0x9E37_79B9_7F4A_7C15
                var value = state
                value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
                value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
                value ^= value >> 31
                bytes.append(contentsOf: (0 ..< 8).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) })
            }
            let payload = Data(bytes.prefix(20))
            let address = try codec.encode(payload: payload, network: .mainnet)
            XCTAssertEqual(try codec.decode(address.raw, network: .mainnet).payload, payload)
        }
    }

    func testArbitraryUTF8NeverTraps() {
        let inputs = ["", "thor1", "\u{0}", "é", "🙂", "thor1\u{2028}x", String(repeating: "q", count: 120)]
        for input in inputs {
            _ = try? AddressCodec().decode(input, network: .mainnet)
        }
    }
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
