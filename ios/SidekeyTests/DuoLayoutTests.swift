import XCTest
@testable import Sidekey

/// M3a: 层 3 DuoLayout (§3.3–3.7) 和层 2 LayoutStabilizer 的单测。
/// 观测数据取自 M0 实测 (m0/README.md「M3 前置实测」, 坐标已换算到窗口坐标), 期望值取自 UI 稿 ui-v1 (README「实际尺寸」表、画板 03 / 04 / 09)。
final class DuoLayoutTests: XCTestCase {

    // MARK: - 观测样本 (M0 实测)

    /// 竖向全开: 669 × 951, 折痕横向 y 455.5…495.5 (非激活), 摄像头在右侧折痕下方, 状态栏角 (激活)。
    static func portrait(statusBar: Bool = true, hinge: DuoHinge = .fullyOpen, active: Bool = false) -> DuoObservation {
        var regions = [DuoRegion(kind: .division, frame: CGRect(x: 0, y: 455.5, width: 669, height: 40), isActive: active),
                       DuoRegion(kind: .occlusion, frame: CGRect(x: 611, y: 677.3, width: 37, height: 58), isActive: false)]
        if statusBar { regions.append(DuoRegion(kind: .occlusion, frame: CGRect(x: 535, y: 0, width: 134, height: 82), isActive: true)) }
        return DuoObservation(screen: .inner, window: CGSize(width: 669, height: 951),
                              safe: DuoInsets(top: statusBar ? 82 : 0, left: 0, bottom: 34, right: 0), regions: regions, hinge: hinge)
    }

    /// 横向全开: 951 × 669, 折痕竖向 x 455.5…495.5, 摄像头在顶部偏右, 状态栏在右侧 (安全区 r84)。
    static func landscape(statusBar: Bool = true, hinge: DuoHinge = .fullyOpen, active: Bool = false) -> DuoObservation {
        var regions = [DuoRegion(kind: .division, frame: CGRect(x: 455.5, y: 0, width: 40, height: 669), isActive: active),
                       DuoRegion(kind: .occlusion, frame: CGRect(x: 677.3, y: 21, width: 58, height: 37), isActive: false)]
        if statusBar { regions.append(DuoRegion(kind: .occlusion, frame: CGRect(x: 867, y: 0, width: 84, height: 120), isActive: true)) }
        return DuoObservation(screen: .inner, window: CGSize(width: 951, height: 669),
                              safe: DuoInsets(top: 0, left: 0, bottom: 34, right: statusBar ? 84 : 0), regions: regions, hinge: hinge)
    }

    /// Split View 左窗口 (M0 实测): 469 × 669, 折痕被裁成右边缘 13.5 pt。
    static let splitLeft = DuoObservation(screen: .inner, window: CGSize(width: 469, height: 669),
                                          safe: DuoInsets(top: 0, left: 0, bottom: 34, right: 0),
                                          regions: [DuoRegion(kind: .division, frame: CGRect(x: 455.5, y: 0, width: 13.5, height: 669), isActive: false)],
                                          hinge: .fullyOpen)
    /// Split View 右窗口 (UI 稿 09A): 469 宽, 左边缘 13.5 避让, 右侧状态栏安全区 84。
    static let splitRight = DuoObservation(screen: .inner, window: CGSize(width: 469, height: 669),
                                           safe: DuoInsets(top: 0, left: 0, bottom: 34, right: 84),
                                           regions: [DuoRegion(kind: .division, frame: CGRect(x: 0, y: 0, width: 13.5, height: 669), isActive: false)],
                                           hinge: .fullyOpen)

    static func page(columns: Int = 12, rows: Int = 6, pages: Int = 2) -> DuoPageInfo {
        let keys = (0..<rows).map { KeyCap(label: "K\($0)", code: "a", col: 0, row: $0) }
        return DuoPageInfo(columns: columns, rowCount: rows, keys: keys, pageCount: pages)
    }

