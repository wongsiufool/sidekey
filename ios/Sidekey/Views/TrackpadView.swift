import SwiftUI
import UIKit

/// 触控板顺滑度(指针速度)调参。SettingsView 的滑块与 TrackpadView 都读同一个 @AppStorage key。
enum TrackpadTuning {
    static let defaultSpeed: Double = 2.6   // 基础速度倍率 (比旧的 1.7 更快, 解决「慢/范围小」)
    static let minSpeed: Double = 1.2
    static let maxSpeed: Double = 5.0
    static let accelK: CGFloat = 0.12        // 加速度系数: 单次回调位移越大(滑得越快)放大越多
    static let accelCap: CGFloat = 30        // 速度封顶, 防止猛甩飞出
    // 滚动速度 (倍率): 手指位移 × 此值 = 滚动像素 (配服务端像素级滚动)。可在设置里拖滑块调。
    static let scrollDefaultSpeed: Double = 4.0
    static let scrollMinSpeed: Double = 2.0
    static let scrollMaxSpeed: Double = 9.0
    static let scrollAccelK: CGFloat = 0.05  // 滚动加速度: 快速滑动滚更远, 慢速更精准
    static let edgeScrollFraction: CGFloat = 0.16   // 右侧这段宽度 = 单指上下滑滚动条区
    static let edgeScrollMaxWidth: CGFloat = 64     // 滚动带最宽 64 pt (§5.4)

    /// 滚动带宽度: 触控板宽 × 16%, 最宽 64 (视觉和手势共用, M3 审计 S1)。
    static func scrollBandWidth(_ width: CGFloat) -> CGFloat { min(width * edgeScrollFraction, edgeScrollMaxWidth) }
}

/// 触控板手势面: 用 UIKit 手势识别器可靠区分单指/双指 (纯 SwiftUI 难分)。
/// 单指拖=移动光标(相对位移,带灵敏度+累积小数) · 双指拖=滚动 · 单指轻点=左键 · 双指轻点=右键。
struct TrackpadSurface: UIViewRepresentable {
    var sensitivity: CGFloat = 1.7
    var scrollSpeed: CGFloat = 4.0
    var onMove: (Int, Int) -> Void
    var onScroll: (Int, Int) -> Void
    var onLeftClick: () -> Void
    var onRightClick: () -> Void
    var resetToken: Int = 0

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        v.isMultipleTouchEnabled = true
        let c = context.coordinator

