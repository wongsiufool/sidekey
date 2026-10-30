import Foundation

/// 每台电脑的连接生命周期状态机 (§4.7「连接」, v1.7 改成窗口 ID 集合): 纯值类型, 不连网、不管计时器, 便于单测。
///
/// 每台电脑维护三个量:
/// - 使用者集合: 选了这台电脑的窗口 (前台、后台都算);
/// - 前台集合: 其中处在前台的窗口。用集合而不是计数, 重复到达的事件也只算一次;
/// - 后台空闲截止时间: 前台集合从有到空时设为「现在 + 10 分钟」。
/// 规则: 使用者集合变空就断开; 到了截止时间前台集合仍为空就断开但保留使用者集合, **不自动重连**,
/// 等到再有窗口回到前台。窗口回到前台只往前台集合里加, 使用者集合不变。
struct ConnectionLifecycle: Equatable {
    typealias WindowID = UUID
    typealias ComputerID = UUID

    static let idleTimeout: TimeInterval = 10 * 60

    struct State: Equatable {
        var users: Set<WindowID> = []
        var foreground: Set<WindowID> = []
        var idleDeadline: Date?
        var idleDisconnected = false
    }

    /// 要交给传输层执行的动作。
    enum Action: Equatable {
        case connect(ComputerID)
        case disconnect(ComputerID)
    }

    private(set) var computers: [ComputerID: State] = [:]

    /// 窗口选了这台电脑。窗口回到前台由 `setForeground` 处理, 这里按传入的前后台状态一并登记。
    mutating func attach(window: WindowID, to computer: ComputerID, foreground: Bool, now: Date) -> [Action] {
        var s = computers[computer] ?? State()
        let firstUser = s.users.isEmpty
        s.users.insert(window)
        var actions: [Action] = []
        if foreground { s.foreground.insert(window) }
        if firstUser { actions.append(.connect(computer)) }
        if foreground {
            s.idleDeadline = nil
            if s.idleDisconnected { s.idleDisconnected = false; if !firstUser { actions.append(.connect(computer)) } }
        } else if s.foreground.isEmpty, s.idleDeadline == nil, !s.idleDisconnected {
            s.idleDeadline = now.addingTimeInterval(Self.idleTimeout)
        }
        computers[computer] = s
        return actions
    }

    /// 窗口切到别的电脑 / 关闭。
    mutating func detach(window: WindowID, from computer: ComputerID, now: Date) -> [Action] {
        guard var s = computers[computer], s.users.contains(window) else { return [] }
        let hadForeground = !s.foreground.isEmpty
        s.users.remove(window)
        s.foreground.remove(window)
        if s.users.isEmpty {
            computers[computer] = nil
            return [.disconnect(computer)]
        }
        if hadForeground, s.foreground.isEmpty, !s.idleDisconnected { s.idleDeadline = now.addingTimeInterval(Self.idleTimeout) }
        computers[computer] = s
        return []
    }

    /// 窗口前后台变化。`scenePhase` 是 active 或 inactive 都算前台, 只有 background 算后台 (调用方负责映射)。
    mutating func setForeground(window: WindowID, computer: ComputerID, isForeground: Bool, now: Date) -> [Action] {
        guard var s = computers[computer], s.users.contains(window) else { return [] }   // 不是使用者: 不改使用者集合
        var actions: [Action] = []
        if isForeground {
            guard !s.foreground.contains(window) else { return [] }     // 重复事件: 只算一次
            s.foreground.insert(window)
            s.idleDeadline = nil
            if s.idleDisconnected { s.idleDisconnected = false; actions.append(.connect(computer)) }
        } else {
            guard s.foreground.contains(window) else { return [] }
            s.foreground.remove(window)
            if s.foreground.isEmpty, !s.idleDisconnected { s.idleDeadline = now.addingTimeInterval(Self.idleTimeout) }
        }
        computers[computer] = s
        return actions
    }

    /// 检查截止时间 (计时器到点、App 恢复运行时都要调用)。到期且前台集合仍为空 → 断开但保留使用者, 不自动重连。
    mutating func tick(now: Date) -> [Action] {
        var actions: [Action] = []
        for (id, var s) in computers {
            guard let d = s.idleDeadline, d <= now, s.foreground.isEmpty else { continue }
            s.idleDeadline = nil
            s.idleDisconnected = true
            computers[id] = s
            actions.append(.disconnect(id))
        }
        return actions
    }

    /// 最近的截止时间 (给计时器用)。
    var nextDeadline: Date? { computers.values.compactMap(\.idleDeadline).min() }
}