    private func assertRect(_ r: CGRect?, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
                            _ msg: String = "", file: StaticString = #filePath, line: UInt = #line) {
        guard let r else { return XCTFail("nil rect \(msg)", file: file, line: line) }
        XCTAssertEqual(r.minX, x, accuracy: 0.01, "x \(msg)", file: file, line: line)
        XCTAssertEqual(r.minY, y, accuracy: 0.01, "y \(msg)", file: file, line: line)
        XCTAssertEqual(r.width, w, accuracy: 0.01, "w \(msg)", file: file, line: line)
        XCTAssertEqual(r.height, h, accuracy: 0.01, "h \(msg)", file: file, line: line)
    }

    // MARK: - §3.3 折痕分类

    func testClassifyInternalVsEdge() {
        XCTAssertNotNil(DuoLayout.classify(Self.landscape()).internalDivision)
        let left = DuoLayout.classify(Self.splitLeft)
        XCTAssertNil(left.internalDivision, "被窗口截断的 13.5 pt 是边缘避让, 不算横贯")
        XCTAssertEqual(left.edgeAvoid.count, 1)
        let c = DuoLayout.classify(Self.landscape())
        XCTAssertEqual(c.camera.count, 1, "非激活的 occlusion = 摄像头")
        XCTAssertEqual(c.activeOcclusion.count, 1)
    }

    func testPhoneScreenDropsDivisionsAndDisjointRegions() {
        // 合上时外屏头几帧还带着内屏的 division (坐标系不对, §3.8 第 1 条)
        let stale = DuoObservation(screen: .phone, window: CGSize(width: 678, height: 466), safe: DuoInsets(left: 84, bottom: 34),
                                   regions: [DuoRegion(kind: .division, frame: CGRect(x: -84, y: 455.5, width: 669, height: 40), isActive: true),
                                             DuoRegion(kind: .occlusion, frame: CGRect(x: 2000, y: 0, width: 10, height: 10), isActive: true),
                                             DuoRegion(kind: .occlusion, frame: CGRect(x: 29.3, y: 29.3, width: 37, height: 37), isActive: true)],
                                   hinge: .closed)
        let n = stale.normalized()
        XCTAssertEqual(n.regions.count, 1)
        XCTAssertEqual(n.regions.first?.kind, .occlusion)
    }

    // MARK: - §4.2 竖向全开 (UI 稿 03)

    func testPortraitMatchesBoard03() {
        let p = DuoLayout.plan(Self.portrait(), page: Self.page(), swapped: false)
        XCTAssertEqual(p.arrangement, .stacked); XCTAssertEqual(p.divider, .inactiveCrease); XCTAssertEqual(p.posture, .flat)
        XCTAssertEqual(p.content, .dual); XCTAssertFalse(p.isNarrow); XCTAssertTrue(p.swapAvailable)
        assertRect(p.topBar, 20, 94, 629, 44)
        assertRect(p.keyboard, 20, 150, 629, 301.5, "README: 内屏竖向键盘区 629 × 301.5")
        assertRect(p.pagerRow, 20, 150, 629, 44)
        assertRect(p.grid, 20, 202, 629, 249.5)
        assertRect(p.trackpad, 20, 499.5, 629, 333.5, "README: 触控板 629 × 333.5")
        assertRect(p.bottomRow, 20, 841, 629, 64)
        assertRect(p.dock, 449, 841, 200, 64)
        assertRect(p.mouseRow, 20, 841, 421, 64)
        XCTAssertEqual(p.rowsFit, 5)
    }

    func testPortraitStatusBarHiddenGivesBackTop() {
        let p = DuoLayout.plan(Self.portrait(statusBar: false), page: Self.page(), swapped: false)
        assertRect(p.topBar, 20, 12, 629, 44)
        assertRect(p.keyboard, 20, 68, 629, 383.5)
    }

