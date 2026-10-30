import SwiftUI

/// 输入传输层: 把鼠标键等事件交给连接。`SidekeyClient` 实现它; 单测里用假的实现来核对「发了什么」。
@MainActor
protocol InputTransport: AnyObject {
    /// 当前连着的电脑 (没连时 nil)。松键只发给「按下时那台」, 电脑已经换了就不发 (旧连接断开时电脑端会松开, F18)。
    var transportComputerID: UUID? { get }
    func transportMouseDown(button: String)
    func transportMouseUp(button: String)
    func transportMouseClick(button: String)
    /// 丢掉还没交给 WebSocket 的待发位移和滚动 (已经交出去的不撤回)。
    func transportDiscardPendingMotion()
}

/// 窗口级的输入守卫 (§5.2 + §4.7「输入归属」): 每个窗口一个。
/// - 鼠标键经它仲裁后再发 (App 级的 `MouseHoldArbiter` 决定要不要真发 down / up);
/// - 记录这个窗口的各个输入 (按住的鼠标键、按键连发、待发位移) 的取消方法;
/// - `interrupt` 立即执行 1–3 步 (松鼠标键、停连发、丢待发位移), 然后冻结输入, 等布局稳定 (150 ms) 才恢复。
///   这几步**不等**姿态防抖 (§3.4 的 300 ms)。
@MainActor
final class InputGuard: ObservableObject {
    private(set) var windowID: UUID
    /// 窗口当前选的电脑 (鼠标键按下时锁定)。
    var computerID: () -> UUID

    @Published private(set) var frozen = false
    /// 丢了触摸信息、等下一次触摸来重新采集: 这一下点击只用来恢复, 按键不会执行 —— 界面要提示, 免得以为按钮坏了。
    @Published private(set) var needsRetap = false

    private let transport: InputTransport
    private let arbiter: ArbiterBox
    private let now: () -> Date
    private var freeze = FreezeTimer()
    private var cancelHandlers: [UUID: () -> Void] = [:]
    private struct Hold { var computer: UUID; var sources: Set<UUID> }
    private var heldMouse: [String: Hold] = [:]          // 这个窗口按着的键 → 按下时的电脑 + 输入源集合
    private var activeTouches = 0                       // 屏幕上还有几根手指 (窗口级触摸跟踪器上报)
    private var touchesUnknown = false                  // 跟踪器丢了触摸信息: 当作「可能还有手指」, 直到重新采集到完整触摸状态才解冻
    private var thawTask: Task<Void, Never>?
    /// 层 2 还在等布局稳定 (姿态防抖 300 ms 等): 这期间不解冻, 布局采用后再按 150 ms 规则解冻 (M3 审计 B1)。
    private(set) var layoutPending = false

    /// App 级共享的仲裁器 (引用包装, 多个窗口共用一份)。
    @MainActor final class ArbiterBox { var value = MouseHoldArbiter() }

    init(windowID: UUID, computerID: @escaping () -> UUID, transport: InputTransport,
         arbiter: ArbiterBox, now: @escaping () -> Date = Date.init) {
        self.windowID = windowID
        self.computerID = computerID
        self.transport = transport
        self.arbiter = arbiter
        self.now = now
    }

    /// 窗口建好后绑定它的标识和「当前电脑」(SwiftUI 里守卫比窗口状态先创建)。必须在任何输入之前调用。
    func bind(windowID: UUID, computerID: @escaping () -> UUID) {
        self.windowID = windowID
        self.computerID = computerID
    }

    // MARK: - 鼠标键 (经仲裁)
    /// 没有明确输入源时用的默认输入源 (同一窗口的多个鼠标键按钮各自传自己的 id, 见 `MouseKeyButton`)。
    nonisolated static let defaultSource = UUID()

    /// 同一窗口内可以有多个输入源 (例如编辑器里放了两个左键) 同时按住同一个键: 窗口内按输入源计数,
    /// 窗口里第一个输入源按下 / 最后一个松开, 才向连接级的窗口集合 (仲裁器) 登记。
    func mouseDown(button: String, source: UUID = InputGuard.defaultSource) {
        guard !frozen else { return }               // 冻结期间拒绝新输入 (§5.2 第 4 步)
        if heldMouse[button] == nil {
            let c = computerID()
            heldMouse[button] = Hold(computer: c, sources: [source])
            if arbiter.value.down(window: windowID, computer: c, button: button) { transport.transportMouseDown(button: button) }
        } else {
            heldMouse[button]?.sources.insert(source)
        }
    }

