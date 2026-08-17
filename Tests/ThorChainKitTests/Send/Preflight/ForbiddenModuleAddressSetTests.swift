@testable import ThorChainKit
import XCTest

final class ForbiddenModuleAddressSetTests: XCTestCase {
    func testEveryPinnedModuleVectorAndSourceProvenanceIsPresent() throws {
        let policy = try ForbiddenModuleAddressSet()
        XCTAssertEqual(ForbiddenModuleAddressSet.sourceTags, ["v3.19.0@5f2141c3", "v3.19.1@59a3e925", "v3.19.2@c6fa8caa", "v3.19.3@52e66ad9"])
        XCTAssertEqual(ForbiddenModuleAddressSet.sourceFileSHA256, "72ce4607cfcd45e1546e9c12d79afaeeb897946d0c9f3df31c14b8e05a3a98cf")
        XCTAssertEqual(ForbiddenModuleAddressSet.pinnedModuleVectors.count, 9)
        for (_, address) in ForbiddenModuleAddressSet.pinnedModuleVectors {
            XCTAssertTrue(policy.contains(address))
        }
    }

    func testThorchainVectorAndAUserAddress() throws {
        let policy = try ForbiddenModuleAddressSet()
        XCTAssertTrue(policy.contains("thor1v8ppstuf6e3x0r4glqc68d5jqcs2tf38cg2q6y"))
        XCTAssertFalse(policy.contains("thor1x0jkvqdh2hlpeztd5zyyk70n3efx6mhudkmnn2"))
    }
}