    func testPortraitSwappedMovesMouseRowWithTrackpadAndKeysAvoidCamera() {
        let p = DuoLayout.plan(Self.portrait(), page: Self.page(), swapped: true)
        assertRect(p.trackpad, 20, 150, 629, 237.5)
        assertRect(p.mouseRow, 20, 395.5, 629, 56, "鼠标键行紧贴触控板下沿, 在折痕间距之外")
        assertRect(p.keyboard, 20, 499.5, 629, 333.5)
        assertRect(p.dock, 449, 841, 200, 64, "竖向时胶囊不随调换移动")
        // 摄像头 (611, 677.3, 37 × 58) 落在下半部: 网格横向让开, 留 8 pt
        XCTAssertEqual(p.grid!.maxX, 603, accuracy: 0.01)
        XCTAssertFalse(p.grid!.intersects(p.camera[0]))
        XCTAssertFalse(p.pagerRow!.intersects(p.camera[0].insetBy(dx: -8, dy: -8)))
    }

    // MARK: - §4.3 横向全开 (UI 稿 04)

    func testLandscapeMatchesBoard04() {
        let p = DuoLayout.plan(Self.landscape(), page: Self.page(), swapped: false)
        XCTAssertEqual(p.arrangement, .sideBySide)
        assertRect(p.topBar, 20, 12, 835, 44, "右侧贴安全区: 边距 12")
        assertRect(p.keyboard, 20, 68, 431.5, 483, "README: 431.5 × 483")
        assertRect(p.trackpad, 499.5, 68, 355.5, 483, "README: 355.5 × 483")
        assertRect(p.dock, 20, 559, 200, 64)
        assertRect(p.mouseRow, 499.5, 559, 355.5, 64)
        XCTAssertEqual(p.topBarAvoid.count, 1, "摄像头落在顶栏这一行: 顶栏控件要避开")
    }

    func testLandscapeSwappedMirrorsZonesAndAttachments() {
        let p = DuoLayout.plan(Self.landscape(), page: Self.page(), swapped: true)
        assertRect(p.trackpad, 20, 68, 431.5, 483)
        assertRect(p.keyboard, 499.5, 68, 355.5, 483)
        assertRect(p.dock, 499.5, 559, 200, 64, "横向时胶囊跟着键盘")
        assertRect(p.mouseRow, 20, 559, 431.5, 64)
    }

    func testBookPostureUsesActiveFrameWithoutExtraGap() {
        let p = DuoLayout.plan(Self.landscape(hinge: .partiallyOpen, active: true), page: Self.page(), swapped: false)
        XCTAssertEqual(p.posture, .book); XCTAssertEqual(p.divider, .activeCrease); XCTAssertTrue(p.swapAvailable)
        XCTAssertEqual(p.keyboard!.maxX, 455.5, accuracy: 0.01, "§3.3: 激活时按系统 frame 避让, 不另外加")
        XCTAssertEqual(p.trackpad!.minX, 495.5, accuracy: 0.01)
    }

    func testLaptopPostureHidesSwap() {
        let p = DuoLayout.plan(Self.portrait(statusBar: false, hinge: .partiallyOpen, active: true), page: Self.page(), swapped: false)
        XCTAssertEqual(p.posture, .laptop)
        XCTAssertFalse(p.swapAvailable, "笔记本姿势不显示调换键 (§4.4); 信息屏排法在 M4")
    }

    // MARK: - T-UN-1: 没有按键或触控板压在折痕两侧各 24 pt 里