        let pan1 = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.handlePan1(_:)))
        pan1.minimumNumberOfTouches = 1; pan1.maximumNumberOfTouches = 1
        v.addGestureRecognizer(pan1)

        let pan2 = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.handlePan2(_:)))
        pan2.minimumNumberOfTouches = 2; pan2.maximumNumberOfTouches = 2
        v.addGestureRecognizer(pan2)

        let tap1 = UITapGestureRecognizer(target: c, action: #selector(Coordinator.handleTap1))
        tap1.numberOfTouchesRequired = 1
        v.addGestureRecognizer(tap1)

        let tap2 = UITapGestureRecognizer(target: c, action: #selector(Coordinator.handleTap2))
        tap2.numberOfTouchesRequired = 2
        v.addGestureRecognizer(tap2)

        tap1.require(toFail: tap2)   // 双指点优先, 避免被当成两次单指点
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.applyResetIfNeeded(uiView, token: resetToken)
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: TrackpadSurface
        private var lastResetToken = 0

        /// §5.2: 取消正在进行的手势 (关再开识别器会把进行中的触摸判为取消) 并清掉累积位移 / 滚动余量, 不把它们发出去。
        func applyResetIfNeeded(_ view: UIView, token: Int) {
            guard token != lastResetToken else { return }
            lastResetToken = token
            moveAccX = 0; moveAccY = 0; scrollRemX = 0; scrollRemY = 0; pan1IsScroll = false
            for g in view.gestureRecognizers ?? [] { g.isEnabled = false; g.isEnabled = true }
        }
        private var moveAccX: CGFloat = 0, moveAccY: CGFloat = 0
        private var scrollRemX: CGFloat = 0, scrollRemY: CGFloat = 0   // 滚动亚像素余量
        private var pan1IsScroll = false      // 这次单指拖是否落在右侧滚动条区
        /// 这次手势已因手指越界被取消 (§5.3): 直到手势结束都不再发任何位移 / 滚动。
        private var aborted = false
        private var lastMoveSent: TimeInterval = 0
        // 采样上限 ~120Hz, 取更细粒度; 真正的「防灌爆」改由客户端 sendMouseMove 的合并+背压把关。
        private let moveInterval: TimeInterval = 1.0 / 120.0

        init(_ p: TrackpadSurface) { parent = p }

        /// 有没有参与触摸的手指 (或质心) 在触控板外。
        private func anyOutside(_ g: UIPanGestureRecognizer) -> Bool {
            guard let view = g.view else { return false }
            let b = view.bounds
            var points = [g.location(in: view)]
            for i in 0..<g.numberOfTouches { points.append(g.location(ofTouch: i, in: view)) }
            return points.contains { !b.contains($0) }
        }

        /// §5.3: 任一参与触摸的手指滑出触控板区 → 取消整次手势、丢掉余量, 不按正常结束补发末段 (M3 审计 B3)。
        /// 返回 true = 已越界 (调用方直接返回)。
        private func abortIfOutside(_ g: UIPanGestureRecognizer) -> Bool {
            if aborted { return true }
            guard anyOutside(g) else { return false }
            aborted = true
            moveAccX = 0; moveAccY = 0; scrollRemX = 0; scrollRemY = 0
            g.isEnabled = false; g.isEnabled = true            // 让识别器进入 cancelled
            return true
        }

        @objc func handlePan1(_ g: UIPanGestureRecognizer) {
            let view = g.view
            if g.state == .began {
                aborted = false
                // 单指起点落在右侧滚动带内 → 这次当滚动条用 (只纵向滚动)。
                let x = g.location(in: view).x, w = view?.bounds.width ?? 1
                pan1IsScroll = x >= w - TrackpadTuning.scrollBandWidth(w)
                moveAccX = 0; moveAccY = 0; scrollRemX = 0; scrollRemY = 0
            }
            if g.state == .ended || g.state == .cancelled {
                // 只有正常结束、没越界过、并且结束位置仍在触控板内才冲掉余量; 取消不补发 (M3 审计 N-B2: 到 ended 才越界也丢掉)
                if g.state == .ended, !aborted, !pan1IsScroll, !anyOutside(g) { flushMove(force: true) }
                moveAccX = 0; moveAccY = 0; pan1IsScroll = false; aborted = false
                return
            }
            if abortIfOutside(g) { return }
            let t = g.translation(in: view); g.setTranslation(.zero, in: view)
            if pan1IsScroll {
                emitScroll(fx: 0, fy: t.y)        // 右侧滚动条: 单指上下滑 = 滚动
            } else {
                // 苹果式加速度: 本次回调位移越大(滑得越快), 增益越高 → 快速滑动光标走更远, 慢速更精准。
                let speed = min(hypot(t.x, t.y), TrackpadTuning.accelCap)
                let gain = parent.sensitivity * (1 + speed * TrackpadTuning.accelK)
                moveAccX += t.x * gain
                moveAccY += t.y * gain
                flushMove(force: false)
            }
        }

        /// 节流发送累积位移: 距上次未到 moveInterval 就攒着, 手势结束时 force 冲掉余量。
        private func flushMove(force: Bool) {
            let now = ProcessInfo.processInfo.systemUptime
            if !force && now - lastMoveSent < moveInterval { return }
            // 收尾 (force) 时四舍五入, 把不足 1px 的亚像素余量也送出去, 避免长期累积的轻微漂移。
            let ix = force ? Int(moveAccX.rounded()) : Int(moveAccX)
            let iy = force ? Int(moveAccY.rounded()) : Int(moveAccY)
            if ix != 0 || iy != 0 {
                moveAccX -= CGFloat(ix); moveAccY -= CGFloat(iy)
                lastMoveSent = now
                parent.onMove(ix, iy)
            }
        }

        @objc func handlePan2(_ g: UIPanGestureRecognizer) {
            if g.state == .began { scrollRemX = 0; scrollRemY = 0; aborted = false }   // 每次手势独立, 不继承上次余量
            if g.state == .ended || g.state == .cancelled { scrollRemX = 0; scrollRemY = 0; aborted = false; return }
            if abortIfOutside(g) { return }
            let t = g.translation(in: g.view); g.setTranslation(.zero, in: g.view)
            emitScroll(fx: t.x, fy: t.y)          // 双指拖 = 滚动 (横纵都支持)
        }

        /// 把手指位移转成「像素级滚动增量」发出去: 取负保持原方向(手指下滑→内容向下滚),
        /// 乘增益, 累积亚像素余量, 只发整数。客户端再做合并+背压、服务端 macOS 做像素级平滑滚动。
        private func emitScroll(fx: CGFloat, fy: CGFloat) {
            // 滚动速度可调 + 轻微加速度: 快速滑动滚更远, 慢速更精准。取负保持原方向。
            let speed = min(hypot(fx, fy), TrackpadTuning.accelCap)
            let gain = parent.scrollSpeed * (1 + speed * TrackpadTuning.scrollAccelK)
            scrollRemX += -fx * gain
            scrollRemY += -fy * gain
            let ix = Int(scrollRemX), iy = Int(scrollRemY)
            if ix != 0 || iy != 0 {
                scrollRemX -= CGFloat(ix); scrollRemY -= CGFloat(iy)
                parent.onScroll(ix, iy)
            }
        }

        @objc func handleTap1() { parent.onLeftClick() }
        @objc func handleTap2() { parent.onRightClick() }
    }
}

