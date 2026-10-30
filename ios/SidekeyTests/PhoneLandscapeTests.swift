import XCTest
@testable import Sidekey

/// T-PH-2 / T-PH-3 的纯计算部分 (§4.1.2, v1.7): 横屏三种情况 + B 类单区回退。
final class PhoneLandscapeTests: XCTestCase {
    private var vibe: KeyLayer { BuiltinModes.vibe().layers[0] }
    private var micro: KeyLayer { BuiltinModes.codexMicro().layers[0] }
    private var typingKbd: KeyLayer { BuiltinModes.vibecodingKbd().layers[0] }

    private func plan(_ l: KeyLayer, h: CGFloat, zone: SingleZone = .keys) -> PhoneLandscapePlan {
        PhoneLandscape.plan(keys: l.keys, columns: l.columns, rowCount: l.rowCount, availableHeight: h, zone: zone)
    }

    // MARK: 分类
    func testClassification() {
        XCTAssertEqual(PhoneLandscape.classify(keys: vibe.keys, columns: vibe.columns), .wholeRowTrackpad)
        XCTAssertEqual(PhoneLandscape.classify(keys: micro.keys, columns: micro.columns), .mixed)
        XCTAssertEqual(PhoneLandscape.classify(keys: typingKbd.keys, columns: typingKbd.columns), .noTrackpad)
    }

    // 触控板没占满整行, 或有别的键和这些行相交 → 混排。
    func testNotWholeRowIsMixed() {
        let half = [KeyCap(label: "t", col: 0, row: 0, colSpan: 6, rowSpan: 3, kind: .trackpad)]
        XCTAssertEqual(PhoneLandscape.classify(keys: half, columns: 12), .mixed)
        let intersect = [KeyCap(label: "t", col: 0, row: 0, colSpan: 12, rowSpan: 3, kind: .trackpad),
                         KeyCap(label: "k", col: 0, row: 2)]
        XCTAssertEqual(PhoneLandscape.classify(keys: intersect, columns: 12), .mixed)
    }

    // MARK: B 正常 (按键行 40 固定, 触控板占剩余, 例: 可用 360 → 触控板 360 − 96 = 264)
    func testVibeStackedTrackpadGetsRemainingHeight() {
        let p = plan(vibe, h: 360)
        XCTAssertEqual(p.kind, .wholeRowTrackpad)
        XCTAssertEqual(p.trackpadHeight, 264)
        XCTAssertFalse(p.needsZoneToggle)
        guard case .stacked(let blocks) = p.presentation else { return XCTFail("应是 stacked") }
        XCTAssertEqual(blocks.map(\.kind), [.trackpad, .keys(5..<7)])
        XCTAssertEqual(blocks[1].height, 88, "2 行 × 40 + 8")
        // 总高 = 触控板 + 行距 8 + 按键块, 正好等于可用高度
        XCTAssertEqual(blocks.map(\.height).reduce(0, +) + 8, 360)
    }

    func testVibeExactly80TrackpadStillStacked() {
        XCTAssertEqual(plan(vibe, h: 176).trackpadHeight, 80)          // 176 − 96
        guard case .stacked = plan(vibe, h: 176).presentation else { return XCTFail() }
    }

    // MARK: B 单区回退 (§3.5): 触控板不到 80 → 进单区, 只改显示
    func testVibeFallsBackToSingleZoneBelow80() {
        let keysOnly = plan(vibe, h: 170, zone: .keys)
        XCTAssertEqual(keysOnly.presentation, .keysOnly)
        XCTAssertTrue(keysOnly.needsZoneToggle)
        XCTAssertEqual(keysOnly.rowCount, 2, "去掉触控板的 5 行, 剩 2 行")
        XCTAssertEqual(keysOnly.keys.map(\.row).sorted(), [0, 0, 0, 1, 1, 1], "行号按顺序重排")
        XCTAssertFalse(keysOnly.keys.contains { $0.kind == .trackpad })
        XCTAssertEqual(keysOnly.subpages.map(\.rows), [0..<2])

        let trackpadOnly = plan(vibe, h: 170, zone: .trackpad)
        XCTAssertEqual(trackpadOnly.presentation, .trackpadOnly)
        XCTAssertTrue(trackpadOnly.needsZoneToggle, "「键盘 / 触控板」切换一直在侧栏里")
        XCTAssertEqual(trackpadOnly.mouseButtons.map(\.code), ["left", "right"], "左右键一起显示 (缺的补上)")
        XCTAssertEqual(vibe.keys.filter { $0.kind == .trackpad }.count, 1, "只改显示, 不改存档的键")
    }