    func testNothingInsideCreaseGap() {
        for obs in [Self.portrait(), Self.portrait(statusBar: false), Self.landscape(), Self.landscape(statusBar: false)] {
            for swapped in [false, true] {
                let p = DuoLayout.plan(obs, page: Self.page(), swapped: swapped)
                let d = DuoLayout.classify(obs).internalDivision!.frame
                let gapBand = d.height >= d.width
                    ? CGRect(x: d.midX - 24, y: 0, width: 48, height: obs.window.height)
                    : CGRect(x: 0, y: d.midY - 24, width: obs.window.width, height: 48)
                for r in [p.keyboard, p.grid, p.pagerRow, p.trackpad, p.mouseRow].compactMap({ $0 }) {
                    XCTAssertFalse(r.intersects(gapBand.insetBy(dx: 0.01, dy: 0.01)), "\(r) 压到折痕间距 swapped=\(swapped)")
                }
            }
        }
    }

    // MARK: - §3.3 窄窗口 (UI 稿 09; 没有内部分界)

    func testSplitLeftWindowNarrowStackedHalves() {
        let p = DuoLayout.plan(Self.splitLeft, page: Self.page(), swapped: false)
        XCTAssertTrue(p.isNarrow); XCTAssertEqual(p.divider, .none); XCTAssertEqual(p.arrangement, .stacked)
        assertRect(p.topBar, 12, 12, 431.5, 44, "UI 稿 09B: 内容宽 431.5")
        assertRect(p.grid, 12, 120, 431.5, 195.5)
        assertRect(p.trackpad, 12, 363.5, 431.5, 195.5)
        assertRect(p.bottomRow, 12, 567, 431.5, 56)
        assertRect(p.dock, 311.5, 567, 132, 56)
        XCTAssertEqual(p.edgeAvoid.count, 1)
    }

    func testSplitRightWindowMatchesBoard09BeforeAndAfterSwap() {
        let before = DuoLayout.plan(Self.splitRight, page: Self.page(), swapped: false)
        XCTAssertEqual(before.topBar.width, 347.5, accuracy: 0.01, "内容宽 347.5")
        XCTAssertEqual(before.grid!.height, 195.5, accuracy: 0.01)
        XCTAssertEqual(before.trackpad!.height, 195.5, accuracy: 0.01)
        let after = DuoLayout.plan(Self.splitRight, page: Self.page(), swapped: true)
        XCTAssertEqual(after.content, .dual)
        XCTAssertEqual(after.trackpad!.height, 163.5, accuracy: 0.01, "调换后两区各 163.5, 触控板 ≥ 160")
        XCTAssertEqual(after.grid!.height, 163.5, accuracy: 0.01)
        XCTAssertEqual(after.mouseRow!.minY, after.trackpad!.maxY + 8, accuracy: 0.01)
        XCTAssertEqual(after.rowsFit, 3)
        XCTAssertEqual(before.rowsFit, 4)
    }

    // MARK: - §3.6 子页

    func testSubpagesAndPagerRowForSinglePage() {
        // 只有 1 页、但 12 行: 先按没有分页行算 N, 切出子页后加上分页行重算
        let p = DuoLayout.plan(Self.landscape(), page: Self.page(rows: 12, pages: 1), swapped: false)
        XCTAssertNotNil(p.pagerRow, "有子页就要有分页行放子页圆点")
        XCTAssertEqual(p.rowsFit, 9)                       // (431 + 8) / 48
        XCTAssertEqual(p.subpages.map(\.rows), [0..<9, 9..<12])
        let q = DuoLayout.plan(Self.landscape(), page: Self.page(rows: 3, pages: 1), swapped: false)
        XCTAssertNil(q.pagerRow, "1 页、没有子页: 不要分页行")
    }

    // MARK: - §3.5 回退

