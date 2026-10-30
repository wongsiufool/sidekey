import XCTest
import SwiftUI
import UIKit
@testable import Sidekey

/// M3 第一轮 Codex 审计的修复回归 (m3-audit-codex.md)。尽量接到实际组件的生命周期上:
/// 层 2 驱动 + 输入守卫、挂载的 ContentView / LaptopKeyView、真实的 TrackpadSurface.Coordinator、无网络的语音发送记录。
@MainActor
final class M3AuditFixTests: XCTestCase {

    // MARK: - 夹具

    private func obs(portrait: Bool = false, book: Bool = false, shift: CGFloat = 0) -> DuoObservation {
        DuoObservation(screen: .inner, window: portrait ? CGSize(width: 669, height: 951) : CGSize(width: 951, height: 669),
                       safe: DuoInsets(bottom: 34),
                       regions: [DuoRegion(kind: .division,
                                           frame: portrait ? CGRect(x: 0, y: 455.5 + shift, width: 669, height: 40) : CGRect(x: 455.5 + shift, y: 0, width: 40, height: 669),
                                           isActive: book)],
                       hinge: book ? .partiallyOpen : .fullyOpen)
    }

    final class FakeTransport: InputTransport {
        var transportComputerID: UUID?
        func transportMouseDown(button: String) {}
        func transportMouseUp(button: String) {}
        func transportMouseClick(button: String) {}
        func transportDiscardPendingMotion() {}
    }

    private func pump(_ t: TimeInterval = 0.05) { RunLoop.main.run(until: Date().addingTimeInterval(t)) }
    private var window: UIWindow?
    override func tearDown() {
        window?.isHidden = true; window?.rootViewController = nil; window = nil
        ContentViewTestHooks.current = nil; LaptopKeyTestHooks.last = nil
        super.tearDown()
    }
    private func mount<V: View>(_ v: V) -> UIHostingController<V> {
        let h = UIHostingController(rootView: v)
        let w = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        w.rootViewController = h; w.makeKeyAndVisible(); window = w
        pump(0.3)
        return h
    }

    // MARK: - B1: 输入在布局采用之后才解冻; 等待期间的有效变化延长冻结

    func testGuardStaysFrozenUntilPostureAdoptedPlus150ms() {
        var clock = Date(timeIntervalSince1970: 100)
        let g = InputGuard(windowID: UUID(), computerID: { UUID() }, transport: FakeTransport(), arbiter: .init(), now: { clock })
        let d = DuoLayoutDriver(input: g)
        d.feed(obs(), at: 0)
        d.feed(obs(book: true), at: 0.01)                     // 进书本姿势: 300 ms 防抖
        XCTAssertTrue(g.frozen)
        clock = clock.addingTimeInterval(0.2); g.thawIfStable()
        XCTAssertTrue(g.frozen, "布局还在等 300 ms 防抖: 不能解冻 (审计样本 testGuardThawsBeforePostureAdoption 翻转)")
        XCTAssertTrue(d.tick(at: 0.32), "采用书本布局")
        clock = clock.addingTimeInterval(0.1); g.thawIfStable()
        XCTAssertTrue(g.frozen, "采用后再等 150 ms")
        clock = clock.addingTimeInterval(0.06); g.thawIfStable()
        XCTAssertFalse(g.frozen)
    }

    func testSecondEffectiveChangeExtendsFreeze() {
        var clock = Date(timeIntervalSince1970: 100)
        let g = InputGuard(windowID: UUID(), computerID: { UUID() }, transport: FakeTransport(), arbiter: .init(), now: { clock })
        let d = DuoLayoutDriver(input: g)
        d.feed(obs(), at: 0)
        d.feed(obs(shift: 1), at: 0.01)
        clock = clock.addingTimeInterval(0.1)
        d.feed(obs(shift: 2), at: 0.11)                        // 等待期间又换了新值
        clock = clock.addingTimeInterval(0.06); g.thawIfStable()
        XCTAssertTrue(g.frozen, "离最后一次有效变化只有 60 ms: 不能解冻 (审计样本 testSecondObservationDoesNotExtendFreeze 翻转)")
    }

    // MARK: - B5: 离开内屏整套重置, 以相同几何重新展开会重新发布

    func testSameGeometryReopenRepublishes() {
        let g = InputGuard(windowID: UUID(), computerID: { UUID() }, transport: FakeTransport(), arbiter: .init())
        let d = DuoLayoutDriver(input: g)
        XCTAssertTrue(d.feed(obs(), at: 0)); XCTAssertNotNil(d.stable)
        let gen = d.generation
        XCTAssertTrue(d.feed(.empty, at: 1)); XCTAssertNil(d.stable)
        XCTAssertNotEqual(d.generation, gen, "等待中的计时作废")
        XCTAssertTrue(d.feed(obs(), at: 2), "同一个几何重新展开: 第一次观测直接采用")
        XCTAssertNotNil(d.stable, "审计样本 testSameGeometryFoldReopenLosesStableContext 翻转")
    }

