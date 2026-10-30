import XCTest
@testable import Sidekey

/// T-PH-1 的预算部分 (§4.1.1 外屏空间预算): 窄屏留白 12, 每格宽不比现在的 iPhone 窄。
final class PhoneMetricsTests: XCTestCase {
    func testNarrowOuterScreenUses12Padding() {
        let m = PhoneMetrics.portrait(width: 382)            // Duo 外屏可用容器宽
        XCTAssertEqual(m.hPadding, 12)
        XCTAssertGreaterThanOrEqual(m.cellWidth(totalWidth: 382, columns: 12), 22.5 - 0.05)
    }

    func testRegularPhonesKeep20Padding() {
        XCTAssertEqual(PhoneMetrics.portrait(width: 393).hPadding, 20)   // iPhone 17
        XCTAssertEqual(PhoneMetrics.portrait(width: 402).hPadding, 20)   // iPhone 17 Pro
        XCTAssertEqual(PhoneMetrics.portrait(width: 390).hPadding, 20)   // 边界: 不窄
    }

    func testCellWidthNeverBelowMinimum20() {
        // 外屏 382 + 留白 12 → 22.5; 按旧留白 20 只有 21.2, 都 ≥ 20
        XCTAssertGreaterThanOrEqual(PhoneMetrics.portrait(width: 382).cellWidth(totalWidth: 382, columns: 12), 20)
    }
}
