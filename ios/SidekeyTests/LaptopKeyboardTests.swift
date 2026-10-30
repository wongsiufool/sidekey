import XCTest
@testable import Sidekey

/// M3f 笔记本键盘模式 (§4.9、附录 appendix-laptop-keymap.md): 键表、发送规则、粘滞修饰键、排版。
final class LaptopKeyboardTests: XCTestCase {

    private func units(_ row: [LaptopKey]) -> Double { row.reduce(0) { $0 + $1.width } }
    private func all(_ p: LaptopPlatform, portrait: Bool) -> [LaptopKey] {
        let r = LaptopKeymap.rows(p, portrait: portrait); return (r.left + r.right).flatMap { $0 }
    }

    // MARK: 键表 (附录)

    func testRowWidthsMatchAppendix() {
        for p in [LaptopPlatform.mac, .windows] {
            let portrait = LaptopKeymap.rows(p, portrait: true)
            XCTAssertEqual(portrait.left.count, 6, "竖屏 6 行 (含 F 键行)")
            for row in portrait.left { XCTAssertEqual(units(row), 14.5, accuracy: 1e-9) }
            let split = LaptopKeymap.rows(p, portrait: false)
            XCTAssertEqual(split.left.count, 5); XCTAssertEqual(split.right.count, 5)
            for row in split.left { XCTAssertEqual(units(row), 7.25, accuracy: 1e-9) }
            for row in split.right { XCTAssertEqual(units(row), 8, accuracy: 1e-9) }
        }
        XCTAssertEqual(all(.mac, portrait: true).count, 77)
        XCTAssertEqual(all(.mac, portrait: false).count, 64)
        XCTAssertEqual(all(.windows, portrait: true).count, 76)
        XCTAssertEqual(all(.windows, portrait: false).count, 64)
    }

    func testStableIDsUniqueWithinEachTable() {
        for p in [LaptopPlatform.mac, .windows] {
            for portrait in [true, false] {
                let ids = all(p, portrait: portrait).map(\.id)
                XCTAssertEqual(Set(ids).count, ids.count, "\(p) portrait=\(portrait)")
            }
        }
    }