    func mouseUp(button: String, source: UUID = InputGuard.defaultSource) {
        guard var h = heldMouse[button], h.sources.remove(source) != nil else { return }
        if h.sources.isEmpty {
            heldMouse[button] = nil
            if arbiter.value.up(window: windowID, computer: h.computer, button: button) { sendUp(button: button, computer: h.computer) }
        } else {
            heldMouse[button] = h
        }
    }

    func mouseClick(button: String) {
        guard !frozen else { return }
        let c = computerID()
        guard arbiter.value.canClick(window: windowID, computer: c, button: button) else { return }
        transport.transportMouseClick(button: button)
    }

    private func sendUp(button: String, computer: UUID) {
        // 电脑已经换了: 旧连接已断 (电脑端会松开鼠标键), 不能把 up 发到新电脑。
        guard transport.transportComputerID == nil || transport.transportComputerID == computer else { return }
        transport.transportMouseUp(button: button)
    }

    /// 释放这个窗口按着的所有鼠标键 (不管有几个输入源), 由仲裁决定要不要发 up。
    private func releaseAllMouse() {
        for (button, h) in heldMouse {
            heldMouse[button] = nil
            if arbiter.value.up(window: windowID, computer: h.computer, button: button) { sendUp(button: button, computer: h.computer) }
        }
    }

    // MARK: - 取消方法的登记 (按键连发、触控板、鼠标键按钮的视觉状态)
    func register(_ id: UUID, cancel: @escaping () -> Void) { cancelHandlers[id] = cancel }
    func unregister(_ id: UUID) { cancelHandlers[id] = nil }

    // MARK: - §5.2
    /// 会改变输入区域的变化 (旋转、后台、切换电脑 / 模式 / 页、窗口缩放、键位刷新……) 都调这里。
    /// 第一次变化立即执行 1–3 步; 之后的连续变化只重新计时。
    func interrupt() {
        let first = freeze.noteChange(at: now())
        if first {
            // 1. 撤销这个窗口按住的鼠标键 (由仲裁决定要不要发 up)
            releaseAllMouse()
            // 2. 停止这个窗口的按键连发 (3. 丢弃待发位移 / 滚动 也在各自的取消方法里)
            for h in cancelHandlers.values { h() }
            transport.transportDiscardPendingMotion()
            frozen = true
            DebugTimeline.record("guard frozen")
        }
        scheduleThaw()
    }

    private func scheduleThaw(after override: TimeInterval? = nil) {
        thawTask?.cancel()
        guard let wait = override ?? freeze.remaining(at: now()) else { return }
        thawTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((wait + 0.005) * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.thawIfStable()
        }
    }

    /// 检查是否稳定 (计时器到点、手指数变化时调用; 单测里直接调)。
    /// 解冻要同时满足: 布局稳定 150 ms, 并且所有手指都已离开屏幕。
    func thawIfStable() {
        guard !layoutPending else { return }                 // 布局还没采用: 不解冻, 等 setLayoutPending(false)
        if freeze.thawIfStable(at: now(), touchesActive: activeTouches > 0 || touchesUnknown) { frozen = false; DebugTimeline.record("guard thawed"); return }
        // 还没稳定: 继续计时。已经稳定但还有手指在屏幕上: 等触摸数归零时再检查 (touchCountChanged)。
        // 丢了触摸信息: 不靠计时放行, 等 `touchesResynced` 重新采集到完整触摸状态。
        if let r = freeze.remaining(at: now()), r > 0 { scheduleThaw() }
    }

    /// 层 2 告诉守卫「布局还在等稳定」/「已经采用 (或作废)」。等待期间保持冻结; 结束后再按 150 ms 规则解冻。
    func setLayoutPending(_ pending: Bool) {
        guard pending != layoutPending else { return }
        layoutPending = pending
        if !pending, frozen { scheduleThaw() }
    }