    // 高密度 B 类: 触控板上下都有键、有跨行键。去掉触控板行后顺序 / 列 / 跨度不变, 行号重排, 再切子页。
    func testHighDensityBSingleZoneKeysOnly() {
        let keys: [KeyCap] = [
            KeyCap(label: "a", col: 0, row: 0, colSpan: 3),
            KeyCap(label: "b", col: 3, row: 0, colSpan: 3, rowSpan: 2),       // 跨行键 (第 0–1 行)
            KeyCap(label: "c", col: 0, row: 1, colSpan: 3),
            KeyCap(label: "tp", col: 0, row: 2, colSpan: 6, rowSpan: 2, kind: .trackpad),
            KeyCap(label: "d", col: 0, row: 4, colSpan: 2),
            KeyCap(label: "e", col: 2, row: 4, colSpan: 2, rowSpan: 3),       // 跨行键 (第 4–6 行)
            KeyCap(label: "f", col: 0, row: 5, colSpan: 2),
            KeyCap(label: "g", col: 0, row: 6, colSpan: 2),
        ]
        let p = PhoneLandscape.plan(keys: keys, columns: 6, rowCount: 7, availableHeight: 150, zone: .keys)
        XCTAssertEqual(p.kind, .wholeRowTrackpad)
        XCTAssertEqual(p.presentation, .keysOnly)                              // 7 − 2 = 5 行 × 48 = 240 > 150 − 80 ...
        XCTAssertEqual(p.rowCount, 5)
        let byLabel = Dictionary(uniqueKeysWithValues: p.keys.map { ($0.label, $0) })
        XCTAssertEqual(byLabel["a"]?.row, 0); XCTAssertEqual(byLabel["b"]?.row, 0); XCTAssertEqual(byLabel["c"]?.row, 1)
        XCTAssertEqual(byLabel["d"]?.row, 2); XCTAssertEqual(byLabel["e"]?.row, 2); XCTAssertEqual(byLabel["e"]?.rowSpan, 3)
        XCTAssertEqual(byLabel["e"]?.col, 2); XCTAssertEqual(byLabel["e"]?.colSpan, 2, "列位置和跨度不变")
        XCTAssertEqual(byLabel["g"]?.row, 4)
        // 150 pt 放得下 3 行 (3 × 48 − 8 = 136); 5 行切成子页, 切线不穿过跨行键
        XCTAssertGreaterThan(p.subpages.count, 1)
        XCTAssertTrue(p.hasSubpageDots)
        for s in p.subpages {
            for k in p.keys where k.row < s.rows.upperBound && s.rows.upperBound < k.row + k.rowSpan { XCTFail("切线穿过键 \(k.label)") }
        }
    }

    // 触控板在中间 (上下都有按键行): 正常堆叠时顺序保持。
    func testStackedKeepsOrderAroundTrackpad() {
        let keys: [KeyCap] = [
            KeyCap(label: "a", col: 0, row: 0, colSpan: 4),
            KeyCap(label: "tp", col: 0, row: 1, colSpan: 4, rowSpan: 2, kind: .trackpad),
            KeyCap(label: "b", col: 0, row: 3, colSpan: 4),
        ]
        let p = PhoneLandscape.plan(keys: keys, columns: 4, rowCount: 4, availableHeight: 300)
        guard case .stacked(let blocks) = p.presentation else { return XCTFail() }
        XCTAssertEqual(blocks.map(\.kind), [.keys(0..<1), .trackpad, .keys(3..<4)])
        XCTAssertEqual(p.trackpadHeight, 300 - 2 * 48)
    }