    func testTooManyColumnsFallsBackToSingleThenTooNarrow() {
        // 20 列需要 552 宽: 横向两侧 (431.5 / 355.5) 都放不下 → 键盘单区也放不下 → 窗口太窄
        let kb = DuoLayout.plan(Self.landscape(), page: Self.page(columns: 20), swapped: false, singleChoice: .keys)
        XCTAssertEqual(kb.content, .tooNarrow(neededWidth: 552))
        XCTAssertFalse(kb.swapAvailable)
        // 切到触控板: 选面积大的一侧 (左, 431.5), 鼠标键一起显示且让开胶囊
        let tp = DuoLayout.plan(Self.landscape(), page: Self.page(columns: 20), swapped: false, singleChoice: .trackpad)
        XCTAssertEqual(tp.content, .single(.trackpad))
        XCTAssertEqual(tp.trackpad!.width, 431.5, accuracy: 0.01)
        XCTAssertFalse(tp.mouseRow!.intersects(tp.dock))
        XCTAssertFalse(tp.trackpad!.intersects(tp.dividerBand!), "单区不跨折痕")
    }

    func testSingleZoneKeyboardUsesWholeContentWithoutDivision() {
        // 窄窗口 16 列: 双区宽度够 (448 > 431.5? 不够) → 单区
        let p = DuoLayout.plan(Self.splitLeft, page: Self.page(columns: 16), swapped: false, singleChoice: .keys)
        XCTAssertEqual(p.content, .tooNarrow(neededWidth: 16 * 20 + 15 * 8))
        let q = DuoLayout.plan(Self.splitLeft, page: Self.page(columns: 14), swapped: false, singleChoice: .keys)
        // 14 列 = 384 ≤ 431.5: 双区就够
        XCTAssertEqual(q.content, .dual)
    }

    func testShortTrackpadFallsBackToSingle() {
        // 调换后窄窗口的触控板 163.5; 把底部安全区加大 10 → 触控板 < 160 → 单区
        var o = Self.splitRight
        o.safe.bottom += 10
        let p = DuoLayout.plan(o, page: Self.page(), swapped: true, singleChoice: .keys)
        XCTAssertEqual(p.content, .single(.keys))
        XCTAssertNil(p.trackpad)
        XCTAssertNotNil(p.grid)
    }

    // MARK: - 层 2 LayoutStabilizer

    func testStabilizerInterruptsImmediatelyAndAdoptsAfterSettle() {
        var s = LayoutStabilizer<String>(posture: { $0.hasPrefix("book") ? "book" : "flat" })
        XCTAssertNil(s.observe("a", at: 0)); XCTAssertEqual(s.stable, "a")
        XCTAssertEqual(s.observe("b", at: 1.0), .interruptNow, "§5.2 第 1–3 步立即执行")
        XCTAssertNil(s.observe("c", at: 1.05), "连续变化只算一次")
        XCTAssertNil(s.tick(at: 1.10))
        XCTAssertEqual(s.tick(at: 1.21), "c", "150 ms 内没有新变化 → 采用")
        XCTAssertFalse(s.isSettling)
    }

    func testStabilizerPostureChangeWaits300ms() {
        var s = LayoutStabilizer<String>(posture: { $0.hasPrefix("book") ? "book" : "flat" })
        _ = s.observe("flat", at: 0)
        XCTAssertEqual(s.observe("book1", at: 1.0), .interruptNow)
        XCTAssertNil(s.tick(at: 1.2), "姿态结论变了: 300 ms 防抖")
        XCTAssertEqual(s.tick(at: 1.31), "book1")
    }

    func testStabilizerFlapBackKeepsLayout() {
        var s = LayoutStabilizer<String>(posture: { _ in "flat" })
        _ = s.observe("a", at: 0)
        XCTAssertEqual(s.observe("transient", at: 1.0), .interruptNow)
        XCTAssertNil(s.observe("a", at: 1.05), "过渡帧又变回来")
        XCTAssertNil(s.tick(at: 1.25), "布局不变 (不触发重排)")
        XCTAssertEqual(s.stable, "a"); XCTAssertFalse(s.isSettling)
    }