    func testMountedSameGeometryReopen() throws {
        _ = mount(ContentView())
        let v = try XCTUnwrap(ContentViewTestHooks.current)
        v.testSetScreen(.inner); pump(0.1)
        v.testFeed(obs()); pump(0.2); XCTAssertNotNil(v.testStable)
        v.testFeed(.empty); pump(0.1); XCTAssertNil(v.testStable)
        v.testFeed(obs()); pump(0.4)
        XCTAssertNotNil(v.testStable, "挂载的 ContentView: 内屏 A → 空 → 同一个 A 后布局回来")
    }

    // MARK: - B1: 打开语音面板同步结束输入

    func testOpenVoiceInterruptsSynchronously() throws {
        _ = mount(ContentView())
        let v = try XCTUnwrap(ContentViewTestHooks.current)
        v.testSelectGridMode(); v.testSetScreen(.inner); pump(0.5)
        v.testGuard.thawIfStable(); pump(0.3)
        XCTAssertFalse(v.testGuard.frozen)
        v.testOpenVoice()
        XCTAssertTrue(v.testGuard.frozen, "打开语音面板之前先同步结束输入 (审计样本 testNewVoicePresentationDoesNotInterruptImmediately 翻转)")
    }

    // MARK: - B7 / I1: 内屏和手机屏共用窗口级草稿; 内屏 (含笔记本模式) 不弹手机 sheet

    func testVoiceDraftSurvivesCrossScreen() throws {
        _ = mount(ContentView())
        let v = try XCTUnwrap(ContentViewTestHooks.current)
        v.testSetScreen(.inner); pump(0.1)
        v.testOpenVoice(); v.testVoiceDraft.text = "KEEP-ME"
        XCTAssertFalse(v.testPhoneVoicePresented, "内屏不弹手机 sheet")
        v.testSetScreen(.phone); pump(0.3)
        XCTAssertTrue(v.testShowDictation, "换屏造成的旧容器关闭不清掉语音状态")
        XCTAssertTrue(v.testPhoneVoicePresented, "手机屏改用 sheet 呈现")
        XCTAssertEqual(v.testVoiceDraft.text, "KEEP-ME", "同一份草稿, 文字不丢 (审计样本 testFoldShowsEmptyOuterDraft 翻转)")
        v.testSetScreen(.inner); pump(0.3)
        XCTAssertTrue(v.testShowDictation); XCTAssertEqual(v.testVoiceDraft.text, "KEEP-ME")
    }

    func testLaptopModeInnerUsesPanelNotPhoneSheet() throws {
        _ = mount(ContentView())
        let v = try XCTUnwrap(ContentViewTestHooks.current)
        let store = AppEnvironment.shared.store
        if let m = store.currentComputer?.modes.first(where: { $0.kind == .laptopKeyboard }) { store.selectMode(m.id) }
        v.testSetScreen(.inner); pump(0.2)
        v.testOpenVoice(); pump(0.1)
        XCTAssertTrue(v.testShowDictation)
        XCTAssertFalse(v.testPhoneVoicePresented, "笔记本模式在内屏也用内屏面板 (审计样本 testLaptopVoiceAlsoSelectsOuterSheet 翻转)")
        v.testSelectGridMode()
    }

    // MARK: - I9: 权限 / 思考强度面板是窗口级状态, 合屏换容器继续显示

    func testPaletteHandsOverAcrossScreens() throws {
        _ = mount(ContentView())
        let v = try XCTUnwrap(ContentViewTestHooks.current)
        v.testSelectGridMode(); v.testSetScreen(.inner); pump(0.2)
        v.testFeed(DuoObservation(screen: .inner, window: CGSize(width: 951, height: 669), safe: DuoInsets(bottom: 34),
                                  regions: [DuoRegion(kind: .division, frame: CGRect(x: 455.5, y: 0, width: 40, height: 669), isActive: false)],
                                  hinge: .fullyOpen)); pump(0.3)
        let perm = try XCTUnwrap(v.testGridKeys?.first { $0.kind == .permission })
        v.testOpenPalette(.permission, key: perm.id)
        XCTAssertTrue(v.testPalettePresented(.permission, inGrid: true))
        XCTAssertFalse(v.testPalettePresented(.permission, inGrid: false))
        v.testSetScreen(.phone); pump(0.9)                  // 过渡期 (旧容器先关) 之后
        XCTAssertTrue(v.testPalettePresented(.permission, inGrid: false), "合屏后转交给手机屏的 sheet")
        XCTAssertFalse(v.testPalettePresented(.permission, inGrid: true))
    }

    // MARK: - I6: 调换动画期间第二次点击无效 (接到挂载的 ContentView)

