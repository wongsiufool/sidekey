import XCTest
@testable import Sidekey

/// 连接状态机 (§4.7 v1.7, T-MW-9): 窗口 ID 集合 + 10 分钟后台空闲断开 + 不自动重连。
final class ConnectionLifecycleTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let w1 = UUID(), w2 = UUID(), pc = UUID(), pc2 = UUID()
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    func testFirstUserConnectsLastUserDisconnects() {
        var l = ConnectionLifecycle()
        XCTAssertEqual(l.attach(window: w1, to: pc, foreground: true, now: t0), [.connect(pc)])
        XCTAssertEqual(l.attach(window: w2, to: pc, foreground: true, now: t0), [], "第二个使用者不重复连接")
        XCTAssertEqual(l.detach(window: w1, from: pc, now: t0), [])
        XCTAssertEqual(l.detach(window: w2, from: pc, now: t0), [.disconnect(pc)])
    }

    func testBackgroundIdleDisconnectAfterTenMinutesKeepsUsers() {
        var l = ConnectionLifecycle()
        _ = l.attach(window: w1, to: pc, foreground: true, now: t0)
        XCTAssertEqual(l.setForeground(window: w1, computer: pc, isForeground: false, now: t0), [])
        XCTAssertEqual(l.nextDeadline, at(600))
        XCTAssertEqual(l.tick(now: at(599)), [], "不到 10 分钟不断开")
        XCTAssertEqual(l.tick(now: at(600)), [.disconnect(pc)])
        XCTAssertEqual(l.computers[pc]?.users, [w1], "断开后保留使用者集合")
        XCTAssertEqual(l.tick(now: at(9999)), [], "不自动重连, 也不重复断开")
    }

    func testReturnBeforeDeadlineKeepsConnection() {
        var l = ConnectionLifecycle()
        _ = l.attach(window: w1, to: pc, foreground: true, now: t0)
        _ = l.setForeground(window: w1, computer: pc, isForeground: false, now: t0)
        XCTAssertEqual(l.setForeground(window: w1, computer: pc, isForeground: true, now: at(300)), [], "不到 10 分钟回前台: 连接不断")
        XCTAssertNil(l.nextDeadline)
        XCTAssertEqual(l.tick(now: at(10_000)), [])
    }

    func testReturnAfterIdleDisconnectReconnects() {
        var l = ConnectionLifecycle()
        _ = l.attach(window: w1, to: pc, foreground: true, now: t0)
        _ = l.setForeground(window: w1, computer: pc, isForeground: false, now: t0)
        _ = l.tick(now: at(700))
        XCTAssertEqual(l.setForeground(window: w1, computer: pc, isForeground: true, now: at(800)), [.connect(pc)])
        XCTAssertEqual(l.computers[pc]?.users, [w1], "回前台不改使用者集合")
    }

    // 恢复运行时立即检查: App 被挂起很久后一次 tick 就能断开。
    func testResumeAfterLongSuspendChecksDeadlineImmediately() {
        var l = ConnectionLifecycle()
        _ = l.attach(window: w1, to: pc, foreground: true, now: t0)
        _ = l.setForeground(window: w1, computer: pc, isForeground: false, now: t0)
        XCTAssertEqual(l.tick(now: at(3600)), [.disconnect(pc)])
    }

    // 集合语义: 重复事件只算一次, 不延长截止时间, 不让引用积累。
    func testDuplicateEventsAreIdempotent() {
        var l = ConnectionLifecycle()
        _ = l.attach(window: w1, to: pc, foreground: true, now: t0)
        _ = l.setForeground(window: w1, computer: pc, isForeground: true, now: at(1))
        _ = l.setForeground(window: w1, computer: pc, isForeground: true, now: at(2))
        XCTAssertEqual(l.computers[pc]?.users.count, 1)
        _ = l.setForeground(window: w1, computer: pc, isForeground: false, now: at(10))
        _ = l.setForeground(window: w1, computer: pc, isForeground: false, now: at(500))
        XCTAssertEqual(l.nextDeadline, at(610), "重复的后台事件不延长截止时间")
        _ = l.setForeground(window: w1, computer: pc, isForeground: true, now: at(20))
        XCTAssertEqual(l.detach(window: w1, from: pc, now: at(30)), [.disconnect(pc)], "回前台多次后一次 detach 就能归零")
    }

    // 只要还有一个前台窗口, 就不计时; 最后一个前台窗口进后台才开始计时。
    func testTimerStartsOnlyWhenLastForegroundWindowLeaves() {
        var l = ConnectionLifecycle()
        _ = l.attach(window: w1, to: pc, foreground: true, now: t0)
        _ = l.attach(window: w2, to: pc, foreground: true, now: t0)
        _ = l.setForeground(window: w1, computer: pc, isForeground: false, now: at(5))
        XCTAssertNil(l.nextDeadline)
        _ = l.setForeground(window: w2, computer: pc, isForeground: false, now: at(50))
        XCTAssertEqual(l.nextDeadline, at(650))
    }

    func testNonUserForegroundEventIsIgnored() {
        var l = ConnectionLifecycle()
        _ = l.attach(window: w1, to: pc, foreground: true, now: t0)
        XCTAssertEqual(l.setForeground(window: w2, computer: pc, isForeground: true, now: t0), [])
        XCTAssertEqual(l.computers[pc]?.users, [w1], "前台事件不能把非使用者加进使用者集合")
    }

    // 审计: 恢复前台时必须先处理已经到期的截止时间, 再登记前台 —— 顺序反了到期断开会被跳过。
    func testResumeOrderTickThenForegroundDisconnectsThenReconnects() {
        var l = ConnectionLifecycle()
        _ = l.attach(window: w1, to: pc, foreground: true, now: t0)
        _ = l.setForeground(window: w1, computer: pc, isForeground: false, now: t0)
        // 正确顺序 (ConnectionPool 现在的做法): 先 tick, 再前台 → 断开 + 重连
        var good = l
        XCTAssertEqual(good.tick(now: at(601)), [.disconnect(pc)])
        XCTAssertEqual(good.setForeground(window: w1, computer: pc, isForeground: true, now: at(601)), [.connect(pc)])
        // 错误顺序: 先前台再 tick → 截止时间被清掉, 到期断开被跳过 (这是审计发现的 bug, 保留用例说明为什么顺序重要)
        var bad = l
        XCTAssertEqual(bad.setForeground(window: w1, computer: pc, isForeground: true, now: at(601)), [])
        XCTAssertEqual(bad.tick(now: at(601)), [])
    }
}