    // MARK: A / C: 整页网格, 行高 < 40 时切子页; 触控板格子当普通格子。
    func testNoTrackpadFitsOnePage() {
        let p = plan(typingKbd, h: 360)
        XCTAssertEqual(p.presentation, .grid)
        XCTAssertEqual(p.subpages.count, 1)
        XCTAssertFalse(p.needsZoneToggle)
    }

    func testNoTrackpadSplitsWhenTooTall() {
        let p = plan(typingKbd, h: 120)                                        // 放得下 2 行
        XCTAssertEqual(p.presentation, .grid)
        XCTAssertGreaterThan(p.subpages.count, 1)
        XCTAssertTrue(p.subpages.dropLast().allSatisfy { $0.rows.count <= 2 })
    }

    func testMixedCodexMicroKeepsTrackpadCellInGrid() {
        let p = plan(micro, h: 360)
        XCTAssertEqual(p.kind, .mixed)
        XCTAssertEqual(p.presentation, .grid)
        XCTAssertTrue(p.keys.contains { $0.kind == .trackpad }, "触控板格子保留在原位置")
        XCTAssertEqual(p.subpages.map(\.rows), [0..<4])
        let tight = plan(micro, h: 130)                                        // 放得下 2 行 → 两个子页, 只能点圆点翻
        XCTAssertEqual(tight.subpages.map(\.rows), [0..<2, 2..<4])
        XCTAssertTrue(tight.hasSubpageDots)
    }

    // MARK: 审计: 宽度回退 (§3.5, 每格 ≥ 20 pt 不降)
    private func wideLayer(columns: Int) -> KeyLayer {
        KeyLayer(id: "base", columns: columns, keys: (0..<columns).map { KeyCap(label: "k", col: $0, row: 0) })
    }

    func testMinGridWidth() {
        XCTAssertEqual(PhoneLandscape.minGridWidth(columns: 12), 12 * 20 + 11 * 8)    // 328
        XCTAssertEqual(PhoneLandscape.minGridWidth(columns: 16), 440)
    }

    func testSideBarNarrowsBeforeGivingUp() {
        // 16 列要 440; 容器 560: 侧栏 60 → 剩 440 刚好够
        XCTAssertEqual(PhoneLandscape.sideBarWidth(containerWidth: 560, columns: 16), 60)
        // 容器 540: 60 不够 (420 < 440), 收窄到 48 (剩 444) 才够
        XCTAssertEqual(PhoneLandscape.sideBarWidth(containerWidth: 540, columns: 16), 48)
    }

    func testSixteenColumnsTooNarrowShowsPlaceholderNotSmallKeys() {
        let l = wideLayer(columns: 16)
        let p = PhoneLandscape.plan(keys: l.keys, columns: 16, rowCount: 1, availableHeight: 300, availableWidth: 360)
        XCTAssertEqual(p.presentation, .tooNarrow(required: 440, trackpadAvailable: false), "没有触控板的页: 占位里不能提示「切到触控板」")
        XCTAssertFalse(p.needsZoneToggle, "没有触控板的页: 只有占位, 没有切换")
        let ok = PhoneLandscape.plan(keys: l.keys, columns: 16, rowCount: 1, availableHeight: 300, availableWidth: 440)
        XCTAssertEqual(ok.presentation, .grid, "刚好够: 正常显示")
    }

    func testTooNarrowWithTrackpadOffersSwitchToTrackpad() {
        var keys = (0..<15).map { KeyCap(label: "k", col: $0, row: 1) }
        keys.append(KeyCap(label: "t", col: 0, row: 0, colSpan: 16, kind: .trackpad))
        keys.append(KeyCap(label: "k", col: 15, row: 1))
        let narrow = PhoneLandscape.plan(keys: keys, columns: 16, rowCount: 2, availableHeight: 300, availableWidth: 300)
        XCTAssertEqual(narrow.presentation, .tooNarrow(required: 440, trackpadAvailable: true))
        XCTAssertTrue(narrow.needsZoneToggle, "切到触控板的入口一直在")
        let tp = PhoneLandscape.plan(keys: keys, columns: 16, rowCount: 2, availableHeight: 300, availableWidth: 300, zone: .trackpad)
        XCTAssertEqual(tp.presentation, .trackpadOnly)
        XCTAssertEqual(tp.mouseButtons.map(\.code), ["left", "right"])
    }

