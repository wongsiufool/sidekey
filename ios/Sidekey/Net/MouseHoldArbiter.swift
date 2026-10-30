import Foundation

/// 鼠标键按住的仲裁 (§4.7「输入归属」, v1.5): 按「电脑 + 哪个键」登记当前是哪些窗口按着它, 允许多个窗口同时按住。
/// - 第一个窗口按下才发 `mouse down`; 最后一个窗口松开才发 `mouse up`;
/// - 窗口 A 按着时, 窗口 B 按下同一个键只是加入「按着的窗口」, 不发任何事件; B 松开也不发;
/// - 单击 (`mouse click`): 这台电脑的这个键正被别的窗口按着时, 不发送。
/// 纯值类型, 不连网, 便于单测。
struct MouseHoldArbiter: Equatable {
    struct Key: Hashable { var computer: UUID; var button: String }

    private(set) var holders: [Key: Set<UUID>] = [:]

    /// 返回 true = 需要真的发送 `down`。
    mutating func down(window: UUID, computer: UUID, button: String) -> Bool {
        let k = Key(computer: computer, button: button)
        var s = holders[k] ?? []
        let first = s.isEmpty
        s.insert(window)
        holders[k] = s
        return first
    }

    /// 返回 true = 需要真的发送 `up` (这个窗口是最后一个松开的)。没按着就松开: 不发。
    mutating func up(window: UUID, computer: UUID, button: String) -> Bool {
        let k = Key(computer: computer, button: button)
        guard var s = holders[k], s.remove(window) != nil else { return false }
        if s.isEmpty { holders[k] = nil; return true }
        holders[k] = s
        return false
    }

    /// 单击是否可以发送: 这台电脑的这个键正被「别的」窗口按着时不发。
    func canClick(window: UUID, computer: UUID, button: String) -> Bool {
        let others = (holders[Key(computer: computer, button: button)] ?? []).subtracting([window])
        return others.isEmpty
    }

    /// 这个窗口按着的所有键 (中断输入时逐个松开)。
    func held(by window: UUID) -> [Key] { holders.filter { $0.value.contains(window) }.map(\.key) }
}