    func testSecondSwapDuringAnimationIgnored() throws {
        _ = mount(ContentView())
        let v = try XCTUnwrap(ContentViewTestHooks.current)
        let before = v.testSwapPortrait
        v.testToggleSwap(.stacked)
        XCTAssertTrue(v.testSwapAnimating)
        v.testToggleSwap(.stacked)                          // 动画期间第二次
        pump(0.05)
        XCTAssertNotEqual(v.testSwapPortrait, before, "只换了一次")
        pump(0.35)
        XCTAssertFalse(v.testSwapAnimating)
        v.testToggleSwap(.stacked); pump(0.35)              // 动画结束后可以再换 (还原)
        XCTAssertEqual(v.testSwapPortrait, before)
    }

    // MARK: - B2: 笔记本键禁用后连发停止, 迟到的松手不补发

    func testLaptopRepeatStopsWhenDisabled() throws {
        let session = LaptopSession(), client = SidekeyClient()
        session.tap(.shift)
        let key = try XCTUnwrap(LaptopKeymap.macPortrait.flatMap { $0 }.first { $0.id == "k.backspace" })
        let h = mount(LaptopKeyView(key: key, platform: .mac, enabled: true, session: session, client: client).frame(width: 100, height: 50))
        let v = try XCTUnwrap(LaptopKeyTestHooks.last)
        v.testDown()
        h.rootView = LaptopKeyView(key: key, platform: .mac, enabled: false, session: session, client: client).frame(width: 100, height: 50)
        pump(0.8)
        let after = try XCTUnwrap(LaptopKeyTestHooks.last)
        XCTAssertFalse(after.testPressed, "禁用时取消按压 (审计样本 testLaptopRepeatContinuesWhenDisabled 翻转)")
        XCTAssertEqual(session.sticky.state(.shift), .once, "没发出过: 「一次」退还")
        after.testUp()
        XCTAssertEqual(session.sticky.state(.shift), .once, "迟到的松手不补发")
    }

    // MARK: - B3 / S1: 越界取消整次手势; 滚动带最宽 64

    final class FakePan: UIPanGestureRecognizer {
        var phase: UIGestureRecognizer.State = .possible
        var pt = CGPoint.zero, delta = CGPoint.zero
        var fingers: [CGPoint] = []                                     // 实际参与的触摸 (双指用例给两根)
        override var state: UIGestureRecognizer.State { get { phase } set { phase = newValue } }
        override var numberOfTouches: Int { fingers.count }
        override func location(ofTouch i: Int, in view: UIView?) -> CGPoint { fingers[i] }
        override func location(in view: UIView?) -> CGPoint { pt }
        override func translation(in view: UIView?) -> CGPoint { delta }
        override func setTranslation(_ t: CGPoint, in view: UIView?) { delta = t }
    }