/// 触控板控件: 只是一整块手势面 (单指移动 / 双指滚动 / 轻点左键 / 双指点右键)。
/// 不再自带按钮条 —— 左键/右键/按住拖动等都做成独立的 .mouseButton 键, 用户自由摆放。
struct TrackpadView: View {
    let client: SidekeyClient
    var enabled: Bool = true
    @Environment(\.sidekeyTheme) private var theme
    @Environment(\.inputGuard) private var inputGuard
    @State private var guardID = UUID()
    @State private var resetToken = 0          // §5.2: 变一次 = 取消正在进行的手势并清掉累积位移
    @AppStorage("sidekey.trackpad.speed") private var trackpadSpeed: Double = TrackpadTuning.defaultSpeed
    @AppStorage("sidekey.scroll.speed") private var scrollSpeed: Double = TrackpadTuning.scrollDefaultSpeed

    var body: some View {
        surface
            .opacity(enabled ? 1 : 0.4)
            .allowsHitTesting(enabled)
            .onAppear { inputGuard?.register(guardID) { resetToken &+= 1 } }
            .onDisappear { inputGuard?.unregister(guardID) }
    }

    private var surface: some View {
        let shape = RoundedRectangle(cornerRadius: theme.radiusCard, style: .continuous)
        return ZStack {
            shape.fill(theme.surfaceMuted)
            TrackpadSurface(
                sensitivity: CGFloat(trackpadSpeed),
                scrollSpeed: CGFloat(scrollSpeed),
                onMove: { dx, dy in if inputGuard?.frozen != true { client.sendMouseMove(dx: dx, dy: dy) } },
                onScroll: { dx, dy in if inputGuard?.frozen != true { client.sendMouseScroll(dx: dx, dy: dy) } },
                onLeftClick: {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    if let g = inputGuard { g.mouseClick(button: "left") } else { client.sendMouseClick(button: "left") }
                },
                onRightClick: {
                    UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                    if let g = inputGuard { g.mouseClick(button: "right") } else { client.sendMouseClick(button: "right") }
                },
                resetToken: resetToken
            )
            VStack(spacing: 6) {
                Image(systemName: "hand.point.up.left")
                    .font(.system(size: 28, weight: .light)).foregroundStyle(theme.hint)
                Text("触控板").font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.textSecondary)
                Text("单指移动 · 轻点左键 · 双指点右键 · 双指滚动\n右侧边单指上下滑也能滚动")
                    .font(.system(size: 11)).foregroundStyle(theme.hint)
                    .multilineTextAlignment(.center)
            }
            .allowsHitTesting(false)   // 提示文字不挡手势

            // 右侧滚动条区: 单指上下滑即滚动 (淡色竖带 + 上下箭头), 画在提示之上不被遮挡, 不挡手势
            GeometryReader { geo in
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    ZStack {
                        Rectangle().fill(theme.accent.opacity(0.05))
                        Image(systemName: "arrow.up.and.down")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(theme.hint)
                    }
                    .frame(width: TrackpadTuning.scrollBandWidth(geo.size.width))
                    .overlay(Rectangle().fill(theme.hairline).frame(width: 1), alignment: .leading)
                }
            }
            .allowsHitTesting(false)
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(theme.hairline, lineWidth: 1))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

}