    // 层 2 只比较影响布局的结果: 不碰任何区域的旧摄像头区不算变化; 碰到网格的算
    func testStableContextIgnoresRegionsThatDoNotChangeLayout() {
        let base = Self.landscape()
        var stale = base
        stale.regions.append(DuoRegion(kind: .occlusion, frame: CGRect(x: 460, y: 300, width: 20, height: 30), isActive: false))   // 落在折痕间距里: 调换前后都碰不到按键和控件
        XCTAssertEqual(DuoStableContext(base), DuoStableContext(stale))
        var s = LayoutStabilizer<DuoStableContext>(posture: { $0.posture })
        _ = s.observe(DuoStableContext(base), at: 0)
        XCTAssertNil(s.observe(DuoStableContext(stale), at: 1), "不影响布局: 不 interrupt")
        var hitsKeys = base
        hitsKeys.regions.append(DuoRegion(kind: .occlusion, frame: CGRect(x: 200, y: 300, width: 37, height: 37), isActive: false))   // 落在键盘网格里
        XCTAssertNotEqual(DuoStableContext(base), DuoStableContext(hitsKeys))
    }

    // §4.6 窄窗口顶栏: 电脑条宽 = W − 156 (双区) / W − 208 (单区), 最窄 120 → 双区 W ≥ 276、单区 W ≥ 328 才放得下全套
    func testNarrowTopBarFallbacks() {
        let a = DuoTopBarPlan.narrow(width: 347.5, single: false)
        XCTAssertTrue(a.showStatus); XCTAssertFalse(a.collapsedMenu); XCTAssertEqual(a.chipWidth, 191.5, accuracy: 0.01)
        XCTAssertEqual(DuoTopBarPlan.narrow(width: 347.5, single: true).chipWidth, 139.5, accuracy: 0.01)
        XCTAssertTrue(DuoTopBarPlan.narrow(width: 276, single: false).showStatus, "双区 W = 276 刚好放下")
        XCTAssertTrue(DuoTopBarPlan.narrow(width: 328, single: true).showStatus, "单区 W = 328 刚好放下")
        let b = DuoTopBarPlan.narrow(width: 260, single: false)
        XCTAssertFalse(b.showStatus); XCTAssertFalse(b.collapsedMenu); XCTAssertEqual(b.chipWidth, 156, accuracy: 0.01)
        let c = DuoTopBarPlan.narrow(width: 200, single: false)
        XCTAssertTrue(c.collapsedMenu, "双区再把调换和设置收进「⋯」"); XCTAssertEqual(c.chipWidth, 148, accuracy: 0.01); XCTAssertFalse(c.tooNarrow)
        let d = DuoTopBarPlan.narrow(width: 300, single: true)                // 单区: 去掉状态圆钮后电脑条 144
        XCTAssertFalse(d.showStatus); XCTAssertFalse(d.collapsedMenu, "单区的切换始终留在顶栏, 不收进「⋯」"); XCTAssertEqual(d.chipWidth, 144, accuracy: 0.01)
        XCTAssertTrue(DuoTopBarPlan.narrow(width: 270, single: true).tooNarrow, "单区 270: 电脑条只剩 114 < 120 → 窗口太窄")
        XCTAssertTrue(DuoTopBarPlan.narrow(width: 150, single: false).tooNarrow)
    }

    // MARK: - T-VO-1: 语音面板 + 系统键盘 (§4.8), 期望值取自 UI 稿 11 · V