    func testTrackpadAbortsWhenFingerLeaves() {
        var moves: [(Int, Int)] = [], scrolls: [(Int, Int)] = []
        let s = TrackpadSurface(onMove: { moves.append(($0, $1)) }, onScroll: { scrolls.append(($0, $1)) }, onLeftClick: {}, onRightClick: {})
        let c = s.makeCoordinator(), view = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 300)), p = FakePan()
        view.addGestureRecognizer(p)
        p.pt = CGPoint(x: 100, y: 100); p.phase = .began; c.handlePan1(p)
        p.pt = CGPoint(x: 150, y: 100); p.delta = CGPoint(x: 0.4, y: 0); p.phase = .changed; c.handlePan1(p)   // 攒一点亚像素余量
        p.pt = CGPoint(x: 500, y: 100); p.delta = CGPoint(x: 50, y: 0); c.handlePan1(p)                       // 越界
        p.pt = CGPoint(x: 120, y: 100); p.delta = CGPoint(x: 30, y: 0); c.handlePan1(p)                       // 回来也不再发
        p.phase = .ended; c.handlePan1(p)
        XCTAssertTrue(moves.isEmpty, "越界后取消整次手势, 末段余量也不补发 (审计样本 testPanContinuesOutsideSurface 翻转): \(moves)")
        // 双指滚动同样处理
        // 双指: 两根实际触摸, 质心在区内、其中一指越界也要取消 (审计第二轮样本 testIndividualFingerOutsideWithCentroidInsideAborts)
        let p2 = FakePan(); view.addGestureRecognizer(p2)
        p2.pt = CGPoint(x: 200, y: 100); p2.fingers = [CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 100)]; p2.phase = .began; c.handlePan2(p2)
        p2.fingers = [CGPoint(x: -5, y: 100), CGPoint(x: 350, y: 100)]; p2.pt = CGPoint(x: 172.5, y: 100)
        p2.delta = CGPoint(x: 0, y: 40); p2.phase = .changed; c.handlePan2(p2)
        p2.fingers = [CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 100)]; p2.delta = CGPoint(x: 0, y: 40); c.handlePan2(p2)
        XCTAssertTrue(scrolls.isEmpty, "越界后整次手势都不再滚动")
        XCTAssertEqual(TrackpadTuning.scrollBandWidth(629), 64)
        XCTAssertEqual(TrackpadTuning.scrollBandWidth(200), 32, accuracy: 0.001)
    }

    // MARK: - B4 / I2 / I8 / I1: 笔记本排版

    func testLaptopTemporaryTrackpadStaysOnOneSide() {
        var o = obs(portrait: true); o.window.height = 730
        let probe = DuoPageInfo(columns: 12, rowCount: 6, keys: [], pageCount: 1)
        let b = DuoLayout.plan(o, page: probe, swapped: true)
        XCTAssertEqual(LaptopLayoutPlan.plan(base: b, swapped: false).kind, .tooSmall)
        let single = DuoLayout.plan(o, page: probe, swapped: true, singleChoice: .trackpad, forceSingle: true)
        if case .single(.trackpad) = single.content {
            XCTAssertFalse(single.trackpad!.intersects(b.dividerBand!), "不跨内部分界 (审计样本 testLaptopTemporaryTrackpadWouldCrossInternalDivision 翻转)")
            XCTAssertFalse(single.mouseRow!.intersects(b.dividerBand!))
        } else if case .tooSmall = single.content {
            XCTAssertNil(single.trackpad, "放不下就是「窗口太小」, 不画触控板")
        } else {
            XCTFail("回退只能是单区触控板或「窗口太小」, 实际 \(single.content)")
        }
    }

    func testLaptopKeysAvoidCameraAfterSwap() {
        var o = obs(portrait: true)
        let camera = CGRect(x: 611, y: 677.3, width: 37, height: 58)
        o.regions.append(DuoRegion(kind: .occlusion, frame: camera, isActive: false))
        let b = DuoLayout.plan(o, page: DuoPageInfo(columns: 12, rowCount: 5, keys: [], pageCount: 1), swapped: true)
        let l = LaptopLayoutPlan.plan(base: b, swapped: false)
        XCTAssertEqual(l.kind, .portrait)
        XCTAssertGreaterThanOrEqual(l.unit, 28)
        let frames = LaptopKeymap.rows(.mac, portrait: true).left.enumerated().flatMap {
            LaptopLayoutPlan.keyFrames($0.element, in: l.left, rowIndex: $0.offset, unit: l.unit, rowH: l.rowHeight)
        }
        XCTAssertFalse(frames.contains { $0.intersects(camera) }, "审计样本 testLaptopSwappedKeysOverlapCamera 翻转")
    }

    func testWideWindowWithoutDivisionShowsPlaceholder() {
        var o = obs(); o.regions = []
        let b = DuoLayout.plan(o, page: DuoPageInfo(columns: 12, rowCount: 6, keys: [], pageCount: 1), swapped: false)
        XCTAssertEqual(b.divider, .none)
        XCTAssertEqual(LaptopLayoutPlan.plan(base: b, swapped: false).kind, .tooSmall, "M3 豁免: 不落进分体 (审计样本 testNoInternalDivisionWide… 翻转)")
    }

    func testLaptopVoiceFollowsSwappedTrackpad() {
        let o = obs(), b = DuoLayout.plan(o, page: DuoPageInfo(columns: 12, rowCount: 5, keys: [], pageCount: 1), swapped: false)
        let lp = LaptopLayoutPlan.plan(base: b, swapped: true)
        XCTAssertLessThan(lp.trackpad!.midX, b.dividerBand!.midX)
        let v = DuoVoiceKeyboardPlan.plan(base: LaptopLayoutPlan.voiceBase(base: b, laptop: lp),
                                          keyboard: CGRect(x: 0, y: 405, width: 951, height: 264), window: o.window)!
        XCTAssertLessThan(v.trackpad!.midX, b.dividerBand!.midX, "触控板留在调换后的那一侧 (审计样本 testLaptopVoiceTrackpadDoesNotMatchSwappedSide 翻转)")
        XCTAssertGreaterThan(v.panel!.midX, b.dividerBand!.midX, "面板在掌托那一侧")
    }

    // MARK: - I4: 加分页行后放不下一行就占位

    func testSingleKeysTooShortAfterPagerShowsPlaceholder() {
        let o = DuoObservation(screen: .inner, window: CGSize(width: 320, height: 220), safe: DuoInsets(), regions: [], hinge: .fullyOpen)
        let p = DuoLayout.plan(o, page: DuoPageInfo(columns: 4, rowCount: 5, keys: (0..<5).map { KeyCap(label: "K", code: "a", row: $0) }, pageCount: 1), swapped: false)
        if case .tooSmall = p.content {} else { XCTFail("应为占位, 实际 \(p.content) (审计样本 testSingleKeysPagerConsumesLastRow 翻转)") }
    }

    // MARK: - I5: 连续形态变化用实际首行作锚点

    func testReanchorUsesActualFirstRow() {
        let keys = (0..<12).map { KeyCap(label: "K", code: "a", row: $0) }
        let n4 = SubpageSplitter.split(keys: keys, totalRows: 12, maxRows: 4), n3 = SubpageSplitter.split(keys: keys, totalRows: 12, maxRows: 3)
        var anchor = 4                                                     // N=4 第 2 个子页
        anchor = SubpageSplitter.reanchor(row: anchor, in: n3)             // → N=3, 实际首行 3
        XCTAssertEqual(anchor, 3)
        anchor = SubpageSplitter.reanchor(row: anchor, in: n4)             // → 回到 N=4: 包含 3 的子页首行 0
        XCTAssertEqual(anchor, 0, "审计样本 testRepeatedLayoutChangesUseStaleFirstVisibleAnchor 翻转")
    }

    // MARK: - S2: 多个修饰键的摘要可以展开看每一项

    func testStickySummaryItems() {
        var s = StickyModifiers()
        s.tap(.shift, at: 0); s.tap(.cmd, at: 1); s.tap(.cmd, at: 1.1); s.tapFn()
        XCTAssertEqual(s.summaryItems(.mac), ["⇧ 粘住一次", "⌘ 已锁定", "fn 粘住一次"])
        XCTAssertEqual(s.summary(.mac)?.count, 3)
    }

    // MARK: - I7: 排法按电脑各记各的

    func testPlatformPerComputerNoCrossBorrow() {
        let d = UserDefaults(suiteName: "m3fix.platform." + UUID().uuidString)!
        let a = UUID(), b = UUID()
        let s = PerComputerStore(defaults: d, computerIDs: [a, b])
        s.setPlatform(.windows, for: a)
        XCTAssertEqual(s.platform(for: a), .windows)
        XCTAssertNil(s.platform(for: b), "B 没识别过: 不借用 A 的记录 (界面按 Mac 默认)")
    }
}

