import Foundation

/// 普通键一次按压的生命周期 (纯值类型, 便于单测): 取消后的松手不能再补发。
/// - 按下: 必须已启用、没在冻结、没有正在进行的按压;
/// - 松手: 只有「仍然有效的按压」才可能触发 (被取消的按压松手时什么都不做); 真连发过就不再补一次轻点;
/// - 取消: 滑动翻页 / 移出键面 / 被系统取消 / 布局变化 / 退后台 / 断连。
struct PressLifecycle: Equatable {
    private(set) var pressed = false
    private(set) var didRepeat = false

    /// 返回 true = 本次按压生效。
    mutating func down(enabled: Bool, frozen: Bool) -> Bool {
        guard enabled, !frozen, !pressed else { return false }
        pressed = true
        didRepeat = false
        return true
    }

    mutating func markRepeating() { didRepeat = true }

    /// 返回 true = 要补发一次轻点。
    mutating func up(enabled: Bool) -> Bool {
        guard pressed else { return false }          // 已被取消: 后到的 .ended 不能再触发
        let fired = didRepeat
        pressed = false
        return enabled && !fired
    }

    mutating func cancel() { pressed = false }
}