    /// 窗口级触摸跟踪器上报屏幕上的手指数 (0 = 确认没有活跃触摸)。
    /// 丢了触摸信息之后, 普通上报**不能**证明旧手指已离开 (新手指来了 / 走了都不能), 只记下数量, 不解除「未知」。
    func touchCountChanged(_ count: Int) {
        activeTouches = max(0, count)
        if activeTouches == 0, !touchesUnknown { releaseOrphanHolds() }
        if activeTouches == 0, frozen { thawIfStable() }
    }

    /// 兜底: 屏幕上已确认没有手指, 这个窗口却还按着鼠标键 —— 按键自己的识别器漏了松开 (实测: 一指按左键、一指在触控板上拖,
    /// 两指同时抬起时左键收不到 .ended)。没有手指就不可能还在按, 直接松开并作废各输入源的按压状态, 保证 down / up 成对。
    private func releaseOrphanHolds() {
        guard !heldMouse.isEmpty else { return }
        DebugTimeline.record("guard released orphan mouse hold")
        releaseAllMouse()
        for h in cancelHandlers.values { h() }
    }

    /// 跟踪器丢了触摸信息 (手指还没收到结束事件就被强制复位 / 摘除): 先安全结束当前所有输入 (没冻结也要),
    /// 然后一直保持「未知」, 直到 `touchesResynced` 从系统事件里重新采集到完整的触摸状态。**不靠计时放行。**
    func touchTrackingLost() {
        interrupt()
        activeTouches = 0
        touchesUnknown = true
        needsRetap = true
        DebugTimeline.record("guard touches unknown")
    }

    /// 下一次触摸事件带来了窗口上全部触摸 (`UIEvent.allTouches`) 的完整状态: 可信, 解除「未知」。
    func touchesResynced(_ count: Int) {
        touchesUnknown = false
        needsRetap = false
        touchCountChanged(count)
    }

    /// 窗口关闭 / 消失: 按住的键松开, 并清掉冻结状态 (重新挂载后不会一直冻结)。
    func teardown() {
        releaseAllMouse()
        thawTask?.cancel()
        freeze = FreezeTimer()
        layoutPending = false
        frozen = false
        activeTouches = 0
        touchesUnknown = false
        needsRetap = false
    }
}

private struct InputGuardKey: EnvironmentKey { static let defaultValue: InputGuard? = nil }
extension EnvironmentValues {
    /// 可选: 编辑器等没有输入守卫的场合为 nil, 组件退回到直接发送。
    var inputGuard: InputGuard? {
        get { self[InputGuardKey.self] }
        set { self[InputGuardKey.self] = newValue }
    }
}

// MARK: - 窗口级触摸跟踪 (§5.2 第 4 步: 所有手指离开屏幕后才恢复输入)

