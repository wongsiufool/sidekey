import XCTest
@testable import Sidekey

/// 输入安全 (§5.2、§4.7「输入归属」): T-IN-1 / T-IN-2 / T-IN-4 的逻辑部分, T-MW-2 的仲裁部分。
@MainActor
final class InputSafetyTests: XCTestCase {
    private let w1 = UUID(), w2 = UUID(), pcA = UUID(), pcB = UUID()
    private func at(_ s: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_000_000 + s) }

    // MARK: 仲裁器 (T-MW-2)
    func testArbiterSingleWindowPairsDownUp() {
        var a = MouseHoldArbiter()
        XCTAssertTrue(a.down(window: w1, computer: pcA, button: "left"))
        XCTAssertTrue(a.up(window: w1, computer: pcA, button: "left"))
        XCTAssertFalse(a.up(window: w1, computer: pcA, button: "left"), "没按着就松开: 不发")
    }

    func testArbiterMultipleWindowsOnlyFirstDownAndLastUp() {
        var a = MouseHoldArbiter()
        XCTAssertTrue(a.down(window: w1, computer: pcA, button: "left"))
        XCTAssertFalse(a.down(window: w2, computer: pcA, button: "left"), "B 也按住: 不发新的 down")
        XCTAssertFalse(a.up(window: w1, computer: pcA, button: "left"), "A 先松开: 仍有 B 按着, 不发 up")
        XCTAssertTrue(a.up(window: w2, computer: pcA, button: "left"), "最后一个松开才发 up")
    }

    func testArbiterClickSuppressedWhileOtherWindowHolds() {
        var a = MouseHoldArbiter()
        _ = a.down(window: w1, computer: pcA, button: "left")
        XCTAssertFalse(a.canClick(window: w2, computer: pcA, button: "left"))
        XCTAssertTrue(a.canClick(window: w2, computer: pcB, button: "left"), "别的电脑不受影响")
        XCTAssertTrue(a.canClick(window: w1, computer: pcA, button: "right"), "别的键不受影响")
    }

    // MARK: 冻结计时 (§5.2 第 4 步)
    func testFreezeOnlyFirstChangeInterruptsAndThawsAfter150ms() {
        var f = FreezeTimer()
        XCTAssertTrue(f.noteChange(at: at(0)))
        XCTAssertFalse(f.noteChange(at: at(0.05)), "连续变化只算一次")
        XCTAssertFalse(f.thawIfStable(at: at(0.1)), "最后一次变化后不足 150 ms 不恢复")
        XCTAssertFalse(f.thawIfStable(at: at(0.19)))
        XCTAssertTrue(f.thawIfStable(at: at(0.20)))
        XCTAssertTrue(f.noteChange(at: at(5)), "解冻后的新变化又是新的一轮")
    }

    // MARK: 输入守卫 (假传输层记录「发了什么」)
    @MainActor final class FakeTransport: InputTransport {
        var computer: UUID?
        var log: [String] = []
        var transportComputerID: UUID? { computer }
        func transportMouseDown(button: String) { log.append("down:\(button)") }
        func transportMouseUp(button: String) { log.append("up:\(button)") }
        func transportMouseClick(button: String) { log.append("click:\(button)") }
        func transportDiscardPendingMotion() { log.append("discard") }
    }

    private func makeGuard(_ t: FakeTransport, window: UUID, computer: UUID, box: InputGuard.ArbiterBox,
                           clock: @escaping () -> Date) -> InputGuard {
        InputGuard(windowID: window, computerID: { computer }, transport: t, arbiter: box, now: clock)
    }

    // T-IN-1 / T-IN-4: 按住左键拖动时发生布局变化 → down 与 up 成对, 立即 (同步) 发出 up, 并丢弃待发位移、停连发。
    func testInterruptReleasesHeldMouseImmediatelyAndPairs() {
        let t = FakeTransport(); t.computer = pcA
        var clock = at(0)
        let g = makeGuard(t, window: w1, computer: pcA, box: .init(), clock: { clock })
        var repeatStopped = 0
        g.register(UUID()) { repeatStopped += 1 }
        g.mouseDown(button: "left")
        g.interrupt()                                  // 不经过任何防抖 / 异步等待
        XCTAssertEqual(t.log, ["down:left", "up:left", "discard"], "旋转 / 切后台时 up 同步发出, 成对, 并丢弃待发位移")
        XCTAssertEqual(repeatStopped, 1, "T-IN-2: 连发立即停止")
        XCTAssertTrue(g.frozen)
        // 连续变化 (拖动窗口边缘) 只执行一次 1–3 步
        clock = at(0.05); g.interrupt()
        XCTAssertEqual(t.log.count, 3)
        // 稳定后恢复
        clock = at(0.30); g.thawIfStable()
        XCTAssertFalse(g.frozen)
    }

    // 真实连接冒烟发现: 一指按左键、一指在触控板上拖, 两指同时抬起时左键漏收 .ended → 电脑端左键一直按着。
    // 兜底: 窗口确认没有手指时, 还按着的鼠标键立刻松开 (成对), 按压状态作废, 之后迟到的松开不会再发 up。
    func testAllFingersLiftedReleasesOrphanMouseHold() {
        let t = FakeTransport(); t.computer = pcA
        let g = makeGuard(t, window: w1, computer: pcA, box: .init(), clock: { self.at(0) })
        let src = UUID(); var cancelled = 0
        g.register(src) { cancelled += 1 }
        g.touchCountChanged(2)
        g.mouseDown(button: "left", source: src)
        g.touchCountChanged(1)
        XCTAssertEqual(t.log, ["down:left"], "还有手指在屏幕上: 不动")
        g.touchCountChanged(0)
        XCTAssertEqual(t.log, ["down:left", "up:left"])
        XCTAssertEqual(cancelled, 1, "按键的按压状态作废")
        g.mouseUp(button: "left", source: src)           // 迟到的松开
        XCTAssertEqual(t.log, ["down:left", "up:left"], "不重复发 up")
        g.touchCountChanged(0)
        XCTAssertEqual(cancelled, 1, "没有按住的键时不打扰其他输入源")
    }

    // 触摸信息未知时 (跟踪器丢了触摸) 不能据「0 根手指」判断松开 —— 那次已经由 touchTrackingLost 的中断松开过。
    func testUnknownTouchesDoNotTriggerOrphanRelease() {
        let t = FakeTransport(); t.computer = pcA
        let g = makeGuard(t, window: w1, computer: pcA, box: .init(), clock: { self.at(0) })
        g.touchTrackingLost()
        t.log = []
        g.touchesResynced(1)
        g.thawIfStable()
        XCTAssertTrue(t.log.isEmpty)
    }

    // 切换电脑: 残留的按住不能发到新电脑 (旧连接断开时电脑端会松开, F18)。
    func testResidualHoldNotSentToNewComputer() {
        let t = FakeTransport(); t.computer = pcA
        let g = makeGuard(t, window: w1, computer: pcA, box: .init(), clock: { self.at(0) })
        g.mouseDown(button: "left")
        t.computer = pcB                                // 连接已经切到 B
        g.interrupt()
        XCTAssertFalse(t.log.contains("up:left"), "不能把 up 发到新电脑")
    }

    // 两个窗口同时按住同一个键: 只有一次 down; A 先松开不发 up; B 松开才发一次。
    func testTwoWindowsHoldSameButtonOnSameComputer() {
        let t = FakeTransport(); t.computer = pcA
        let box = InputGuard.ArbiterBox()
        let a = makeGuard(t, window: w1, computer: pcA, box: box, clock: { self.at(0) })
        let b = makeGuard(t, window: w2, computer: pcA, box: box, clock: { self.at(0) })
        a.mouseDown(button: "left"); b.mouseDown(button: "left")
        XCTAssertEqual(t.log, ["down:left"])
        a.teardown()                                    // A 关闭: 仍没有 up
        XCTAssertEqual(t.log, ["down:left"])
        b.mouseUp(button: "left")
        XCTAssertEqual(t.log, ["down:left", "up:left"])
    }

    // B 的单击在 A 按住时不发送。
    func testClickSuppressedWhenOtherWindowHolds() {
        let t = FakeTransport(); t.computer = pcA
        let box = InputGuard.ArbiterBox()
        let a = makeGuard(t, window: w1, computer: pcA, box: box, clock: { self.at(0) })
        let b = makeGuard(t, window: w2, computer: pcA, box: box, clock: { self.at(0) })
        a.mouseDown(button: "left")
        b.mouseClick(button: "left")
        XCTAssertEqual(t.log, ["down:left"])
    }

    // MARK: 审计修复 (Codex M1 阻断 4/5, 重要 5, 小问题 teardown)

    // 解冻要同时满足: 布局稳定 + 所有手指离开屏幕。
    func testThawWaitsForAllFingersLifted() {
        var f = FreezeTimer()
        _ = f.noteChange(at: at(0))
        XCTAssertFalse(f.thawIfStable(at: at(1), touchesActive: true), "稳定了但手指还在屏幕上: 不解冻")
        XCTAssertTrue(f.thawIfStable(at: at(1), touchesActive: false))
    }

    func testGuardStaysFrozenWhileTouchesActiveThenThaws() {
        let t = FakeTransport()
        var clock = at(0)
        let g = makeGuard(t, window: w1, computer: pcA, box: .init(), clock: { clock })
        g.touchCountChanged(1)
        g.interrupt()
        clock = at(5); g.thawIfStable()
        XCTAssertTrue(g.frozen, "手指还没抬起: 一直冻结")
        g.touchCountChanged(0)                           // 最后一根手指抬起 → 立即检查 → 解冻
        XCTAssertFalse(g.frozen)
    }

    // 冻结期间发送入口拒绝新输入。
    func testFrozenRejectsNewMouseInput() {
        let t = FakeTransport(); t.computer = pcA
        let g = makeGuard(t, window: w1, computer: pcA, box: .init(), clock: { self.at(0) })
        g.interrupt()
        g.mouseDown(button: "left"); g.mouseClick(button: "right")
        XCTAssertEqual(t.log, ["discard"], "冻结期间不发 down / click")
    }

    // 同一窗口两个输入源 (例如两个左键按钮) 同时按住同一个键: 第一个松开不发 up, 最后一个松开才发。
    func testTwoSourcesInSameWindow() {
        let t = FakeTransport(); t.computer = pcA
        let g = makeGuard(t, window: w1, computer: pcA, box: .init(), clock: { self.at(0) })
        let s1 = UUID(), s2 = UUID()
        g.mouseDown(button: "left", source: s1)
        g.mouseDown(button: "left", source: s2)
        XCTAssertEqual(t.log, ["down:left"], "窗口里第二个输入源不重复发 down")
        g.mouseUp(button: "left", source: s1)
        XCTAssertEqual(t.log, ["down:left"], "另一根手指还按着: 不发 up")
        g.mouseUp(button: "left", source: s2)
        XCTAssertEqual(t.log, ["down:left", "up:left"])
    }

    // 中断时不管有几个输入源, 只松一次。
    func testInterruptReleasesOnceForMultipleSources() {
        let t = FakeTransport(); t.computer = pcA
        let g = makeGuard(t, window: w1, computer: pcA, box: .init(), clock: { self.at(0) })
        g.mouseDown(button: "left", source: UUID()); g.mouseDown(button: "left", source: UUID())
        g.interrupt()
        XCTAssertEqual(t.log.filter { $0 == "up:left" }.count, 1)
    }

    // teardown 清冻结状态: 重新挂载后不会一直冻结。
    func testTeardownClearsFrozenState() {
        let t = FakeTransport()
        let g = makeGuard(t, window: w1, computer: pcA, box: .init(), clock: { self.at(0) })
        g.touchCountChanged(2)
        g.interrupt()
        XCTAssertTrue(g.frozen)
        g.teardown()
        XCTAssertFalse(g.frozen)
        g.interrupt()                                    // 重新挂载后的第一次变化仍是新的一轮 (会再次执行 1–3 步)
        XCTAssertTrue(g.frozen)
    }

    // MARK: 普通键按压生命周期: 取消后松手不再补发
    func testPressLifecycleCancelledPressDoesNotFireOnLateUp() {
        var p = PressLifecycle()
        XCTAssertTrue(p.down(enabled: true, frozen: false))
        p.cancel()                                       // 布局变化 / 滑动翻页 / 被系统取消
        XCTAssertFalse(p.up(enabled: true), "取消之后后到的 .ended 不能再触发动作")
    }

    func testPressLifecycleNormalTapFiresOnce() {
        var p = PressLifecycle()
        XCTAssertTrue(p.down(enabled: true, frozen: false))
        XCTAssertTrue(p.up(enabled: true))
        XCTAssertFalse(p.up(enabled: true), "同一次按压只触发一次")
    }

    func testPressLifecycleRepeatedPressDoesNotAddTapOnUp() {
        var p = PressLifecycle()
        _ = p.down(enabled: true, frozen: false)
        p.markRepeating()
        XCTAssertFalse(p.up(enabled: true), "真连发过: 松手不再补一次轻点")
    }

    func testPressLifecycleRejectsWhenFrozenOrDisabled() {
        var p = PressLifecycle()
        XCTAssertFalse(p.down(enabled: true, frozen: true), "冻结期间拒绝新输入")
        XCTAssertFalse(p.down(enabled: false, frozen: false), "未连接 / 禁用不响应")
        XCTAssertFalse(p.up(enabled: true))
    }

    // MARK: 审计第二轮: 触摸计数器不参与互斥 / 复位与摘除都上报
    func testTouchCountRecognizerDoesNotParticipateInExclusion() {
        let r = TouchCountRecognizer(target: nil, action: nil)
        let pan = UIPanGestureRecognizer(target: nil, action: nil)
        let longPress = UILongPressGestureRecognizer(target: nil, action: nil)
        for other in [pan, longPress] as [UIGestureRecognizer] {
            XCTAssertFalse(r.canBePrevented(by: other), "别的识别器识别成功不能把计数器置为失败")
            XCTAssertFalse(r.canPrevent(other), "计数器也不能阻止别的识别器")
            XCTAssertFalse(r.shouldRequireFailure(of: other))
            XCTAssertFalse(r.shouldBeRequiredToFail(by: other))
            XCTAssertTrue(r.gestureRecognizer(r, shouldRecognizeSimultaneouslyWith: other))
            XCTAssertFalse(r.gestureRecognizer(r, shouldRequireFailureOf: other))
            XCTAssertFalse(r.gestureRecognizer(r, shouldBeRequiredToFailBy: other))
        }
        XCTAssertFalse(r.cancelsTouchesInView)
        XCTAssertFalse(r.delaysTouchesBegan)
        XCTAssertFalse(r.delaysTouchesEnded)
    }

    func testTouchCountRecognizerReportsZeroOnResetAndDetach() {
        let r = TouchCountRecognizer(target: nil, action: nil)
        var reported: [Int] = []
        r.onCount = { reported.append($0) }
        r.reset()
        XCTAssertEqual(reported.last, 0, "复位后不再跟踪任何手指: 上报 0, 不留下过期计数")
        reported.removeAll()
        let view = UIView(); view.addGestureRecognizer(r)
        r.detach()
        XCTAssertEqual(reported.last, 0, "摘除 / 重新挂载前先上报 0")
        XCTAssertNil(r.view, "摘除后不再挂在视图上")
        XCTAssertEqual(r.trackedTouchCount, 0)
    }

    // MARK: 审计第三轮: 每一次按压都必须以 up 或 cancel 之一结束
    func testKeyPressEndActionAlwaysEndsWithUpOrCancel() {
        typealias T = KeyPressTracker
        XCTAssertEqual(T.endAction(cancelOnMove: true, alreadyMoved: false, movedTooFarNow: false), .up, "没移动: 正常松手")
        XCTAssertEqual(T.endAction(cancelOnMove: true, alreadyMoved: false, movedTooFarNow: true), .cancel,
                       "没收到越过阈值的 .changed、到 .ended 才发现移动太远: 必须取消, 不能既不松手也不取消")
        XCTAssertEqual(T.endAction(cancelOnMove: true, alreadyMoved: true, movedTooFarNow: true), .none, "中途已取消: 不再重复")
        XCTAssertEqual(T.endAction(cancelOnMove: false, alreadyMoved: false, movedTooFarNow: true), .up, "鼠标左键: 移动不取消, 松手就是松手")
        // 配合 PressLifecycle: cancel 之后 pressed 复位, 不会一直为 true
        var p = PressLifecycle()
        XCTAssertTrue(p.down(enabled: true, frozen: false))
        p.cancel()
        XCTAssertFalse(p.pressed)
    }

    // MARK: 审计第三轮(系统性): 一次触摸的所有结束状态
    /// 模拟宿主 (KeyCapButton / MouseKeyButton 的核心): KeyPressTracker.Machine 给出动作, PressLifecycle 做状态。
    private struct Host {
        var machine = KeyPressTracker.Machine()
        var life = PressLifecycle()
        var cancelOnMove = true
        var enabled = true
        var frozen = false
        var taps = 0, cancels = 0, downs = 0, ups = 0

        mutating func feed(_ events: [KeyPressTracker.Machine.Event]) {
            for e in events {
                for a in machine.handle(e, cancelOnMove: cancelOnMove) {
                    switch a {
                    case .down: if life.down(enabled: enabled, frozen: frozen) { downs += 1 }
                    case .up: ups += 1; if life.up(enabled: enabled) { taps += 1 }
                    case .cancel: cancels += 1; life.cancel()
                    }
                }
            }
        }
    }

    func testEveryTouchEndsWithUpOrCancel() {
        typealias E = KeyPressTracker.Machine.Event
        let paths: [(String, [E], expectTap: Int, expectCancel: Bool)] = [
            ("began→ended", [.began, .ended(tooFar: false)], 1, false),
            ("began→changed(近)→ended", [.began, .changed(tooFar: false), .ended(tooFar: false)], 1, false),
            ("began→changed(远)→ended (滑动翻页)", [.began, .changed(tooFar: true), .ended(tooFar: true)], 0, true),
            ("began→ended 才发现移动太远 (没有 changed)", [.began, .ended(tooFar: true)], 0, true),
            ("began→cancelled", [.began, .cancelled], 0, true),
            ("began→changed(远)→cancelled", [.began, .changed(tooFar: true), .cancelled], 0, true),
            ("began→cancelled→(迟到的)ended", [.began, .cancelled, .ended(tooFar: false)], 0, true),
        ]
        for (name, events, tap, cancel) in paths {
            var h = Host()
            h.feed(events)
            XCTAssertEqual(h.taps, tap, "\(name): 触发次数")
            XCTAssertEqual(h.cancels > 0, cancel, "\(name): 取消")
            XCTAssertFalse(h.life.pressed, "\(name): 结束后 pressed 必须复位 (否则连发停不下来)")
            XCTAssertTrue(h.ups + h.cancels >= 1, "\(name): 必须以 up 或 cancel 结束")
            XCTAssertLessThanOrEqual(h.taps, 1, "\(name): 同一次触摸最多触发一次")
        }
    }

    func testRepeatCannotRunAfterEnd() {
        // 连发循环的条件是 pressed; 任何结束路径之后 pressed 都是 false, 循环必然退出
        typealias E = KeyPressTracker.Machine.Event
        for events in [[E.began, .ended(tooFar: false)], [.began, .cancelled], [.began, .ended(tooFar: true)], [.began, .changed(tooFar: true)]] {
            var h = Host(); h.feed(events)
            if events.contains(.changed(tooFar: true)) && !events.contains(.ended(tooFar: true)) { XCTAssertFalse(h.life.pressed, "滑动取消后不再连发") }
            else { XCTAssertFalse(h.life.pressed) }
        }
    }

    func testNewTouchAfterCancelIsIndependent() {
        typealias E = KeyPressTracker.Machine.Event
        var h = Host()
        h.feed([.began, .cancelled])
        h.feed([.began, .ended(tooFar: false)])                       // 取消之后的新一次触摸不受影响
        XCTAssertEqual(h.taps, 1)
        XCTAssertEqual(h.downs, 2)
    }

    func testMouseLeftDoesNotCancelOnMoveButStillPairs() {
        typealias E = KeyPressTracker.Machine.Event
        var h = Host(); h.cancelOnMove = false
        h.feed([.began, .changed(tooFar: true), .changed(tooFar: true), .ended(tooFar: true)])
        XCTAssertEqual(h.cancels, 0, "鼠标左键: 手指在键上滑动仍算按住")
        XCTAssertEqual(h.ups, 1, "松手发 up (与 down 成对)")
        h = Host(); h.cancelOnMove = false
        h.feed([.began, .cancelled])
        XCTAssertEqual(h.cancels, 1, "系统取消时必须松开 (否则鼠标键一直按着)")
    }

    func testFrozenAtBeganRejectsAndLaterEndDoesNothing() {
        typealias E = KeyPressTracker.Machine.Event
        var h = Host(); h.frozen = true
        h.feed([.began, .ended(tooFar: false)])
        XCTAssertEqual(h.downs, 0)
        XCTAssertEqual(h.taps, 0, "冻结期间按下被拒绝, 松手也不能补发")
    }

    // MARK: 触摸与冻结 (手指数 / 丢失 / 多指)
    func testFreezeWaitsForEveryFingerWhenTouchesOverlapTrackpadDrag() {
        let t = FakeTransport()
        var clock = at(0)
        let g = makeGuard(t, window: w1, computer: pcA, box: .init(), clock: { clock })
        g.touchCountChanged(2)                  // 一根在键上, 一根在触控板上拖动 / 滚动
        g.interrupt()
        clock = at(1); g.touchCountChanged(1); XCTAssertTrue(g.frozen, "还有一根手指在触控板上: 不解冻")
        g.touchCountChanged(0); XCTAssertFalse(g.frozen, "最后一根抬起才解冻")
    }

    // 丢了触摸信息: 旧触摸没有确认结束之前, 不管等多久都不能恢复输入 (不靠计时放行)。
    func testTrackingLostNeverThawsByTimeout() {
        let t = FakeTransport()
        var clock = at(0)
        let g = makeGuard(t, window: w1, computer: pcA, box: .init(), clock: { clock })
        g.touchCountChanged(1)
        g.interrupt()
        g.touchTrackingLost()
        for s in [0.5, 1.2, 30, 600] as [TimeInterval] { clock = at(s); g.thawIfStable(); XCTAssertTrue(g.frozen, "\(s) s 后仍应冻结") }
    }

    // 新手指来了又走, 只说明新手指抬起了, 不能证明旧手指已经离开。
    func testNewFingerDownThenUpDoesNotProveOldFingerGone() {
        let t = FakeTransport()
        var clock = at(0)
        let g = makeGuard(t, window: w1, computer: pcA, box: .init(), clock: { clock })
        g.interrupt()
        g.touchTrackingLost()
        g.touchCountChanged(1); clock = at(0.2); g.touchCountChanged(0); clock = at(0.5); g.thawIfStable()
        XCTAssertTrue(g.frozen, "普通上报不能解除未知")
    }

    // 重新采集到完整触摸状态后才可信: 0 → 解冻; >0 → 等它们抬起。
    func testResyncRestoresTrustedState() {
        let t = FakeTransport()
        var clock = at(0)
        let g = makeGuard(t, window: w1, computer: pcA, box: .init(), clock: { clock })
        g.interrupt(); g.touchTrackingLost()
        clock = at(1); g.touchesResynced(1)
        XCTAssertTrue(g.frozen, "旧手指其实还在 (allTouches 里有): 继续冻结")
        g.touchCountChanged(0)
        XCTAssertFalse(g.frozen, "它抬起 (可信计数归零) 且布局已稳定: 解冻")

        let g2 = makeGuard(FakeTransport(), window: w2, computer: pcA, box: .init(), clock: { clock })
        g2.interrupt(); g2.touchTrackingLost()
        clock = at(5); g2.touchesResynced(0)
        XCTAssertFalse(g2.frozen, "完整状态显示没有手指: 解冻")
    }

    // 丢失发生时还没冻结: 要先结束当前输入 (松鼠标键), 再冻结; 新的点击在冻结里被拒绝。
    func testLostWhileNotFrozenReleasesAndFreezes() {
        let t = FakeTransport()
        let clock = at(0)
        let g = makeGuard(t, window: w1, computer: pcA, box: .init(), clock: { clock })
        g.mouseDown(button: "left")
        XCTAssertFalse(g.frozen)
        g.touchTrackingLost()
        XCTAssertTrue(g.frozen)
        XCTAssertTrue(t.log.contains("up:left"), "按着的左键被松开")
        let before = t.log.count
        g.mouseClick(button: "left"); g.mouseDown(button: "left")
        XCTAssertEqual(t.log.count, before, "冻结期间新的点击 / 按下被拒绝")
    }

    // 连续多次丢失 (重新挂载后再次丢失) 仍然是未知。
    func testRepeatedLostStaysUnknownUntilResync() {
        let t = FakeTransport()
        var clock = at(0)
        let g = makeGuard(t, window: w1, computer: pcA, box: .init(), clock: { clock })
        g.interrupt(); g.touchTrackingLost()
        clock = at(2); g.touchTrackingLost(); g.touchCountChanged(0)
        clock = at(10); g.thawIfStable()
        XCTAssertTrue(g.frozen)
        g.touchesResynced(0)
        XCTAssertFalse(g.frozen)
    }

    // MARK: 识别器 → 守卫 适配层 (快照校正)
    private func snap(_ id: NSObject, _ phase: UITouch.Phase, inWindow: Bool = true) -> TouchCountRecognizer.TouchSnapshot {
        .init(id: ObjectIdentifier(id), phase: phase, inThisWindow: inWindow)
    }
    private func wired(_ g: InputGuard) -> TouchCountRecognizer {
        let r = TouchCountRecognizer(target: nil, action: nil)
        r.onCount = { g.touchCountChanged($0) }
        r.onTrackingLost = { g.touchTrackingLost() }
        r.onResync = { g.touchesResynced($0) }
        return r
    }

    // 旧触摸 A 丢失; 下一个事件的快照里有 A + 新手指 B (重新采集 = 2); A 的结束事件收不到;
    // B 结束 (快照里只剩 B 的 ended, A 已不在) → 0 → 解冻; 之后的点击继续按快照校正。
    func testMissingEndEventForOldTouchStillRecovers() {
        let t = FakeTransport()
        var clock = at(0)
        let g = makeGuard(t, window: w1, computer: pcA, box: .init(), clock: { clock })
        let r = wired(g)
        let a = NSObject(), b = NSObject(), c = NSObject()
        r.apply(snapshot: [snap(a, .began)])                         // 先挂上: 第一次快照
        g.interrupt()
        r.activeIDs = [ObjectIdentifier(a)]
        r.reset()                                                    // 强制复位: 手指还在 → 丢失
        XCTAssertTrue(g.needsRetap)
        r.apply(snapshot: [snap(a, .stationary), snap(b, .began)])   // 重新采集为 2
        XCTAssertTrue(g.frozen); XCTAssertFalse(g.needsRetap)
        clock = at(1)
        r.apply(snapshot: [snap(b, .ended)])                         // B 结束, A 的结束事件没收到, 快照里 A 已不在
        XCTAssertFalse(g.frozen, "旧手指不在快照里了: 计数纠正为 0, 解冻")
        // 之后又一次点击: 仍按快照校正 (不会回到只靠增减)
        r.apply(snapshot: [snap(c, .began)]); XCTAssertEqual(r.trackedTouchCount, 1)
        r.apply(snapshot: [snap(c, .ended)]); XCTAssertEqual(r.trackedTouchCount, 0)
    }

    // 旧手指在重新采集之后消失、但计数停在 1: 下一次点击的快照里它不在 → 校正到准确值 (不会一直冻结)。
    func testCountCorrectedByLaterSnapshotsAfterResync() {
        let t = FakeTransport()
        var clock = at(0)
        let g = makeGuard(t, window: w1, computer: pcA, box: .init(), clock: { clock })
        let r = wired(g)
        let a = NSObject(), b = NSObject(), c = NSObject()
        g.interrupt(); g.touchTrackingLost()
        r.apply(snapshot: [snap(a, .stationary), snap(b, .began)])   // 2
        r.apply(snapshot: [snap(a, .stationary), snap(b, .ended)])   // A 还在 (快照里), B 抬起 → 1
        XCTAssertTrue(g.frozen)
        clock = at(2)
        r.apply(snapshot: [snap(c, .began)])                         // A 已离开且没有事件; 新点击的快照里没有 A
        r.apply(snapshot: [snap(c, .ended)])
        XCTAssertFalse(g.frozen, "最终计数 0: 解冻")
    }

    // 快照里含别的窗口的触摸: 不计入本窗口。
    func testSnapshotFiltersOtherWindows() {
        let r = TouchCountRecognizer(target: nil, action: nil)
        var counts: [Int] = []
        r.onResync = { counts.append($0) }
        r.apply(snapshot: [snap(NSObject(), .began), snap(NSObject(), .began, inWindow: false), snap(NSObject(), .stationary, inWindow: false)])
        XCTAssertEqual(counts, [1])
        XCTAssertEqual(r.trackedTouchCount, 1)
    }

    func testNeedsRetapHintLifecycle() {
        let t = FakeTransport()
        let g = makeGuard(t, window: w1, computer: pcA, box: .init(), clock: { self.at(0) })
        XCTAssertFalse(g.needsRetap)
        g.touchTrackingLost(); XCTAssertTrue(g.needsRetap)
        g.touchesResynced(0); XCTAssertFalse(g.needsRetap)
        g.touchTrackingLost(); g.teardown(); XCTAssertFalse(g.needsRetap)
    }

    // 新建的识别器不知道挂载时屏幕上有没有手指, 第一次触摸事件要按 allTouches 校正。
    func testNewRecognizerStartsNeedingResync() {
        let r = TouchCountRecognizer(target: nil, action: nil)
        XCTAssertTrue(r.needsResync)
        XCTAssertTrue(TouchCountRecognizer.isActive(.began))
        XCTAssertTrue(TouchCountRecognizer.isActive(.stationary))
        XCTAssertFalse(TouchCountRecognizer.isActive(.ended))
        XCTAssertFalse(TouchCountRecognizer.isActive(.cancelled))
    }

    func testRecognizerResetWithFingersDownReportsLostNotZero() {
        let r = TouchCountRecognizer(target: nil, action: nil)
        var counts: [Int] = [], lost = 0
        r.onCount = { counts.append($0) }
        r.onTrackingLost = { lost += 1 }
        r.activeIDs = [ObjectIdentifier(NSObject()), ObjectIdentifier(NSObject())]       // 两根手指还在屏幕上
        r.reset()
        XCTAssertEqual(lost, 1, "手指还没抬起就被复位: 上报「丢失」")
        XCTAssertTrue(counts.isEmpty, "不能上报 0")
        XCTAssertEqual(r.trackedTouchCount, 0)
        r.reset()
        XCTAssertEqual(counts.last, 0, "确认没有活跃触摸时的复位才上报 0")
        XCTAssertEqual(lost, 1)
    }

    func testRecognizerDetachWithFingersDownReportsLost() {
        let r = TouchCountRecognizer(target: nil, action: nil)
        var lost = 0, zero = 0
        r.onTrackingLost = { lost += 1 }
        r.onCount = { if $0 == 0 { zero += 1 } }
        let v = UIView(); v.addGestureRecognizer(r)
        r.activeIDs = [ObjectIdentifier(NSObject())]
        r.detach()
        XCTAssertEqual(lost, 1, "移除 / 重新挂载时手指仍在屏幕上: 丢失, 不是 0")
        XCTAssertEqual(zero, 0)
        // 重新挂载后没有活跃手指时摘除: 上报 0
        let r2 = TouchCountRecognizer(target: nil, action: nil)
        var zero2 = 0; r2.onCount = { if $0 == 0 { zero2 += 1 } }
        UIView().addGestureRecognizer(r2)
        r2.detach()
        XCTAssertEqual(zero2, 1)
    }

    // T-IN-1 [M3]: 按住左键拖动时调换 / 进出单区 / 开合, 各 20 次 (逻辑部分)。
    // 调换、单区切换在点击时直接 interrupt; 开合 (以及调换后的重排) 由层 2 防抖在「影响布局的结果」变化时发 interruptNow。
    // 每次都检查: down / up 成对、结束后没有按着的键、没有重复命令。
    func testInnerLayoutChangesWhileHoldingMouse20Times() {
        let t = FakeTransport(); t.computer = pcA
        var clock = at(0)
        let g = makeGuard(t, window: w1, computer: pcA, box: .init(), clock: { clock })
        var stab = LayoutStabilizer<DuoStableContext>(posture: { $0.posture })
        let flat = DuoStableContext(DuoLayoutTests.landscape())
        let book = DuoStableContext(DuoLayoutTests.landscape(hinge: .partiallyOpen, active: true))
        let folded = DuoStableContext(DuoObservation(screen: .inner, window: CGSize(width: 669, height: 951),
                                                     safe: DuoInsets(top: 0, left: 0, bottom: 34, right: 0),
                                                     regions: DuoLayoutTests.portrait(statusBar: false).regions, hinge: .fullyOpen))
        _ = stab.observe(flat, at: 0)
        var tick: TimeInterval = 0
        for kind in ["swap", "singleZone", "fold"] {
            for _ in 0..<20 {
                tick += 1; clock = at(tick)
                t.log.removeAll()
                g.mouseDown(button: "left")
                switch kind {
                case "swap", "singleZone":
                    g.interrupt()                                         // toggleSwap / setSingleZone 都先 interrupt
                default:
                    let next = stab.stable == flat ? (Int(tick) % 2 == 0 ? book : folded) : flat
                    if stab.observe(next, at: tick) == .interruptNow { g.interrupt() }
                    XCTAssertNotNil(stab.tick(at: tick + 0.31), "稳定后换布局")
                }
                XCTAssertEqual(t.log, ["down:left", "up:left", "discard"], "\(kind): down / up 成对, 没有重复命令")
                g.mouseUp(button: "left")                                 // 手指稍后抬起: 不能再发第二次 up
                XCTAssertEqual(t.log.filter { $0.hasPrefix("up:") }.count, 1, "\(kind): 没有重复的 up")
                clock = at(tick + 0.5); g.touchCountChanged(0); g.thawIfStable()
                XCTAssertFalse(g.frozen, "\(kind): 稳定且手指全部离开后恢复输入")
            }
        }
    }
}