/// M3 第二轮 Codex 审计 (m3-audit-codex.md「第二轮」) 的修复回归; 第二轮样本逐条翻转。
@MainActor
final class M3SecondRoundTests: XCTestCase {
    private func land(book: Bool = false) -> DuoObservation {
        DuoObservation(screen: .inner, window: CGSize(width: 951, height: 669), safe: DuoInsets(bottom: 34),
                       regions: [DuoRegion(kind: .division, frame: CGRect(x: 455.5, y: 0, width: 40, height: 669), isActive: book)],
                       hinge: book ? .partiallyOpen : .fullyOpen)
    }
    private func pump(_ t: TimeInterval = 0.1) { RunLoop.main.run(until: Date().addingTimeInterval(t)) }
    private var window: UIWindow?
    override func tearDown() {
        window?.isHidden = true; window?.rootViewController = nil; window = nil
        ContentViewTestHooks.current = nil; LaptopKeyTestHooks.last = nil
        super.tearDown()
    }
    @discardableResult private func mount() throws -> ContentView {
        let h = UIHostingController(rootView: ContentView())
        let w = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        w.rootViewController = h; w.makeKeyAndVisible(); window = w
        pump(0.4)
        return try XCTUnwrap(ContentViewTestHooks.current)
    }
    private func textViews(_ root: UIView) -> [UITextView] { (root as? UITextView).map { [$0] } ?? root.subviews.flatMap(textViews) }

    // N-B1: 回到稳定值之后, 不影响布局的观测不能让冻结一直延长
    func testEquivalentObservationsDoNotKeepGuardFrozen() {
        var clock = Date(timeIntervalSince1970: 100)
        let g = InputGuard(windowID: UUID(), computerID: { UUID() }, transport: M3AuditFixTests.FakeTransport(), arbiter: .init(), now: { clock })
        let d = DuoLayoutDriver(input: g)
        let a = land()
        d.feed(a, at: 0); d.feed(land(book: true), at: 0.01)
        clock = clock.addingTimeInterval(0.1); d.feed(a, at: 0.1)
        for i in 2...100 {
            var harmless = a
            harmless.regions.append(DuoRegion(kind: .occlusion, frame: CGRect(x: 470, y: CGFloat(i + 200), width: 1, height: 1), isActive: false))
            XCTAssertEqual(DuoStableContext(a), DuoStableContext(harmless))
            clock = Date(timeIntervalSince1970: 100 + Double(i) * 0.1)
            d.feed(harmless, at: Double(i) * 0.1); _ = d.tick(at: Double(i) * 0.1); g.thawIfStable()
        }
        XCTAssertFalse(g.frozen, "等价观测不重设计时 (第二轮样本 testIrrelevantUpdatesAfterReturnToStableKeepGuardFrozen 翻转)")
        XCTAssertNil(d.deadline)
    }

