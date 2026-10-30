import XCTest
import SwiftUI
import UIKit
@testable import Sidekey

/// M3 第三轮 Codex 审计 (m3-audit-codex.md「第三轮」) 的修复回归; 第三轮样本逐条翻转。
@MainActor
final class M3ThirdRoundTests: XCTestCase {
    final class FakeVoice: VoiceTransport {
        var isConnectedForVoice = true
        var connectedComputerID: UUID? = UUID()
        var cb: ((Bool, String?) -> Void)?
        func sendPasteTracked(_ text: String, timeout: TimeInterval, completion: @escaping (Bool, String?) -> Void) { cb = completion }
        func sendKey(_ cap: KeyCap) {}
    }
    /// 一个容器 = 同一个窗口里的一块 UIHostingController (换屏时旧容器退场、新容器进场都在同一个窗口里)
    final class Box { let h: UIHostingController<AnyView>; init(_ h: UIHostingController<AnyView>) { self.h = h } }
    private var windows: [UIWindow] = []
    private var stage: UIWindow?
    private func pump(_ t: TimeInterval = 0.15) { RunLoop.main.run(until: Date().addingTimeInterval(t)) }
    private func textViews(_ v: UIView) -> [UITextView] { (v as? UITextView).map { [$0] } ?? v.subviews.flatMap(textViews) }
    private func scene() throws -> UIWindowScene { try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first) }
    private func ensureStage() throws -> UIWindow {
        if let s = stage { return s }
        let w = UIWindow(windowScene: try scene()); w.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        w.rootViewController = UIViewController(); w.makeKeyAndVisible(); stage = w; windows.append(w)
        return w
    }
    /// 挂一个真实的输入框 (窗口挂在宿主 scene 上才会真的显示, UITextView 才会建出来)
    private func host(_ d: VoiceDraft, font: CGFloat = 17, color: UIColor = .black, id: String = "t") throws -> (Box, UITextView) {
        let w = try ensureStage(), root = try XCTUnwrap(w.rootViewController)
        let h = UIHostingController(rootView: AnyView(VoiceTextView(draft: d, fontSize: font, textColor: color, identifier: id)))
        root.addChild(h); h.view.frame = CGRect(x: 0, y: 0, width: 402, height: 200); root.view.addSubview(h.view); h.didMove(toParent: root)
        pump(0.3)
        return (Box(h), try XCTUnwrap(textViews(h.view).first))
    }
    /// 容器退场: SwiftUI 拆掉输入框, 再从窗口移走
    private func remove(_ b: Box) {
        b.h.rootView = AnyView(EmptyView()); pump(0.05)
        b.h.willMove(toParent: nil); b.h.view.removeFromSuperview(); b.h.removeFromParent()
    }
    override func tearDown() {
        windows.forEach { $0.endEditing(true); $0.isHidden = true; $0.rootViewController = nil }; windows = []; stage = nil
        ContentViewTestHooks.current = nil
        super.tearDown()
    }

    // MARK: R-I3 样式随更新同步

    func testStyleChangesUpdateActualTextView() throws {
        let d = VoiceDraft(); d.text = "ABCDEF"; d.selection = NSRange(location: 2, length: 3); d.wantsFocus = true
        let (b, v) = try host(d, font: 15, color: .black)
        XCTAssertTrue(v.isFirstResponder)
        for (font, color) in [(CGFloat(14), UIColor.white), (15, .black), (14, .black), (15, .white)] {   // 停靠 15 / 紧凑 14, 明暗两色
            b.h.rootView = AnyView(VoiceTextView(draft: d, fontSize: font, textColor: color, identifier: "t")); pump(0.2)
            XCTAssertEqual(v.font?.pointSize, font, "字号 (第三轮样本 testStyleChangesUpdateActualTextView 翻转)")
            XCTAssertEqual(v.textColor, color, "文字颜色")
            XCTAssertEqual(v.text, "ABCDEF"); XCTAssertEqual(v.selectedRange, NSRange(location: 2, length: 3))
            XCTAssertTrue(v.isFirstResponder, "换样式不动焦点"); XCTAssertTrue(d.wantsFocus)
            XCTAssertEqual(d.text, "ABCDEF"); XCTAssertEqual(d.selection, NSRange(location: 2, length: 3), "换样式不回写选区")
        }
    }

    // MARK: R-B1 旧输入框不能改写草稿

    func testTeardownCannotRestoreStaleText() throws {
        let d = VoiceDraft(); d.text = "OLD SENT"; d.wantsFocus = true
        let (b, v) = try host(d)
        XCTAssertTrue(v.isFirstResponder)
        d.text = "NEW DRAFT"                                    // 回执 / 编辑和换容器在同一轮主循环里, SwiftUI 还没更新
        remove(b); pump(0.3)
        XCTAssertEqual(d.text, "NEW DRAFT", "第三轮样本 testTeardownCannotRestoreStaleText 翻转")
    }

    func testAckClearThenTeardownCannotResurrectSentText() throws {
        let d = VoiceDraft(); d.text = "ALREADY SENT"; d.wantsFocus = true
        let (b, v) = try host(d)
        XCTAssertTrue(v.isFirstResponder)
        let t = FakeVoice(); d.send(via: t, autoEnter: false); t.cb?(true, nil)
        XCTAssertEqual(d.text, "")
        remove(b); pump(0.3)
        XCTAssertEqual(d.text, "", "已发送的文字不会恢复 (第三轮样本 testAckClearThenTeardownCannotResurrectSentText 翻转)")
    }

    func testEndEditingStaleCoordinatorDoesNotOverwrite() throws {
        let d = VoiceDraft(); d.text = "OLD"
        let (b, v) = try host(d)
        let delegate = try XCTUnwrap(v.delegate)
        remove(b); pump(0.2); d.text = "NEW"
        delegate.textViewDidEndEditing?(v)
        delegate.textViewDidChange?(v)
        delegate.textViewDidChangeSelection?(v)
        XCTAssertEqual(d.text, "NEW", "迟到的旧回调不改写 (第三轮样本 testEndEditingStaleCoordinatorDoesNotOverwrite 翻转)")
    }

    /// 交接途中 (旧容器还在退场、新容器已经建出来) 的三种情况: 收到回执、输入新文字、旧回调迟到
    func testHandoverMidwayAckEditAndLateCallbacks() throws {
        let d = VoiceDraft(); d.text = "SENDING"; d.wantsFocus = true
        let (b1, old) = try host(d, id: "old")
        XCTAssertTrue(old.isFirstResponder)
        let oldDelegate = try XCTUnwrap(old.delegate)
        let t = FakeVoice(); d.send(via: t, autoEnter: false)
        let (b2, new) = try host(d, id: "new")              // 新容器接管, 旧的还在窗口里
        XCTAssertTrue(new.isFirstResponder, "焦点交给新容器"); XCTAssertFalse(old.isFirstResponder)
        t.cb?(true, nil); pump(0.2)                             // 交接途中收到回执
        XCTAssertEqual(d.text, ""); XCTAssertEqual(new.text, "")
        new.insertText("NEXT"); pump(0.1)                       // 交接途中在新容器输入新文字
        XCTAssertEqual(d.text, "NEXT")
        old.text = "SENDING"                                    // 旧输入框里还是旧文字, 它的回调迟到
        oldDelegate.textViewDidChange?(old); oldDelegate.textViewDidEndEditing?(old)
        old.selectedRange = NSRange(location: 1, length: 2); oldDelegate.textViewDidChangeSelection?(old)
        oldDelegate.textViewDidBeginEditing?(old)
        remove(b1); pump(0.3)                                   // 旧容器退场
        XCTAssertEqual(d.text, "NEXT", "新草稿不被旧文字覆盖, 已发送的不恢复")
        XCTAssertEqual(d.selection, new.selectedRange, "选区只跟新容器")
        XCTAssertTrue(new.isFirstResponder); XCTAssertTrue(d.wantsFocus)
        remove(b2)
    }

    /// 加固 (抽查建议): 负责编辑的输入框都已拆除、editorToken 为空时, 仍在场的输入框开始编辑就重新接管
    func testRemainingEditorReclaimsWhenTokenEmpty() throws {
        let d = VoiceDraft(); d.text = "KEEP"
        let (_, a) = try host(d, id: "a")
        let (b, _) = try host(d, id: "b")                       // b 接管
        remove(b); pump(0.2)                                    // b 拆除: 没有负责编辑的输入框了
        XCTAssertNil(d.editorToken)
        a.becomeFirstResponder(); pump(0.1)
        XCTAssertNotNil(d.editorToken, "仍在场的 a 开始编辑就重新接管")
        XCTAssertTrue(d.wantsFocus)
        a.selectedRange = NSRange(location: 4, length: 0); a.insertText("!"); pump(0.1)
        XCTAssertEqual(d.text, "KEEP!", "接管后的编辑写回草稿")
        a.resignFirstResponder()
    }

    /// 重新接管时先把输入框对齐到草稿: 没人负责期间草稿被回执清空, 接着打字不能把已发送的文字带回来
    func testReclaimAlignsStaleTextToDraft() throws {
        let d = VoiceDraft(); d.text = "SENT"
        let (_, a) = try host(d, id: "a")
        let (b, _) = try host(d, id: "b")
        remove(b); pump(0.2)
        XCTAssertNil(d.editorToken)
        let t = FakeVoice(); d.send(via: t, autoEnter: false); t.cb?(true, nil)   // 没人负责期间回执清空草稿
        XCTAssertEqual(d.text, ""); XCTAssertEqual(a.text, "SENT", "a 里还是旧文字")
        a.becomeFirstResponder(); pump(0.1)
        XCTAssertEqual(a.text, "", "接管时对齐到草稿")
        a.insertText("X"); pump(0.1)
        XCTAssertEqual(d.text, "X", "草稿只有新输入, 不含已发送的文字")
        a.resignFirstResponder()
    }

    /// 两个容器同时在场 (换屏的退场 / 进场重叠) 时焦点不来回抢: 焦点只变一次, 之后稳定
    func testOverlappingContainersDoNotPingPongFocus() throws {
        let d = VoiceDraft(); d.text = "0123456789"; d.selection = NSRange(location: 3, length: 2); d.wantsFocus = true
        let (_, a) = try host(d, id: "a")
        let (_, b) = try host(d, id: "b")
        var flips = 0, last = b.isFirstResponder
        for _ in 0..<20 { pump(0.05); if b.isFirstResponder != last { flips += 1; last = b.isFirstResponder } }
        XCTAssertTrue(b.isFirstResponder); XCTAssertFalse(a.isFirstResponder)
        XCTAssertEqual(flips, 0, "焦点稳定在新容器, 没有循环")
        XCTAssertEqual(b.selectedRange, NSRange(location: 3, length: 2))
    }

    /// 组件级往返 20 次: 键盘开着、收着两种状态; 每次检查文字、选区、焦点
    func testRoundTrip20TimesBothKeyboardStates() throws {
        for keep in [true, false] {
            let d = VoiceDraft(); d.text = "0123456789"; d.selection = NSRange(location: 3, length: 2); d.wantsFocus = keep
            var (box, cur) = try host(d, id: "c0")
            for i in 1...20 {
                let (nb, next) = try host(d, id: "c\(i)")      // 新容器先进场
                remove(box); pump(0.15)                         // 旧容器再退场
                XCTAssertEqual(next.text, "0123456789", "第 \(i) 次 (键盘\(keep ? "开" : "收"))")
                XCTAssertEqual(next.selectedRange, NSRange(location: 3, length: 2), "第 \(i) 次选区")
                XCTAssertEqual(next.isFirstResponder, keep, "第 \(i) 次焦点")
                XCTAssertEqual(d.wantsFocus, keep); XCTAssertFalse(cur.isFirstResponder)
                cur = next; box = nb
            }
            cur.resignFirstResponder(); remove(box)
        }
    }

    // MARK: R-I1 面板锚点只认实际画出的键

    func testVisibleKeysFilterUsedByRenderAndAnchor() {
        let keys = (0..<5).map { r in KeyCap(label: "R\(r)", col: 0, row: r) }
        let g = InnerGridShown.compute(pageKeys: keys, rowCount: 5, subpages: [], subIdx: 0, height: 5 * 48 - 8, visibleHeight: 78)
        XCTAssertEqual(g.rowHeight, 40)
        XCTAssertEqual(g.shown.map(\.row), [0], "只露出一行 (行底 40 ≤ 78; 第二行底 88 > 78)")
        XCTAssertEqual(InnerGridShown.compute(pageKeys: keys, rowCount: 5, subpages: [], subIdx: 0, height: 232, visibleHeight: nil).shown.count, 5)
    }

    func testPaletteAnchorHiddenByVoiceMovesToSheetAndBack() throws {
        let w = UIWindow(windowScene: try scene()); w.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        w.rootViewController = UIHostingController(rootView: ContentView()); windows.append(w); w.makeKeyAndVisible()
        pump(0.4)
        let v = try XCTUnwrap(ContentViewTestHooks.current), s = AppEnvironment.shared.store
        let m = try XCTUnwrap(s.installFixture(named: "subpages")); _ = s.ensureLarge(computer: s.currentComputerID, mode: m)
        defer { v.testSelectGridMode() }
        v.testSelectMode(m); v.testSubpageRow = 0; v.testSetScreen(.inner); pump(0.3)
        let obs = DuoObservation(screen: .inner, window: CGSize(width: 951, height: 669), safe: DuoInsets(bottom: 34),
                                 regions: [DuoRegion(kind: .division, frame: CGRect(x: 455.5, y: 0, width: 40, height: 669), isActive: false)],
                                 hinge: .fullyOpen)
        v.testFeed(obs); pump(0.4)
        var key = try XCTUnwrap(v.testGridKeys?.max { $0.row < $1.row })
        key.kind = .permission; key.label = "AUDIT PERMISSION"
        XCTAssertTrue(s.updateKey(layerID: "base", cap: key, in: LayoutTarget(computer: s.currentComputerID, mode: m, set: .large))); pump(0.2)
        v.testOpenPalette(.permission, key: key.id); pump(0.2)
        XCTAssertTrue(v.testPalettePresented(.permission, inGrid: true), "锚点可见: popover")
        v.testOpenVoice(); v.testVoiceDraft.wantsFocus = false
        NotificationCenter.default.post(name: UIResponder.keyboardWillChangeFrameNotification, object: nil,
                                        userInfo: [UIResponder.keyboardFrameEndUserInfoKey: CGRect(x: 0, y: 350, width: 951, height: 524)])
        pump(1.0)
        XCTAssertFalse(v.testGridKeys?.contains { $0.id == key.id } ?? false, "锚点那一行被语音面板挡住、没画出来 (第三轮样本 testPaletteAnchorIgnoresRowsRemovedByVoice 翻转)")
        XCTAssertTrue(v.testPalettePresented(.permission, inGrid: false), "新容器 (sheet) 确实在呈现")
        XCTAssertFalse(v.testPalettePresented(.permission, inGrid: true))
        // 尺寸恢复 (语音关掉、锚点重新画出来) 后面板不丢, 回到 popover
        v.testCloseVoice()
        NotificationCenter.default.post(name: UIResponder.keyboardWillChangeFrameNotification, object: nil,
                                        userInfo: [UIResponder.keyboardFrameEndUserInfoKey: CGRect(x: 0, y: 874, width: 951, height: 0)])
        pump(1.0)
        XCTAssertTrue(v.testGridKeys?.contains { $0.id == key.id } ?? false)
        XCTAssertTrue(v.testPalettePresented(.permission, inGrid: true), "面板没丢, 回到键旁")
        XCTAssertFalse(v.testPalettePresented(.permission, inGrid: false))
    }

    // MARK: R-I2 单区触控板的外围控件避开摄像头

    func testSingleTrackpadMouseRowAvoidsCamera() {
        let camera = CGRect(x: 890, y: 570, width: 35, height: 50)
        let o = DuoObservation(screen: .inner, window: CGSize(width: 951, height: 669), safe: DuoInsets(bottom: 34),
                               regions: [DuoRegion(kind: .occlusion, frame: camera, isActive: false)], hinge: .fullyOpen)
        let p = DuoLayout.plan(o, page: DuoPageInfo(columns: 12, rowCount: 6, keys: [], pageCount: 1), swapped: false, singleChoice: .trackpad, forceSingle: true)
        guard case .single(.trackpad) = p.content else { return XCTFail("\(p.content)") }
        XCTAssertFalse(p.mouseRow!.intersects(camera), "第三轮样本 testSingleTrackpadMouseRowAvoidsCamera 翻转: \(p.mouseRow!)")
    }

    /// 摄像头在底行左侧 / 右侧 × 上下 / 左右分区 × 两种调换 × 强制触控板回退
    func testSingleTrackpadCameraMatrix() {
        var placed = 0
        for size in [CGSize(width: 951, height: 669), CGSize(width: 669, height: 951)] {
            let landscape = size.width > size.height
            let division = landscape ? CGRect(x: size.width / 2 - 20, y: 0, width: 40, height: size.height)
                                     : CGRect(x: 0, y: size.height / 2 - 20, width: size.width, height: 40)
            for camX in [CGFloat(30), size.width - 65] {
                let camera = CGRect(x: camX, y: size.height - 99, width: 35, height: 50)
                for swap in [false, true] {
                    let o = DuoObservation(screen: .inner, window: size, safe: DuoInsets(bottom: 34),
                                           regions: [DuoRegion(kind: .division, frame: division, isActive: false),
                                                     DuoRegion(kind: .occlusion, frame: camera, isActive: false)], hinge: .fullyOpen)
                    let p = DuoLayout.plan(o, page: DuoPageInfo(columns: 12, rowCount: 6, keys: [], pageCount: 1), swapped: swap,
                                           singleChoice: .trackpad, forceSingle: true)
                    let tag = "\(size) cam x=\(camX) swap=\(swap)"
                    switch p.content {
                    case .single(.trackpad):
                        placed += 1
                        let m = p.mouseRow!, tp = p.trackpad!, d = p.dock
                        XCTAssertFalse(m.intersects(camera), tag); XCTAssertFalse(d.intersects(camera), tag)
                        XCTAssertFalse(m.intersects(tp), tag); XCTAssertFalse(m.intersects(d), tag); XCTAssertFalse(tp.intersects(d), tag)
                        XCTAssertGreaterThanOrEqual(m.height, 44, tag); XCTAssertGreaterThanOrEqual((m.width - 8) / 2, 44, tag)
                        XCTAssertGreaterThanOrEqual(d.height, 44, tag)
                        if let b = p.dividerBand { XCTAssertFalse(m.intersects(b), tag); XCTAssertFalse(tp.intersects(b), tag) }
                    case .tooSmall:
                        XCTAssertNil(p.trackpad, tag)
                    default:
                        XCTFail("\(tag): \(p.content)")
                    }
                }
            }
        }
        XCTAssertEqual(placed, 8, "这些尺寸都放得下, 不应退成占位")
    }

    /// Codex 第三轮的预算矩阵: 尺寸 × 有无分界 × 方向 × 调换
    func testSingleTrackpadBudgetMatrix() {
        var count = 0
        for w in stride(from: 160, through: 1100, by: 40) { for h in stride(from: 180, through: 1000, by: 40) { for rotated in [false, true] {
            let size = CGSize(width: w, height: h)
            let division = DuoRegion(kind: .division, frame: rotated ? CGRect(x: CGFloat(w) / 2 - 20, y: 0, width: 40, height: CGFloat(h))
                                                                     : CGRect(x: 0, y: CGFloat(h) / 2 - 20, width: CGFloat(w), height: 40), isActive: false)
            for regions in [[], [division]] { for swap in [false, true] {
                let o = DuoObservation(screen: .inner, window: size, safe: DuoInsets(bottom: 34), regions: regions, hinge: .fullyOpen)
                let p = DuoLayout.plan(o, page: DuoPageInfo(columns: 12, rowCount: 6, keys: [], pageCount: 1), swapped: swap, singleChoice: .trackpad, forceSingle: true)
                guard case .single(.trackpad) = p.content else { continue }
                count += 1
                guard let m = p.mouseRow, let tp = p.trackpad else { return XCTFail("missing rect") }
                XCTAssertGreaterThanOrEqual(m.width, 96); XCTAssertGreaterThanOrEqual(m.height, 44)
                XCTAssertGreaterThanOrEqual(tp.width, 160); XCTAssertGreaterThanOrEqual(tp.height, 80)
                XCTAssertFalse(m.intersects(tp)); XCTAssertFalse(m.intersects(p.dock))
                XCTAssertTrue(CGRect(origin: .zero, size: size).contains(m)); XCTAssertTrue(CGRect(origin: .zero, size: size).contains(tp))
                if let d = p.dividerBand { XCTAssertFalse(m.intersects(d)); XCTAssertFalse(tp.intersects(d)) }
            }}
        }}}
        XCTAssertGreaterThan(count, 500)
    }
}
