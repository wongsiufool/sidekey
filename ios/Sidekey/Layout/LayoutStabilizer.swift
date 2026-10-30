import Foundation

/// 层 2「时序」(§7、§3.4、§5.2): 把一串观测变成「稳定布局上下文」+「立即结束输入」事件。
/// 纯状态机, 时间由调用方传入 (单测可控); 视图层按 `deadline` 排一个计时器再调 `tick`。
///
/// - 输入只比较**归一化之后、会影响布局的结果** (调用方传进来的 Key); 铰链角度这类不影响布局的变化不算新变化。
/// - 观测一变 (和上一次观测不同、也和当前稳定值不同) 就返回 `.interruptNow`: §5.2 第 1–3 步立即执行, 不等防抖。
///   连续变化只算一次: 已经在等稳定时, 后续变化不再重复发事件。
/// - 新值要连续保持一段时间才采用: 姿态结论 (全开 / 书本 / 笔记本) 变了要 300 ms, 其他变化 150 ms。
struct LayoutStabilizer<Key: Equatable> {
    var postureDebounce: TimeInterval = 0.3
    var settleDelay: TimeInterval = 0.15
    /// 从 Key 里取「姿态结论」(只用来决定等 300 ms 还是 150 ms)。
    let posture: (Key) -> String

    private(set) var stable: Key?
    private(set) var pending: Key?
    private var pendingSince: TimeInterval = 0

    enum Event: Equatable { case interruptNow }

    init(posture: @escaping (Key) -> String) { self.posture = posture }

    /// 下一次需要 `tick` 的时间; nil = 没有在等。
    var deadline: TimeInterval? {
        guard let pending else { return nil }
        return pendingSince + dwell(for: pending)
    }

    /// 是否正在等稳定 (输入冻结期间)。
    var isSettling: Bool { pending != nil }

    private func dwell(for k: Key) -> TimeInterval {
        guard let s = stable else { return 0 }
        return posture(k) == posture(s) ? settleDelay : postureDebounce
    }

    /// 收到一次观测。第一次观测直接采用 (启动时没有旧布局可保留)。
    mutating func observe(_ k: Key, at t: TimeInterval) -> Event? {
        guard stable != nil else { stable = k; return nil }
        // 先对等价的 pending 去重 (M3 审计 N-B1): 和正在等的值一样就继续计时, 不能让无关的原始观测反复重设计时
        if k == pending { return nil }
        if k == stable {
            // 变回了当前稳定值 (例如过渡帧): 只在结论真的从别的值变回来时重新计时一次; 冻结的解除仍按 150 ms 规则, 由 tick 处理
            if pending != nil { pending = k; pendingSince = t }
            return nil
        }
        let first = pending == nil
        pending = k
        pendingSince = t                                       // 结论变了才重新计时
        return first ? .interruptNow : nil
    }

    /// 到时间了: 保持够久就采用, 返回新的稳定值 (没变化返回 nil)。
    mutating func tick(at t: TimeInterval) -> Key? {
        guard let p = pending, let d = deadline, t >= d else { return nil }
        pending = nil
        guard p != stable else { return nil }
        stable = p
        return p
    }
}

/// 层 2 接到窗口上 (M3 审计 B1 / B5): 防抖状态机 + 输入守卫联动, 统一由这里驱动。
/// - 每次「影响布局的结果」有效变化 (第一次, 以及等待期间又换了新值) 都 interrupt 并延长冻结;
/// - 等待期间守卫保持冻结 (`setLayoutPending(true)`), 采用新布局时再 interrupt 一次, 从采用时刻起按 150 ms 解冻;
/// - 离开内屏 (空观测) 时整套重置, 作废还没执行的计时 (generation), 重新展开时第一次观测直接采用。
@MainActor
final class DuoLayoutDriver {
    private(set) var stabilizer = LayoutStabilizer<DuoStableContext>(posture: { $0.posture })
    private(set) var stable: DuoObservation?
    /// 每次重置 +1; 计时任务带着它, 不一致就作废。
    private(set) var generation = 0
    /// 这个窗口的输入守卫 (SwiftUI 里守卫和驱动分别创建, 由视图在喂观测前接上)。
    weak var input: InputGuard?

    init(input: InputGuard? = nil) { self.input = input }

    /// 收到一次观测。返回 true = 稳定值变了 (调用方刷新界面)。
    @discardableResult
    func feed(_ o: DuoObservation, at t: TimeInterval) -> Bool {
        guard o != .empty, o.screen == .inner else { return reset() }
        let ctx = DuoStableContext(o)
        let first = stabilizer.stable == nil
        let before = stabilizer.pending
        let ev = stabilizer.observe(ctx, at: t)
        if first { stable = stabilizer.stable?.observation; return true }
        if ev == .interruptNow || (stabilizer.pending != nil && stabilizer.pending != before) {
            input?.interrupt()                                  // 第一次: 1–3 步; 之后: 只延长冻结
        }
        input?.setLayoutPending(stabilizer.isSettling)
        return false
    }

    /// 计时到点。返回 true = 采用了新布局。
    @discardableResult
    func tick(at t: TimeInterval) -> Bool {
        let adopted = stabilizer.tick(at: t)
        if let a = adopted {
            stable = a.observation
            input?.interrupt()                                  // 布局真的换了: 从采用时刻起再等 150 ms
        }
        input?.setLayoutPending(stabilizer.isSettling)
        return adopted != nil
    }

    var deadline: TimeInterval? { stabilizer.deadline }

    /// 离开内屏: 整套重置 (状态机、稳定值、等待中的计时)。返回 true = 稳定值从有变成没有。
    @discardableResult
    func reset() -> Bool {
        let had = stable != nil || stabilizer.stable != nil
        stabilizer = LayoutStabilizer<DuoStableContext>(posture: { $0.posture })
        stable = nil
        generation &+= 1
        input?.setLayoutPending(false)
        return had
    }
}

/// 层 2 的比较键 (M3a 审阅后): 只比较**会影响布局的结果**, 不比较原始观测。
/// 用一个中性页 (1 列 1 行) 分别按调换前 / 后算出几何, 比这两份几何; 调试用的摄像头 / 边缘避让清单不参与比较。
/// 这样坐标对不上、但不影响任何区域的旧摄像头区 (合屏过渡帧) 不会多触发一次 interrupt。
struct DuoStableContext: Equatable {
    let observation: DuoObservation
    let geometry: [DuoLayoutPlan]

    init(_ o: DuoObservation, policy: DuoPolicy = .standard) {
        observation = o
        let neutral = DuoPageInfo(columns: 1, rowCount: 1, keys: [], pageCount: 1)
        geometry = [false, true].map { swapped in
            var p = DuoLayout.plan(o, page: neutral, swapped: swapped, policy: policy)
            p.camera = []; p.edgeAvoid = []
            return p
        }
    }

    var posture: String { geometry.first?.posture.rawValue ?? "" }

    static func == (a: DuoStableContext, b: DuoStableContext) -> Bool { a.geometry == b.geometry }
}