/// 独立鼠标键 (KeyCap.Kind.mouseButton):
/// - code "left" 「左键」: 按住 = 左键 down, 松开 = up —— 轻点即一次单击, 按住可拖(另一只手在触控板上移动)。
/// - code "right" 「右键」: 点一下 = 右键单击。
/// 由 KeyboardView 在正常模式渲染 (编辑器里仍是 KeyTile 静态块, 可拖拽/缩放)。
///
/// 触摸用 UIKit 的 `KeyPressTracker` (UILongPress, 最短按压 0): 每个 .began 必有且仅有一个终结态 (.ended / .cancelled / .failed),
/// 所以「每一次触摸」都从 `PressLifecycle` 的一次新按压开始、以 up / cancel 结束, 不靠任何会残留到下一次触摸的标志位 (审计第二轮阻断 2)。
struct MouseKeyButton: View {
    let cap: KeyCap
    let client: SidekeyClient
    var enabled: Bool = true
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.inputGuard) private var inputGuard
    @State private var guardID = UUID()
    @State private var life = PressLifecycle()

    private var isLeft: Bool { cap.code.lowercased() != "right" }
    private var held: Bool { life.pressed }

    // 鼠标事件经窗口的输入守卫 (连接池级仲裁); 没有守卫 (编辑器等) 时直接发。
    private func mouseDown() { if let g = inputGuard { g.mouseDown(button: "left", source: guardID) } else { client.sendMouseDown(button: "left") } }
    private func mouseUp() { if let g = inputGuard { g.mouseUp(button: "left", source: guardID) } else { client.sendMouseUp(button: "left") } }
    private func mouseClick(_ b: String) { if let g = inputGuard { g.mouseClick(button: b) } else { client.sendMouseClick(button: b) } }

    var body: some View {
        KeyTile(cap: cap, enabled: enabled, pressed: held)
            .contentShape(Rectangle())
            .opacity(enabled ? 1 : 0.4)
            .allowsHitTesting(enabled)
            .overlay(KeyPressTracker(cancelOnMove: !isLeft, onDown: pressDown, onUp: pressUp, onCancel: pressCancel))
            .onAppear {
                // 守卫中断时已经替我们发了 up, 这里只作废这次按压 (之后到的 .ended 不会再触发; 下一次触摸是新的一次按压)
                inputGuard?.register(guardID) { life.cancel() }
            }
            .onDisappear { releaseIfHeld(); inputGuard?.unregister(guardID) }
            .onChange(of: scenePhase) { p in if p != .active { releaseIfHeld() } }
            .onChange(of: enabled) { on in if !on { releaseIfHeld() } }
    }

    // MARK: 一次触摸的生命周期 (来自 KeyPressTracker, 主线程)
    private func pressDown() {
        // 冻结期间拒绝新输入; 没启用不响应
        guard life.down(enabled: enabled, frozen: inputGuard?.frozen == true) else { return }
        UIImpactFeedbackGenerator(style: isLeft ? .light : .rigid).impactOccurred()
        if isLeft { mouseDown() }
    }

    private func pressUp() {
        if isLeft {
            let wasPressed = life.pressed
            _ = life.up(enabled: true)
            if wasPressed { mouseUp() }
        } else if life.up(enabled: enabled) {          // 被取消的按压, 后到的 .ended 不再补发单击
            mouseClick("right")
        }
    }

    /// .cancelled / .failed (系统取消、被别的手势抢走): 左键要松开, 右键什么都不发。
    private func pressCancel() { releaseIfHeld(); life.cancel() }

    private func releaseIfHeld() {
        let wasPressed = life.pressed
        life.cancel()
        if isLeft, wasPressed { mouseUp() }
    }
}