    func testTwelveColumnsFitOnTypicalPhoneLandscape() {
        // iPhone 17 Pro 横屏安全区内约 800 宽: 12 列没问题
        let p = PhoneLandscape.plan(keys: vibe.keys, columns: 12, rowCount: vibe.rowCount, availableHeight: 360, availableWidth: 680)
        guard case .stacked = p.presentation else { return XCTFail() }
    }

    // Q17 实测 (2026-10-26, Duo 外屏横屏, iOS 27.1 模拟器): 屏幕 678 × 466, 安全区 上0/左0/下34/右84 (另一个横向相反: 左84/右0),
    // 容器 594 × 432, 状态栏占 84 × 82 并带 37 × 37 摄像头遮挡区, size class compact / compact。布局只读运行时安全区, 这里只核对用实测值时的预算。
    func testDuoOuterLandscapeMeasuredBudget() {
        let container = CGSize(width: 594, height: 432)
        let side = PhoneLandscape.sideBarWidth(containerWidth: container.width, columns: 12)
        XCTAssertEqual(side, 60, "12 列: 不需要收窄侧栏 (594 − 120 = 474 ≥ 328)")
        let availH = container.height - 16
        let p = PhoneLandscape.plan(keys: vibe.keys, columns: 12, rowCount: vibe.rowCount, availableHeight: availH,
                                    availableWidth: container.width - 2 * side)
        XCTAssertEqual(p.trackpadHeight, availH - 96, "Vibe: 触控板 = 416 − 96 = 320, 远大于 80")
        guard case .stacked = p.presentation else { return XCTFail("外屏横屏 Vibe 不需要单区") }
        // Codex Micro (4 列 4 行): 一页放得下, 不需要子页
        let m = PhoneLandscape.plan(keys: micro.keys, columns: 4, rowCount: 4, availableHeight: availH, availableWidth: container.width - 2 * side)
        XCTAssertEqual(m.subpages.count, 1)
    }

    // 「只显示触控板」放不下 160 宽 / 80 高的触控板 (加上鼠标键行) 时不压缩, 改占位 (侧栏仍可切回键盘)。
    func testTrackpadOnlyHasFloorOtherwisePlaceholder() {
        let tooShort = PhoneLandscape.plan(keys: vibe.keys, columns: vibe.columns, rowCount: vibe.rowCount, availableHeight: 130, zone: .trackpad)
        XCTAssertEqual(tooShort.presentation, .tooSmallForTrackpad(minWidth: 160, minHeight: 144))
        XCTAssertTrue(tooShort.needsZoneToggle, "切回键盘的入口一直在")
        let exact = PhoneLandscape.plan(keys: vibe.keys, columns: vibe.columns, rowCount: vibe.rowCount, availableHeight: 144, zone: .trackpad)
        XCTAssertEqual(exact.presentation, .trackpadOnly); XCTAssertEqual(exact.trackpadHeight, 80)
        let tooNarrowTP = PhoneLandscape.plan(keys: vibe.keys, columns: vibe.columns, rowCount: vibe.rowCount, availableHeight: 300, availableWidth: 150, zone: .trackpad)
        XCTAssertEqual(tooNarrowTP.presentation, .tooSmallForTrackpad(minWidth: 160, minHeight: 144))
        let ok = PhoneLandscape.plan(keys: vibe.keys, columns: vibe.columns, rowCount: vibe.rowCount, availableHeight: 300, availableWidth: 160, zone: .trackpad)
        XCTAssertEqual(ok.presentation, .trackpadOnly)
    }
}
