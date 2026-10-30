import XCTest
@testable import Sidekey

/// T-GEN-2: §3.6 切分算法 —— 一定能切完、切线不穿过任何键、超高子页被正确标记。
final class SubpageSplitterTests: XCTestCase {
    private func key(_ row: Int, _ span: Int = 1, col: Int = 0) -> KeyCap { KeyCap(label: "k", col: col, row: row, rowSpan: span) }

    /// 通用不变量: 覆盖 [0,total) 且不重叠; 没有键跨过任何一条切线。
    private func assertInvariants(_ pages: [Subpage], keys: [KeyCap], total: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(pages.first?.rows.lowerBound, 0, file: file, line: line)
        XCTAssertEqual(pages.last?.rows.upperBound, total, file: file, line: line)
        for (a, b) in zip(pages, pages.dropFirst()) { XCTAssertEqual(a.rows.upperBound, b.rows.lowerBound, "子页必须首尾相接", file: file, line: line) }
        for p in pages {
            XCTAssertGreaterThan(p.rows.count, 0, "每一步至少前进一行", file: file, line: line)
            for k in keys where k.row < p.rows.upperBound && p.rows.upperBound < k.row + k.rowSpan {
                XCTFail("切线 \(p.rows.upperBound) 穿过了键 row=\(k.row) span=\(k.rowSpan)", file: file, line: line)
            }
        }
    }

    func testPlainRows() {
        let keys = (0..<7).map { key($0) }
        let pages = SubpageSplitter.split(keys: keys, totalRows: 7, maxRows: 4)
        XCTAssertEqual(pages.map(\.rows), [0..<4, 4..<7])
        XCTAssertTrue(pages.allSatisfy { !$0.isTall })
        assertInvariants(pages, keys: keys, total: 7)
    }

    func testFitsInOnePage() {
        let keys = (0..<3).map { key($0) }
        XCTAssertEqual(SubpageSplitter.split(keys: keys, totalRows: 3, maxRows: 4).map(\.rows), [0..<3])
    }

    // 跨行键: 切线要前移, 不穿过键。
    func testSpanningKeyMovesTheCut() {
        let keys = [key(0), key(1), key(2, 2), key(4)]       // 键在第 2–3 行
        let pages = SubpageSplitter.split(keys: keys, totalRows: 5, maxRows: 3)
        XCTAssertEqual(pages.map(\.rows), [0..<2, 2..<5])    // 先切在 3 → 穿过 → 提前到 2
        assertInvariants(pages, keys: keys, total: 5)
    }

    // 一个键本身就高于 N 行: 单独成超高子页。
    func testKeyTallerThanN() {
        let keys = [key(0), key(1, 5), key(6)]
        let pages = SubpageSplitter.split(keys: keys, totalRows: 7, maxRows: 4)
        XCTAssertEqual(pages.map(\.rows), [0..<1, 1..<6, 6..<7])
        XCTAssertEqual(pages.map(\.isTall), [false, true, false])
        assertInvariants(pages, keys: keys, total: 7)
    }

    // 一组交错、互相卡住的跨行键: 整组成一个超高子页。
    func testInterlockedSpanningKeys() {
        let keys = [key(0, 3, col: 0), key(1, 3, col: 1), key(4)]
        let pages = SubpageSplitter.split(keys: keys, totalRows: 5, maxRows: 2)
        XCTAssertEqual(pages.map(\.rows), [0..<4, 4..<5])
        XCTAssertTrue(pages[0].isTall)
        assertInvariants(pages, keys: keys, total: 5)
    }

    func testNEqualsOne() {
        let keys = [key(0), key(1, 2), key(3)]
        let pages = SubpageSplitter.split(keys: keys, totalRows: 4, maxRows: 1)
        XCTAssertEqual(pages.map(\.rows), [0..<1, 1..<3, 3..<4])
        XCTAssertEqual(pages.map(\.isTall), [false, true, false])
        assertInvariants(pages, keys: keys, total: 4)
        // N <= 0 也按 1 处理
        XCTAssertEqual(SubpageSplitter.split(keys: keys, totalRows: 4, maxRows: 0).map(\.rows), pages.map(\.rows))
    }

    func testEmptyPage() { XCTAssertTrue(SubpageSplitter.split(keys: [], totalRows: 0, maxRows: 4).isEmpty) }

    func testRowsThatFit() {
        XCTAssertEqual(SubpageSplitter.rowsThatFit(height: 184), 4)     // 4 × 40 + 3 × 8
        XCTAssertEqual(SubpageSplitter.rowsThatFit(height: 183), 3)
        XCTAssertEqual(SubpageSplitter.rowsThatFit(height: 39), 0)
        XCTAssertEqual(SubpageSplitter.rowsThatFit(height: 40), 1)
    }

    // 超高子页: 刚好放下 (5 行放进 184 → 30.4), 28 pt 只是下限; 再放不下滚动。
    func testTallRowHeight() {
        let r = SubpageSplitter.tallRowHeight(rows: 5, availableHeight: 184)
        XCTAssertEqual(r.rowHeight, 30.4, accuracy: 0.001)
        XCTAssertFalse(r.scrolls)
        let s = SubpageSplitter.tallRowHeight(rows: 8, availableHeight: 184)
        XCTAssertEqual(s.rowHeight, 28)
        XCTAssertTrue(s.scrolls)
    }

    func testSubpageIndexContainingRow() {
        let pages = [Subpage(rows: 0..<4, isTall: false), Subpage(rows: 4..<7, isTall: false)]
        XCTAssertEqual(SubpageSplitter.subpageIndex(containingRow: 5, in: pages), 1)
        XCTAssertEqual(SubpageSplitter.subpageIndex(containingRow: 99, in: pages), 0, "找不到回第 1 个")
    }

    func testKeysInSubpageAreRenumbered() {
        let keys = [key(0), key(2), key(3, 1, col: 2)]
        let sub = SubpageSplitter.keys(in: Subpage(rows: 2..<4, isTall: false), from: keys)
        XCTAssertEqual(sub.map(\.row), [0, 1])
    }
}