    // 横向全开 (11·V A): 系统键盘顶在 y 349 → 可见到 341; 面板贴在键盘上方 (y 205), 触控板完整档 209 + 下方鼠标键行
    func testVoiceKeyboardLandscapeFullTier() {
        let base = DuoLayout.plan(Self.landscape(), page: Self.page(), swapped: false)
        let v = DuoVoiceKeyboardPlan.plan(base: base, keyboard: CGRect(x: 0, y: 349, width: 951, height: 320), window: CGSize(width: 951, height: 669))!
        XCTAssertFalse(v.modal); XCTAssertEqual(v.tier, .full)
        assertRect(v.panel, 20, 205, 431.5, 136, "面板停在键盘区一侧")
        assertRect(v.trackpad, 499.5, 68, 355.5, 209, "UI 稿: 触控板 209")
        assertRect(v.mouseButtons.first, 499.5, 285, 173.75, 56)
        // M0 实测键盘 (264 高, 顶在 405): 触控板更高, 仍是完整档
        let real = DuoVoiceKeyboardPlan.plan(base: base, keyboard: CGRect(x: 0, y: 405, width: 951, height: 264), window: CGSize(width: 951, height: 669))!
        XCTAssertEqual(real.tier, .full); XCTAssertEqual(real.trackpad!.height, 397 - 68 - 64, accuracy: 0.01)
    }

    // 窄窗口 (11·V B): 面板在上 (y 68), 剩下 129 放不下完整档 → 小触控板 267.5 × 129 + 右侧竖排左右键 (各 60.5)
    func testVoiceKeyboardNarrowSmallTier() {
        let base = DuoLayout.plan(Self.splitRight, page: Self.page(), swapped: false)
        // Split View 里键盘整屏宽 (横跨两个 App), 只算和本窗口的交集 (§3.8 第 2 条)
        let v = DuoVoiceKeyboardPlan.plan(base: base, keyboard: CGRect(x: -482, y: 349, width: 951, height: 320), window: CGSize(width: 469, height: 669))!
        XCTAssertEqual(v.tier, .small)
        assertRect(v.panel, 25.5, 68, 347.5, 136)
        assertRect(v.trackpad, 25.5, 212, 267.5, 129)
        assertRect(v.mouseButtons[0], 301, 212, 72, 60.5)
        assertRect(v.mouseButtons[1], 301, 280.5, 72, 60.5)
    }

    // 竖向全开 (M0 实测键盘 351, 顶在 600): 面板在上; 剩下的区域被折痕切开 → 取较高的一段 (折痕上方), 不跨折痕
    func testVoiceKeyboardPortraitDoesNotCrossCrease() {
        let base = DuoLayout.plan(Self.portrait(statusBar: false), page: Self.page(), swapped: false)
        let v = DuoVoiceKeyboardPlan.plan(base: base, keyboard: CGRect(x: 0, y: 600, width: 669, height: 351), window: CGSize(width: 669, height: 951))!
        XCTAssertFalse(v.modal)
        XCTAssertEqual(v.panel!.minY, 68, accuracy: 0.01)
        let tp = v.trackpad!
        XCTAssertFalse(tp.intersects(base.dividerBand!), "触控板不跨折痕")
        XCTAssertLessThanOrEqual(v.mouseButtons.map(\.maxY).max()!, base.dividerBand!.minY + 0.01)
    }

    // 都放不下 → 触控板收起; 面板本身放不下 → 盖住整个窗口的语音页; 键盘收起 (高 0) → 不重排
    func testVoiceKeyboardHiddenModalAndNone() {
        let narrow = DuoLayout.plan(Self.splitRight, page: Self.page(), swapped: false)
        let tall = DuoVoiceKeyboardPlan.plan(base: narrow, keyboard: CGRect(x: 0, y: 300, width: 469, height: 369), window: CGSize(width: 469, height: 669))!
        XCTAssertEqual(tall.tier, .hidden, "剩下不到 96: 触控板收起")
        XCTAssertFalse(tall.modal)
        let huge = DuoVoiceKeyboardPlan.plan(base: narrow, keyboard: CGRect(x: 0, y: 150, width: 469, height: 519), window: CGSize(width: 469, height: 669))!
        XCTAssertTrue(huge.modal, "紧凑条放不下: 改成模态语音页")
        XCTAssertNil(DuoVoiceKeyboardPlan.plan(base: narrow, keyboard: CGRect(x: 0, y: 669, width: 469, height: 0), window: CGSize(width: 469, height: 669)))
    }
}
