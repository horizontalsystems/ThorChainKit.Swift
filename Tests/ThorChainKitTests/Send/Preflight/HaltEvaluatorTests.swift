@testable import ThorChainKit
import XCTest

final class HaltEvaluatorTests: XCTestCase {
    func testUnsetMimirValuesAreInactive() throws {
        let snapshot = MimirSnapshot(
            haltChainGlobal: -1,
            nodePauseChainGlobal: -1,
            haltNativeChain: 0,
            solvencyHaltNativeChain: -1
        )
        XCTAssertEqual(try HaltEvaluator.evaluate(height: 100, mimir: snapshot), .allowed)
    }

    func testBoundariesUseThePinnedHeight() {
        let snapshot = MimirSnapshot(
            haltChainGlobal: 100,
            nodePauseChainGlobal: -1,
            haltNativeChain: -1,
            solvencyHaltNativeChain: -1
        )
        XCTAssertEqual(try? HaltEvaluator.evaluate(height: 99, mimir: snapshot), .allowed)
        XCTAssertEqual(try? HaltEvaluator.evaluate(height: 100, mimir: snapshot), .halted)
        XCTAssertEqual(try? HaltEvaluator.evaluate(height: 101, mimir: snapshot), .halted)
    }

    func testEveryHaltKeyUsesAllPinnedHeightBoundaries() throws {
        let h: Int64 = 100
        let rules: [(String, (Int64) -> MimirSnapshot, (Int64) -> Bool)] = [
            ("global", { value in MimirSnapshot(haltChainGlobal: value, nodePauseChainGlobal: -1, haltNativeChain: -1, solvencyHaltNativeChain: -1) }, { $0 <= h }),
            ("pause", { value in MimirSnapshot(haltChainGlobal: -1, nodePauseChainGlobal: value, haltNativeChain: -1, solvencyHaltNativeChain: -1) }, { $0 >= h }),
            ("thor", { value in MimirSnapshot(haltChainGlobal: -1, nodePauseChainGlobal: -1, haltNativeChain: value, solvencyHaltNativeChain: -1) }, { $0 <= h }),
            ("solvency", { value in MimirSnapshot(haltChainGlobal: -1, nodePauseChainGlobal: -1, haltNativeChain: -1, solvencyHaltNativeChain: value) }, { $0 <= h }),
        ]
        for (name, make, isHalted) in rules {
            for value in [h - 1, h, h + 1] {
                let decision = try HaltEvaluator.evaluate(height: h, mimir: make(value))
                XCTAssertEqual(decision, isHalted(value) ? .halted : .allowed, name)
            }
        }
        XCTAssertEqual(try HaltEvaluator.evaluate(height: h, mimir: MimirSnapshot(haltChainGlobal: -1, nodePauseChainGlobal: -1, haltNativeChain: -1, solvencyHaltNativeChain: -1)), .allowed)
        XCTAssertThrowsError(try HaltEvaluator.evaluate(height: h, mimir: MimirSnapshot(haltChainGlobal: -2, nodePauseChainGlobal: -1, haltNativeChain: -1, solvencyHaltNativeChain: -1)))
    }
}