/// 挂在窗口上的被动识别器: 只数手指, 从不识别 / 不吞触摸 / 不延迟触摸, **也不参与和其他识别器的互斥**。
/// UIKit 默认识别器之间互斥, 别的识别器 (触控板 pan、滚动、系统手势) 识别成功会把它置为失败并复位, 之后它收不到尚未结束的触摸,
/// 计数就会停在过期的值上、让输入一直冻结。所以这里明确: 不会被别人阻止 (canBePrevented)、也不阻止别人 (canPrevent),
/// 不要求别人失败、也不被要求失败, 并且和任何识别器同时识别。
/// 手指按触摸对象本身登记 (不数个数), 重复回调不会重复计数。
final class TouchCountRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    var onCount: ((Int) -> Void)?
    /// 跟踪器**丢了触摸信息** (手指还没收到结束事件就被 reset / 摘除 / 销毁): 不知道手指是否已离开屏幕, 和「确认没有活跃触摸 (0)」不同。
    var onTrackingLost: (() -> Void)?
    /// 丢失之后第一次拿到完整触摸状态 (来自 `UIEvent.allTouches`, 含屏幕上所有仍按着的手指) 时上报。
    var onResync: ((Int) -> Void)?
    /// 新建的识别器不知道挂上来时屏幕上有没有手指: 第一次触摸事件先按 allTouches 校正。
    private(set) var needsResync = true
    /// 当前按触摸对象登记的活跃手指 (内部可见, 单测直接注入)。
    var activeIDs = Set<ObjectIdentifier>()

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    // 不参与任何互斥
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func shouldRequireFailure(of otherGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func shouldBeRequiredToFail(by otherGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRequireFailureOf other: UIGestureRecognizer) -> Bool { false }
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool { false }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) { sync(event) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) { sync(event) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { sync(event) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { sync(event) }

    /// 一次触摸事件里某个触摸的快照 (UITouch 在单测里造不出来, 适配层用它隔离)。
    struct TouchSnapshot {
        var id: ObjectIdentifier
        var phase: UITouch.Phase
        var inThisWindow: Bool
    }

    /// 每个事件都用**当前窗口**的完整快照校正 (`UIEvent.allTouches` 可能含别的窗口的触摸, 要过滤)。
    /// 不能只在丢失后校正一次: 校正之后若旧手指的结束事件仍收不到, 下一个事件的快照里它已经不在了, 计数要跟着纠正。
    private func sync(_ event: UIEvent) {
        let win = view as? UIWindow
        let snap = (event.allTouches ?? []).map {
            TouchSnapshot(id: ObjectIdentifier($0), phase: $0.phase, inThisWindow: win == nil || $0.window === win)
        }
        apply(snapshot: snap)
    }

    /// 用快照更新活跃手指: 内部可见, 单测直接注入。丢失之后的第一次快照走 `onResync` (可信, 解除「未知」), 之后每次数量变化走 `onCount`。
    func apply(snapshot: [TouchSnapshot]) {
        let ids = Set(snapshot.filter { $0.inThisWindow && Self.isActive($0.phase) }.map(\.id))
        let changed = ids != activeIDs
        activeIDs = ids
        if needsResync {
            needsResync = false
            DebugTimeline.record("touches resynced=\(ids.count)")
            onResync?(ids.count)
        } else if changed {
            report()
        }
    }
    static func isActive(_ phase: UITouch.Phase) -> Bool { phase != .ended && phase != .cancelled }

    /// UIKit 复位。正常情况下一轮触摸全部结束后才复位 (此时 activeIDs 已空 → 上报 0, 确认没有手指);
    /// 如果复位时还有手指没收到结束事件 (被别的路径强制复位), 说明丢了触摸信息: 清空记录, 但上报「丢失」而不是 0。
    override func reset() {
        if activeIDs.isEmpty { report() }
        else { activeIDs.removeAll(); needsResync = true; DebugTimeline.record("touch tracker reset with fingers still down"); onTrackingLost?() }
    }

    /// 从窗口摘掉 / 视图销毁前调用: 同样, 没有活跃手指就是 0, 否则是「丢失」。
    func detach() {
        if activeIDs.isEmpty { report() }
        else { activeIDs.removeAll(); needsResync = true; DebugTimeline.record("touch tracker detached with fingers still down"); onTrackingLost?() }
        view?.removeGestureRecognizer(self)
    }

    var trackedTouchCount: Int { activeIDs.count }
    private func report() { DebugTimeline.record("touches=\(activeIDs.count)"); onCount?(activeIDs.count) }
}

struct TouchTracker: UIViewRepresentable {
    var onCount: (Int) -> Void
    var onLost: () -> Void = {}
    var onResync: (Int) -> Void = { _ in }

    func makeUIView(context: Context) -> TrackerView { let v = TrackerView(); v.onCount = onCount; v.onLost = onLost; v.onResync = onResync; return v }
    func updateUIView(_ uiView: TrackerView, context: Context) { uiView.onCount = onCount; uiView.onLost = onLost; uiView.onResync = onResync }

    final class TrackerView: UIView {
        var onCount: ((Int) -> Void)?
        var onLost: (() -> Void)?
        var onResync: ((Int) -> Void)?
        private var recognizer: TouchCountRecognizer?
        override init(frame: CGRect) { super.init(frame: frame); isUserInteractionEnabled = false }
        required init?(coder: NSCoder) { fatalError() }

        deinit { recognizer?.detach() }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let r = recognizer { r.detach(); recognizer = nil }     // 换窗口 / 被移除: 先上报 0 再摘掉
            guard let window else { return }
            let r = TouchCountRecognizer(target: nil, action: nil)
            r.onCount = { [weak self] n in self?.onCount?(n) }
            r.onTrackingLost = { [weak self] in self?.onLost?() }
            r.onResync = { [weak self] n in self?.onResync?(n) }
            window.addGestureRecognizer(r)
            recognizer = r
        }
    }
}