    // §4.9 fn 层对照表
    func testFnLayerMatchesSpec() {
        let keys = Dictionary(all(.mac, portrait: true).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func fn(_ id: String) -> LaptopAction? { keys[id]?.fn }
        XCTAssertEqual(fn("k.esc"), .key("`"))
        for i in 1...9 { XCTAssertEqual(fn("k.\(i)"), .key("f\(i)")) }
        XCTAssertEqual(fn("k.0"), .key("f10")); XCTAssertEqual(fn("k.minus"), .key("f11")); XCTAssertEqual(fn("k.equal"), .key("f12"))
        XCTAssertEqual(fn("k.backspace"), .key("delete"))
        XCTAssertEqual(fn("k.left"), .key("home")); XCTAssertEqual(fn("k.right"), .key("end"))
        XCTAssertEqual(fn("k.up"), .key("pageup")); XCTAssertEqual(fn("k.down"), .key("pagedown"))
        XCTAssertEqual(fn("k.a"), .key("a"), "其他键照常发普通键码")
        XCTAssertEqual(keys["k.backspace"]?.normal, .key("backspace"), "Mac 键帽写 delete, 发的是 backspace")
        XCTAssertEqual(keys["k.caps"]?.repeats, false, "⇪ 不连发")
        XCTAssertEqual(keys["k.space"]?.repeats, true)
        XCTAssertEqual(keys["k.1"]?.shiftHint, "!")
    }

    // T-KB-3: 键面和键码固定对应, 不用 primary
    func testModifierCodesPerPlatform() {
        let mac = Set(all(.mac, portrait: true).compactMap(\.modifier))
        XCTAssertEqual(mac, [.shift, .ctrl, .alt, .cmd])
        let win = Set(all(.windows, portrait: true).compactMap(\.modifier))
        XCTAssertEqual(win, [.shift, .ctrl, .alt, .win])
        var s = StickyModifiers()
        s.tap(.cmd, at: 0)
        let snap = s.begin(UUID())
        let c = all(.mac, portrait: true).first { $0.id == "k.c" }!
        XCTAssertEqual(LaptopKeymap.message(for: c, snapshot: snap)?.mods, ["cmd"])
        XCTAssertFalse(LaptopKeymap.message(for: c, snapshot: snap)!.mods.contains("primary"))
    }

    // MARK: 粘滞修饰键 (T-KB-2、T-KB-4)

    func testOnceLockCancel() {
        var s = StickyModifiers()
        s.tap(.shift, at: 0); XCTAssertEqual(s.state(.shift), .once)
        s.tap(.shift, at: 0.3); XCTAssertEqual(s.state(.shift), .locked, "0.4 秒内连点两下锁定")
        s.tap(.shift, at: 5); XCTAssertEqual(s.state(.shift), .off, "再点一下取消")
        s.tap(.cmd, at: 10); s.tap(.cmd, at: 11); XCTAssertEqual(s.state(.cmd), .off, "超过 0.4 秒的第二下 = 取消")
    }

    func testOnceConsumedOnFirstSendLockedPersists() {
        var s = StickyModifiers()
        s.tap(.shift, at: 0)
        s.tap(.cmd, at: 1); s.tap(.cmd, at: 1.2)                    // ⌘ 锁定
        let g = UUID()
        let snap = s.begin(g)
        XCTAssertEqual(snap.mods, [.shift, .cmd])
        let a = all(.mac, portrait: true).first { $0.id == "k.a" }!
        XCTAssertEqual(LaptopKeymap.message(for: a, snapshot: snap)?.mods, ["shift", "cmd"], "修饰键进 mods, 没有单独的按下事件")
        s.didSend(g); s.end(g)
        XCTAssertEqual(s.state(.shift), .off, "一次用掉")
        XCTAssertEqual(s.state(.cmd), .locked, "锁定的保留")
    }

    func testOnceReservedForFirstGestureOnly() {
        var s = StickyModifiers()
        s.tap(.shift, at: 0)
        let first = UUID(), second = UUID()
        XCTAssertEqual(s.begin(first).mods, [.shift])
        XCTAssertEqual(s.begin(second).mods, [], "几根手指同时按键时「一次」只给最先按下的键")
        s.didSend(second)
        XCTAssertEqual(s.state(.shift), .once, "第二个手势发出不会用掉第一个手势的预留")
        s.didSend(first)
        XCTAssertEqual(s.state(.shift), .off)
    }

    func testCancelBeforeSendRefundsAfterSendDoesNot() {
        var s = StickyModifiers()
        s.tap(.alt, at: 0)
        let g = UUID()
        _ = s.begin(g); s.end(g)                                     // 发出消息之前被取消 (§5.2)
        XCTAssertEqual(s.state(.alt), .once, "退还, 还能给下一个键用")
        let h = UUID()
        _ = s.begin(h); s.didSend(h); s.end(h)                       // 已经发出后取消
        XCTAssertEqual(s.state(.alt), .off, "不退还")
    }

    func testFnOnceOnlyAndBackToNormalLayer() {
        var s = StickyModifiers()
        s.tapFn(); XCTAssertTrue(s.fnOnce)
        let g = UUID()
        let snap = s.begin(g)
        let one = all(.mac, portrait: false).first { $0.id == "k.1" }!
        XCTAssertEqual(LaptopKeymap.message(for: one, snapshot: snap)?.code, "f1")
        XCTAssertEqual(LaptopKeymap.message(for: one, snapshot: snap)?.mods, [], "fn 不进 mods")
        s.didSend(g)
        XCTAssertFalse(s.fnOnce, "按完一个键回到普通层")
        XCTAssertEqual(LaptopKeymap.message(for: one, snapshot: s.begin(UUID()))?.code, "1")
        s.tapFn(); s.tapFn(); XCTAssertFalse(s.fnOnce, "fn 不能锁定, 再点一下取消")
    }

    func testRepeatUsesSnapshotTakenAtStart() {
        var s = StickyModifiers()
        s.tap(.shift, at: 0)
        let g = UUID()
        let snap = s.begin(g)
        s.didSend(g)                                                 // 连发第一下
        s.tap(.ctrl, at: 1)                                          // 连发过程中再改修饰键
        let bs = all(.mac, portrait: true).first { $0.id == "k.backspace" }!
        XCTAssertEqual(LaptopKeymap.message(for: bs, snapshot: snap)?.mods, ["shift"], "整串都用开始时的快照")
    }

    func testClearAllAndSummary() {
        var s = StickyModifiers()
        s.tap(.cmd, at: 0)
        XCTAssertEqual(s.summary(.mac)?.text, "⌘ 粘住一次")
        s.tap(.shift, at: 1); s.tap(.shift, at: 1.1); s.tapFn()
        XCTAssertEqual(s.summary(.mac)?.count, 3)
        s.clearAll()
        XCTAssertTrue(s.isEmpty, "切电脑、切模式、后台、断线时全部清空 (含锁定)")
        XCTAssertNil(s.summary(.mac))
    }

    // MARK: 排版 (T-KB-1, 期望值取自 UI 稿画板 13)

    func testPortraitRowsAndUnitWidth() {
        let base = DuoLayout.plan(DuoLayoutTests.portrait(), page: DuoLayoutTests.page(), swapped: false)
        let p = LaptopLayoutPlan.plan(base: base, swapped: false)
        XCTAssertEqual(p.kind, .portrait)
        XCTAssertEqual(p.rowHeight, 45.25, accuracy: 0.01, "6 行各 45.25")
        XCTAssertEqual(p.unit, 37.8, accuracy: 0.01, "单位键宽约 37.8")
        XCTAssertNotNil(p.trackpad)
    }

    func testLandscapeSplitMatchesBoard13() {
        let base = DuoLayout.plan(DuoLayoutTests.landscape(), page: DuoLayoutTests.page(), swapped: false)
        let p = LaptopLayoutPlan.plan(base: base, swapped: false)
        XCTAssertEqual(p.kind, .split)
        XCTAssertEqual(p.unit, 39.19, accuracy: 0.01, "单位键宽约 39.2")
        XCTAssertEqual(p.rowHeight, 50)
        XCTAssertEqual(p.left.width, 321.6, accuracy: 0.1); XCTAssertEqual(p.left.maxX, 451.5, accuracy: 0.01)
        XCTAssertEqual(p.right!.minX, 499.5, accuracy: 0.01)
        XCTAssertEqual(p.left.maxY, 342, accuracy: 0.01)
        XCTAssertEqual(p.trackpad!.minX, 499.5, accuracy: 0.01); XCTAssertEqual(p.trackpad!.minY, 350, accuracy: 0.01)
        XCTAssertEqual(p.trackpad!.maxY, 559, accuracy: 0.01)
        XCTAssertEqual(p.mouseRow!.minY, 567, accuracy: 0.01)
        XCTAssertEqual(p.palm!.minX, 20, accuracy: 0.01)
        // 横屏调换: 键盘不动, 触控板 (连同左右键) 和掌托互换 (T-KB-6)
        let s = LaptopLayoutPlan.plan(base: base, swapped: true)
        XCTAssertEqual(s.left, p.left); XCTAssertEqual(s.right, p.right)
        XCTAssertEqual(s.trackpad!.minX, 20, accuracy: 0.01); XCTAssertEqual(s.palm!.minX, 499.5, accuracy: 0.01)
    }

    func testLandscapeStatusBarHiddenLeftHalfLimitsPitch() {
        // 隐藏状态栏: 右侧 431.5 宽, 但左半不能压到「模式 + 语音」那一列 → 节距由左半定
        let base = DuoLayout.plan(DuoLayoutTests.landscape(statusBar: false), page: DuoLayoutTests.page(), swapped: false)
        let p = LaptopLayoutPlan.plan(base: base, swapped: false)
        XCTAssertEqual(p.kind, .split)
        XCTAssertGreaterThanOrEqual(p.left.minX, 20 + 56 + 6 - 0.01)
        XCTAssertLessThanOrEqual(p.right!.maxX, 931 + 0.01)
        XCTAssertEqual(p.unit, (451.5 - 82 + 6) / 7.25 - 6, accuracy: 0.01)
    }

    func testNarrowWindowTooSmallShowsPlaceholder() {
        // 窄窗口里键盘区 431.5 宽: 单位键宽 (431.5 + 6) / 14.5 − 6 ≈ 24.2 < 28 → 「空间不够」(T-KB-1 / T-KB-6)
        let base = DuoLayout.plan(DuoLayoutTests.splitLeft, page: DuoLayoutTests.page(), swapped: false)
        XCTAssertEqual(LaptopLayoutPlan.plan(base: base, swapped: false).kind, .tooSmall)
    }

    func testFrameRowAlignment() {
        let row = LaptopKeymap.macPortrait[1]
        let f = LaptopLayoutPlan.keyFrames(row, in: CGRect(x: 20, y: 150, width: 629, height: 301.5), rowIndex: 1, unit: 37.8, rowH: 45.25)
        XCTAssertEqual(f.last!.maxX, 20 + 14.5 * 43.8 - 6, accuracy: 0.01, "整行 14.5 单位, 右沿对齐")
        XCTAssertEqual(f[0].minY, 150 + 45.25 + 6, accuracy: 0.01)
    }

    func testPlatformFromReady() {
        XCTAssertEqual(LaptopPlatform(serverPlatform: "Darwin"), .mac)
        XCTAssertEqual(LaptopPlatform(serverPlatform: "Windows"), .windows)
        XCTAssertNil(LaptopPlatform(serverPlatform: "Linux"))
    }

    // §4.9 (M3f 实测后定): 只粘住 Shift 时, 数字和标点直接发上档字符本身 (美式), 不带 shift
    func testShiftOnlyDigitsAndPunctuationSendShiftedCharacter() {
        let keys = Dictionary(all(.mac, portrait: true).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func send(_ id: String, _ setup: (inout StickyModifiers) -> Void) -> (String, [String])? {
            var s = StickyModifiers(); setup(&s)
            let g = UUID(), snap = s.begin(g)
            return LaptopKeymap.message(for: keys[id]!, snapshot: snap).map { ($0.code, $0.mods) }
        }
        let shift: (inout StickyModifiers) -> Void = { $0.tap(.shift, at: 0) }
        XCTAssertEqual(send("k.1", shift)?.0, "!"); XCTAssertEqual(send("k.1", shift)?.1, [])
        XCTAssertEqual(send("k.lbracket", shift)?.0, "{")
        XCTAssertEqual(send("k.quote", shift)?.0, "\"")
        XCTAssertEqual(send("k.grave", shift)?.0, "~")
        XCTAssertEqual(send("k.backslash", shift)?.0, "|")
        // 字母照旧: 字母 + shift
        XCTAssertEqual(send("k.a", shift)?.0, "a"); XCTAssertEqual(send("k.a", shift)?.1, ["shift"])
        // Shift 和其他修饰键一起: 照旧发键码 + 全部修饰键 (⌘⇧3)
        let cmdShift: (inout StickyModifiers) -> Void = { $0.tap(.shift, at: 0); $0.tap(.cmd, at: 1) }
        XCTAssertEqual(send("k.3", cmdShift)?.0, "3"); XCTAssertEqual(send("k.3", cmdShift)?.1, ["shift", "cmd"])
        // fn 层优先: fn + Shift + 1 = f1 + [shift]
        let fnShift: (inout StickyModifiers) -> Void = { $0.tap(.shift, at: 0); $0.tapFn() }
        XCTAssertEqual(send("k.1", fnShift)?.0, "f1"); XCTAssertEqual(send("k.1", fnShift)?.1, ["shift"])
        // 锁定的 Shift 也算「只有 Shift」
        let locked: (inout StickyModifiers) -> Void = { $0.tap(.shift, at: 0); $0.tap(.shift, at: 0.2) }
        XCTAssertEqual(send("k.2", locked)?.0, "@")
    }

    func testShiftConsumedThenBackToNormal() {
        let one = all(.mac, portrait: true).first { $0.id == "k.1" }!
        var s = StickyModifiers()
        s.tap(.shift, at: 0)
        let g = UUID()
        XCTAssertEqual(LaptopKeymap.message(for: one, snapshot: s.begin(g))?.code, "!")
        s.didSend(g); s.end(g)
        XCTAssertEqual(s.state(.shift), .off, "Shift 照样算用掉")
        XCTAssertEqual(LaptopKeymap.message(for: one, snapshot: s.begin(UUID()))?.code, "1", "回到普通层")
    }
}