    // N-B2: 到 .ended 才越界, 也丢掉余量
    func testOutsideOnlyAtEndedDropsPendingMove() {
        var moves: [Int] = []
        let s = TrackpadSurface(onMove: { x, _ in moves.append(x) }, onScroll: { _, _ in }, onLeftClick: {}, onRightClick: {})
        let c = s.makeCoordinator(), view = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 300)), p = M3AuditFixTests.FakePan()
        view.addGestureRecognizer(p)
        p.pt = CGPoint(x: 30, y: 100); p.phase = .began; c.handlePan1(p)
        p.pt = CGPoint(x: 31, y: 100); p.delta = CGPoint(x: 1, y: 0); p.phase = .changed; c.handlePan1(p)
        p.pt = CGPoint(x: 1, y: 100); p.delta = CGPoint(x: -30, y: 0); c.handlePan1(p)
        moves = []
        p.pt = CGPoint(x: -1, y: 100); p.phase = .ended; c.handlePan1(p)
        XCTAssertTrue(moves.isEmpty, "第二轮样本 testOutsideOnlyAtEndedStillFlushesPendingMove 翻转")
        // 对照: 结束位置在区内时, 余量照常冲掉
        p.pt = CGPoint(x: 30, y: 100); p.phase = .began; c.handlePan1(p)
        p.pt = CGPoint(x: 31, y: 100); p.delta = CGPoint(x: 0.6, y: 0); p.phase = .changed; c.handlePan1(p)
        p.phase = .ended; c.handlePan1(p)
        XCTAssertFalse(moves.isEmpty, "正常结束仍补发余量")
    }

    // N-I1: 内屏但暂用原键位 (大屏键位生成不了) 时, 语音用手机 sheet, 不会两边都没有
    func testOriginalFallbackOnInnerUsesPhoneSheet() throws {
        let v = try mount()
        let store = AppEnvironment.shared.store
        let id = try XCTUnwrap(store.installFixture(named: "legacybounds"))
        v.testSelectMode(id); v.testSetScreen(.inner); pump(0.3)
        XCTAssertFalse(v.testUsesInnerPresentation, "越界旧键: 内屏暂用原键位")
        v.testOpenVoice(); pump(0.2)
        XCTAssertTrue(v.testPhoneVoicePresented, "第二轮样本 testLegacyOriginalFallbackCannotOpenVoice 翻转")
        v.testSelectGridMode()
    }

    // N-I2: 重新展开后的第一次采用也更新锚点 (走真实采用路径, 不手动调 reanchor)
    func testReopenFirstAdoptionUpdatesActualFirstRow() throws {
        let v = try mount()
        let store = AppEnvironment.shared.store
        let id = try XCTUnwrap(store.installFixture(named: "subpages"))
        store.ensureLarge(computer: store.currentComputerID, mode: id)
        v.testSelectMode(id); v.testSetScreen(.inner); pump(0.3)
        func portrait(_ mid: CGFloat) -> DuoObservation {
            DuoObservation(screen: .inner, window: CGSize(width: 669, height: 951), safe: DuoInsets(bottom: 34),
                           regions: [DuoRegion(kind: .division, frame: CGRect(x: 0, y: mid - 20, width: 669, height: 40), isActive: false)],
                           hinge: .fullyOpen)
        }
        let a = portrait(350), b = portrait(302)
        v.testFeed(a); pump(0.3)
        v.testSubpageRow = 4; pump(0.1)
        XCTAssertEqual(v.testCurrentFirstRow, 4)
        v.testFeed(.empty); v.testFeed(b); pump(0.2)
        XCTAssertEqual(v.testCurrentFirstRow, 3)
        XCTAssertEqual(v.testSubpageRow, 3, "首次采用也把锚点更新成实际首行 (第二轮样本 testReopenFirstAdoption… 翻转)")
        v.testFeed(a); pump(0.4)
        XCTAssertEqual(v.testCurrentFirstRow, 0, "回到 N=4: 包含 3 的子页首行 0")
        v.testSelectGridMode()
    }

    // N-I3: 跨屏保留选区, 原来收起的键盘不自动弹出。
    // 换屏 = 旧容器里的 VoiceTextView 被拆掉、新容器里建一个新的 (同一份窗口级草稿); 这里用真实 UITextView 走这条生命周期,
    // 真实的 sheet / 面板呈现由 UI 测试 testCrossScreenVoiceRealPresentation 覆盖。
    func testCrossScreenKeepsSelectionAndHiddenKeyboard() throws {
        let draft = VoiceDraft(); draft.text = "0123456789"
        func host(_ id: String) -> (UIWindow, UITextView) {
            let h = UIHostingController(rootView: VoiceTextView(draft: draft, fontSize: 17, textColor: .label, identifier: id).frame(width: 300, height: 120))
            // 挂到宿主 App 的 scene 上, 窗口才真的显示, UIViewRepresentable 才会建出 UITextView
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
            let w = UIWindow(windowScene: scene); w.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
            w.rootViewController = h; w.makeKeyAndVisible()
            pump(0.3)
            return (w, textViews(w).first!)
        }
        var (w1, old) = host("voiceText")
        XCTAssertFalse(old.isFirstResponder)
        old.becomeFirstResponder(); pump(0.1)
        XCTAssertTrue(draft.wantsFocus, "用户在输入: 记下要焦点")
        old.selectedRange = NSRange(location: 3, length: 2); pump(0.1)
        old.resignFirstResponder(); pump(0.2)
        XCTAssertFalse(draft.wantsFocus, "用户收起了键盘")
        w1.isHidden = true; w1.rootViewController = nil; pump(0.2)          // 旧容器拆掉
        let (w2, next) = host("phoneVoiceText")
        XCTAssertEqual(next.text, "0123456789")
        XCTAssertEqual(next.selectedRange, NSRange(location: 3, length: 2), "选区交接 (第二轮样本 testCrossScreenTextRetainedButSelectionAndFocusAreReset 翻转)")
        XCTAssertFalse(next.isFirstResponder, "原来键盘收起的, 换屏后不自动弹出")
        // 对照: 换屏前键盘是开着的, 新容器接着要焦点
        next.becomeFirstResponder(); next.selectedRange = NSRange(location: 1, length: 0); pump(0.1)
        XCTAssertTrue(draft.wantsFocus)
        w2.isHidden = true; w2.rootViewController = nil; pump(0.2)
        (w1, old) = host("voiceText")
        XCTAssertTrue(old.isFirstResponder, "原来在输入, 换屏后接着输入")
        XCTAssertEqual(old.selectedRange, NSRange(location: 1, length: 0))
        old.resignFirstResponder(); w1.isHidden = true
    }

    // N-I4: 网格因回退消失时, 面板改用 sheet, 不丢
    func testPaletteMovesToSheetWhenGridDisappears() throws {
        let v = try mount()
        v.testSelectGridMode(); v.testSetScreen(.inner); pump(0.2)
        v.testFeed(land()); pump(0.3)
        let perm = try XCTUnwrap(v.testGridKeys?.first { $0.kind == .permission })
        v.testOpenPalette(.permission, key: perm.id)
        XCTAssertTrue(v.testPalettePresented(.permission, inGrid: true))   // 打开时不走交接延迟: 在 UI 测试 testPaletteRealHandover 里按实际呈现验证
        v.testFeed(DuoObservation(screen: .inner, window: CGSize(width: 320, height: 220), safe: DuoInsets(), regions: [], hinge: .fullyOpen))
        pump(1.0)
        XCTAssertNil(v.testGridKeys, "网格进入占位")
        XCTAssertTrue(v.testPalettePresented(.permission, inGrid: false), "改用 sheet (第二轮样本 testPaletteDisappearsWhenLayoutLosesGrid 翻转)")
        XCTAssertFalse(v.testPalettePresented(.permission, inGrid: true))
    }

    // N-I5: 鼠标键命中区不被压到 44 以下
    func testSingleTrackpadMouseButtonsKeepHitMinimum() {
        for w in stride(from: 160, through: 480, by: 20) {
            let o = DuoObservation(screen: .inner, window: CGSize(width: CGFloat(w), height: 500), safe: DuoInsets(), regions: [], hinge: .fullyOpen)
            let p = DuoLayout.plan(o, page: DuoPageInfo(columns: 12, rowCount: 6, keys: [], pageCount: 1), swapped: false, singleChoice: .trackpad, forceSingle: true)
            switch p.content {
            case .single(.trackpad):
                XCTAssertGreaterThanOrEqual((p.mouseRow!.width - 8) / 2, 44, "宽 \(w) (第二轮样本 testSingleTrackpadMouseButtonsBelowHitMinimum 翻转)")
                XCTAssertGreaterThanOrEqual(p.trackpad!.width, 160)
                XCTAssertFalse(p.mouseRow!.intersects(p.dock), "宽 \(w)")
            case .tooSmall:
                XCTAssertNil(p.trackpad)
            default:
                XCTFail("宽 \(w): \(p.content)")
            }
        }
    }

    // 第二轮其余样本 (修复前就通过的部分) 原样保留
    func testLateAckCannotConsumeNewRequest() {
        let t = VoiceDraftTests.FakeVoice(), d = VoiceDraft()
        d.text = "FIRST"; d.send(via: t, autoEnter: true); let old = t.pending[0]; old(false, "timeout")
        d.text = "SECOND"; d.send(via: t, autoEnter: true); old(true, nil)
        XCTAssertTrue(d.isSending); XCTAssertEqual(d.text, "SECOND"); XCTAssertTrue(t.keys.isEmpty)
    }

    func testFailedThenClearedIsNotSuccess() {
        let t = VoiceDraftTests.FakeVoice(), d = VoiceDraft()
        d.text = "DRAFT"; d.send(via: t, autoEnter: false); t.ack(false, "timeout")
        d.text = ""
        XCTAssertEqual(d.successCount, 0, "失败后清空文字不算成功, 手机 sheet 不会因此关闭 (第二轮 UI 样本 testClearingFailedPhoneDraft… 翻转)")
        d.text = "ok"; d.send(via: t, autoEnter: false); t.ack(true)
        XCTAssertEqual(d.successCount, 1)
    }
}

