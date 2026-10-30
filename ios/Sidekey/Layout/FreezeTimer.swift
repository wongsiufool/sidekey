import Foundation

/// 输入冻结的计时规则 (§5.2 第 4 步): 布局稳定 (150 ms 内没有新的变化) 后才恢复输入。
/// 「稳定」只看会影响布局的结果; 连续变化 (例如拖动窗口边缘) 只算一次: 第一次变化时执行 1–3, 之后一直冻结, 直到稳定。
/// 纯值类型, 注入时间, 便于单测。
struct FreezeTimer: Equatable {
    static let stableInterval: TimeInterval = 0.150

    private(set) var frozen = false
    private(set) var lastChange: Date?

    /// 布局发生了变化。返回 true = 这是本轮冻结的第一次变化, 调用方要执行「立即结束输入」(1–3 步)。
    mutating func noteChange(at now: Date) -> Bool {
        lastChange = now
        guard !frozen else { return false }
        frozen = true
        return true
    }

    /// 到了该检查的时间: 布局稳定 (150 ms 没有新变化) **并且所有手指都已离开屏幕**才解冻 (§5.2 第 4 步)。返回 true = 刚刚解冻。
    mutating func thawIfStable(at now: Date, touchesActive: Bool = false) -> Bool {
        guard frozen, !touchesActive, let t = lastChange, now.timeIntervalSince(t) >= Self.stableInterval else { return false }
        frozen = false
        lastChange = nil
        return true
    }

    /// 距离可以解冻还要多久 (给计时器用)。
    func remaining(at now: Date) -> TimeInterval? {
        guard frozen, let t = lastChange else { return nil }
        return max(0, Self.stableInterval - now.timeIntervalSince(t))
    }
}
