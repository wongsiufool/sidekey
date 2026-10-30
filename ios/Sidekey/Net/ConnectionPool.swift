import Foundation
import SwiftUI

/// 连接池 (App 级, §4.7): 按「电脑」登记窗口的使用与前后台, 用 `ConnectionLifecycle` 决定何时连接 / 断开, 并管计时器。
/// M1 只有一个窗口、一条 `SidekeyClient`, 所以传输层只是把动作交给这条连接 (切电脑时旧电脑引用降到 0 即断开, 和以前一致);
/// 每台电脑各一条连接要到 M5 (多窗口) 才需要。
@MainActor
final class ConnectionPool: ObservableObject {
    /// 传输层: 真正连 / 断。M1 由 AppEnvironment 接到唯一的 SidekeyClient。
    struct Transport {
        var connect: (UUID) -> Void
        var disconnect: (UUID) -> Void
    }

    private var lifecycle = ConnectionLifecycle()
    private var selection: [UUID: UUID] = [:]      // 窗口 → 它选的电脑
    private var timer: Task<Void, Never>?
    private let transport: Transport
    private let now: () -> Date

    init(transport: Transport, now: @escaping () -> Date = Date.init) {
        self.transport = transport
        self.now = now
    }

    /// 窗口选了某台电脑 (启动、切换电脑都走这里)。先登记旧电脑的离开, 再登记新电脑。
    func select(window: UUID, computer: UUID, foreground: Bool) {
        if selection[window] == computer { return }
        if let old = selection[window] { run(lifecycle.detach(window: window, from: old, now: now())) }
        selection[window] = computer
        run(lifecycle.attach(window: window, to: computer, foreground: foreground, now: now()))
        reschedule()
    }

    /// 窗口关闭。
    func close(window: UUID) {
        guard let c = selection.removeValue(forKey: window) else { return }
        run(lifecycle.detach(window: window, from: c, now: now()))
        reschedule()
    }

    /// `scenePhase` 变化: active / inactive 都算前台 (弹系统菜单、下拉通知中心时是 inactive), 只有 background 算后台。
    func scenePhaseChanged(window: UUID, phase: ScenePhase) {
        guard let c = selection[window] else { return }
        let foreground = phase != .background
        // 回前台时**先**处理挂起期间已经到期的截止时间 (App 被挂起时计时不保证准点), 再登记前台:
        // 先登记前台会把截止时间清掉, 到期的断开就被跳过了。到期断开后紧接着的前台登记会重新连接。
        if foreground { run(lifecycle.tick(now: now())) }
        run(lifecycle.setForeground(window: window, computer: c, isForeground: foreground, now: now()))
        reschedule()
    }

    /// 检查截止时间 (计时器到点、App 回到前台时调用)。
    func tick() {
        run(lifecycle.tick(now: now()))
        reschedule()
    }

    private func run(_ actions: [ConnectionLifecycle.Action]) {
        for a in actions {
            switch a {
            case .connect(let id): transport.connect(id)
            case .disconnect(let id): transport.disconnect(id)
            }
        }
    }

    private func reschedule() {
        timer?.cancel(); timer = nil
        guard let deadline = lifecycle.nextDeadline else { return }
        let delay = max(0, deadline.timeIntervalSince(now()))
        timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.tick()
        }
    }
}