/// B6: 语音发送是一次请求, 用无网络的发送记录验证 (不留到真机)。
@MainActor
final class VoiceDraftTests: XCTestCase {
    final class FakeVoice: VoiceTransport {
        var isConnectedForVoice = true
        var connectedComputerID: UUID? = UUID()
        var pastes: [String] = [], keys: [String] = []
        var pending: [(Bool, String?) -> Void] = []
        func sendPasteTracked(_ text: String, timeout: TimeInterval, completion: @escaping (Bool, String?) -> Void) { pastes.append(text); pending.append(completion) }
        func sendKey(_ cap: KeyCap) { keys.append(cap.code) }
        func ack(_ ok: Bool, _ code: String? = nil) { let cb = pending.removeFirst(); cb(ok, code) }
    }

    func testEnterSettingFixedAtSend() {
        let t = FakeVoice(), d = VoiceDraft(); d.text = "hello"
        d.send(via: t, autoEnter: false)
        XCTAssertEqual(d.state, .sending)
        t.ack(true)                                         // 期间界面上改成「回车：开」也不影响这次请求
        XCTAssertEqual(t.keys, [], "按发起时的设置 (关) 不补 Enter (审计样本 testVoiceAckUsesChangedEnter 翻转)")
        let e = VoiceDraft(); e.text = "x"; e.send(via: t, autoEnter: true); t.ack(true)
        XCTAssertEqual(t.keys, ["enter"])
    }

    func testEditsDuringSendingSurviveSuccess() {
        let t = FakeVoice(), d = VoiceDraft(); d.text = "ORIGINAL"
        d.send(via: t, autoEnter: false)
        d.text = "NEXT DRAFT"
        t.ack(true)
        XCTAssertEqual(d.text, "NEXT DRAFT", "成功回执不清掉发送后新打的文字")
        XCTAssertEqual(d.state, .idle)
        XCTAssertEqual(t.pastes, ["ORIGINAL"])
    }

    func testClearDoesNotReleaseSending() {
        let t = FakeVoice(), d = VoiceDraft(); d.text = "a"
        d.send(via: t, autoEnter: false)
        d.clear()
        XCTAssertEqual(d.state, .sending, "清空不解除发送中的占用")
        d.text = "b"; d.send(via: t, autoEnter: false)
        XCTAssertEqual(t.pastes, ["a"], "发送中不能再发")
    }

    func testThreeOutcomes() {
        let t = FakeVoice()
        let lost = VoiceDraft(); lost.text = "x"; lost.send(via: t, autoEnter: false); t.ack(false, "lost")
        if case .uncertain = lost.state {} else { XCTFail("已提交后断线 = 结果不确定 (审计样本 testPendingVoiceDisconnect… 翻转)") }
        XCTAssertEqual(lost.text, "x")
        let timeout = VoiceDraft(); timeout.text = "y"; timeout.send(via: t, autoEnter: false); t.ack(false, "timeout")
        if case .uncertain = timeout.state {} else { XCTFail("超时 = 不确定") }
        let ax = VoiceDraft(); ax.text = "z"; ax.send(via: t, autoEnter: false); t.ack(false, "ax")
        if case .failed = ax.state {} else { XCTFail("电脑端明确报错 = 没发出") }
        t.isConnectedForVoice = false
        let off = VoiceDraft(); off.text = "w"; off.send(via: t, autoEnter: false)
        if case .failed = off.state {} else { XCTFail("根本没交出去 = 确定没发") }
        XCTAssertEqual(t.pastes.count, 3)
    }

    func testEnterOnlyToOriginalComputer() {
        let t = FakeVoice(), d = VoiceDraft(); d.text = "x"
        d.send(via: t, autoEnter: true)
        t.connectedComputerID = UUID()                       // 回执前换了电脑
        t.ack(true)
        XCTAssertEqual(t.keys, [], "Enter 只发给发起时那台电脑")
    }

    func testEditingClearsOutcomeButNotSending() {
        let t = FakeVoice(), d = VoiceDraft(); d.text = "x"
        d.send(via: t, autoEnter: false); t.ack(false, "ax")
        d.text = "xy"
        XCTAssertEqual(d.state, .idle)
    }
}
