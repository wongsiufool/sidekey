import SwiftUI
import UIKit

/// 柔光软键帽 (brief SoftKey): 近白填充 + 1pt hairline + 双层柔影; 符号在上、说明在下。
/// 按下 = 下沉 2pt + 轻染珊瑚 + 阴影收紧 (无 3D 侧壁 / 玻璃高光 / 厚黑影)。编辑选中 = 珊瑚描边。
/// 字体: 普通功能键 = SF Pro Rounded; 数字/字母/斜杠命令 = SF Mono; Enter = 唯一实心珊瑚; 权限键 = 白底珊瑚描边。
struct KeyTile: View {
    let cap: KeyCap
    var enabled: Bool = true
    var pressed: Bool = false
    var repeating: Bool = false
    var selected: Bool = false
    var permissionMode: PermissionMode = .ask
    var effortLevel: EffortLevel = .high
    @Environment(\.sidekeyTheme) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: theme.radiusKey, style: .continuous)
        let p = theme.pressedShadow
        let isPermission = cap.kind == .permission
        // 权限键 = 白底 + 珊瑚 2pt 描边 (强调但非实心); 选中也用珊瑚 2pt。
        let borderColor = (selected || isPermission) ? theme.accent : theme.hairline
        let borderWidth: CGFloat = (selected || isPermission) ? 2 : 1

        return shape.fill(resolved.0)
            .overlay(shape.fill(theme.accent.opacity(pressed ? 0.12 : 0)))
            .overlay(keyContent)
            .overlay(shape.strokeBorder(borderColor, lineWidth: borderWidth))
            .overlay(                                                       // 长按连发: 珊瑚脉冲环
                shape.strokeBorder(theme.accent, lineWidth: 2)
                    .scaleEffect(repeating ? 1.04 : 1)
                    .opacity(repeating ? 0.9 : 0)
                    .animation(repeating ? .easeInOut(duration: 0.45).repeatForever(autoreverses: true)
                                         : .easeOut(duration: 0.1), value: repeating)
            )
            .compositingGroup()
            .modifier(KeyShadow(theme: theme, pressed: pressed, selected: selected, p: p))
            .offset(y: pressed ? 2 : 0)
            .opacity(enabled ? 1 : 0.4)
    }

    // MARK: - 键面内容: 按键种类选择不同「脸」(统一图标语言: 一个图标 + 一行 13 微标签)
    @ViewBuilder private var keyContent: some View {
        Group {
            if cap.kind == .permission {
                permissionFace
            } else if cap.kind == .effort {
                effortFace
            } else if cap.kind == .trackpad {
                trackpadFace
            } else if cap.kind == .mouseButton {
                mouseFace
            } else if cap.kind == .layer {
                layerFace
            } else if isBackspace {
                backspaceFace
            } else if isEnter {
                enterFace
            } else if isEscape {
                escapeFace
            } else if isSpace {
                spaceFace
            } else if isCommand {
                commandFace
            } else if isMonoChar {
                Text(loc(cap.label))
                    .font(.system(size: 24, weight: .semibold, design: .monospaced))
                    .foregroundStyle(resolved.1)
            } else if isArrowFace {
                arrowFace
            } else {
                defaultFace
            }
        }
        .lineLimit(1).minimumScaleFactor(0.5)
        .padding(.horizontal, 6)
    }

    /// 统一微标签 (13 semibold rounded) —— 全 App 唯一的键面文字层级。
    private func microLabel(_ text: String, color: Color) -> some View {
        Text(text).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(color)
    }

    /// 键标签「显示时本地化」: cap.label 是用户数据, 内置/目录标签(左键/↑ 上/Fn…)命中 en 表显示英文,
    /// 自定义标签未命中则原样显示。不改存储值, 不碰迁移/测试 (审计 L-2)。
    private func loc(_ s: String) -> String { s.isEmpty ? s : NSLocalizedString(s, comment: "") }

    /// 找到第一个本系统真实存在的 SF Symbol (避免某些名字在旧系统上渲染成空白)。
    private func sym(_ candidates: String...) -> String {
        for n in candidates where UIImage(systemName: n) != nil { return n }
        return candidates.last ?? candidates.first ?? "questionmark"
    }

    // 权限键: 锁盾 + 「权限 · X」+ 「⇧Tab」。X = 上次由本机请求的档位 (非 Claude 实时状态, App 读不到); 点开面板里有说明 (审计 M-8)。
    private var permissionFace: some View {
        VStack(spacing: 3) {
            Image(systemName: "lock.shield")
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(theme.accent)
            Text(String(localized: "权限 · \(permissionMode.shortLabel)"))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.textPrimary)
            Text("⇧Tab")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(theme.textTertiary)
        }
    }

    // 鼠标键 (左键/右键): 鼠标指针图标 + 名称。左键珊瑚、右键中性 —— 靠颜色区分, 不靠读字。
    private var mouseFace: some View {
        VStack(spacing: 4) {
            Image(systemName: "cursorarrow.click")
                .font(.system(size: 22, weight: .medium)).foregroundStyle(resolved.1)
            // cap.label 是用户数据; 用 NSLocalizedString 做「显示时本地化」—— 出厂内置标签(左键/右键)命中 en 表显示英文,
            // 自定义标签未命中则原样显示。不改存储值, 不影响迁移/测试 (审计 L-2: 闭合 seed-label 可见缺口)。
            microLabel(cap.label.isEmpty ? (cap.code.lowercased() == "right" ? String(localized: "右键") : String(localized: "左键")) : NSLocalizedString(cap.label, comment: ""),
                       color: resolved.1)
        }
    }

    // 触控板块 (编辑器里的静态表示; 正常模式由 KeyboardView 换成真正的 TrackpadView)。
    private var trackpadFace: some View {
        VStack(spacing: 4) {
            Image(systemName: sym("rectangle.and.hand.point.up.left.fill", "hand.point.up.left.fill", "hand.point.up.left"))
                .font(.system(size: 24, weight: .medium)).foregroundStyle(theme.textSecondary)
            microLabel(String(localized: "触控板"), color: theme.textSecondary)
        }
    }

    // Effort 键: 仪表盘 + 「Effort · X」。X = 上次由本机设定的档位 (非 Claude 实时状态, App 读不到); 点开面板里有说明 (审计 M-8)。
    private var effortFace: some View {
        VStack(spacing: 3) {
            Image(systemName: sym("gauge.with.dots.needle.50percent", "speedometer"))
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(theme.accent)
            microLabel(String(localized: "Effort · \(effortLevel.shortLabel)"), color: theme.textPrimary)
        }
    }

    // Backspace: 自绘 delete-left 图标 (不用 ⌫); 有非占位 label 时在下方标注。
    private var backspaceFace: some View {
        let showLabel = !cap.label.isEmpty && cap.label != "⌫"
        let c = cap.tint == nil ? theme.textSecondary : resolved.1
        return VStack(spacing: 4) {
            DeleteLeftShape()
                .stroke(c, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .frame(width: 32, height: 22)
            if showLabel { microLabel(loc(cap.label), color: c) }
        }
    }

    // 斜杠命令键: 浅珊瑚底 + 品牌 `>_` 矢量标记 + 等宽命令文字 (和主页 logo 同一个 PromptGlyph)。
    private var commandFace: some View {
        VStack(spacing: 4) {
            PromptGlyph()
                .stroke(theme.accent, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                .frame(width: 16, height: 12)
            Text(loc(cap.label))
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(theme.accent)
        }
    }

    // 方向键: 珊瑚箭头 (SF Symbol) + (可选)中文说明 (10 三级)。
    private var arrowFace: some View {
        let glyph = keyGlyph(cap.code)
        let sub: String? = (!cap.label.isEmpty && cap.label != glyph) ? loc(cap.label) : nil
        let symbol = ["up": "arrow.up", "down": "arrow.down", "left": "arrow.left", "right": "arrow.right"][cap.code.lowercased()] ?? "arrow.up"
        return VStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 26, weight: .medium)).foregroundStyle(theme.accent)
            if let sub { Text(sub).font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textTertiary) }
        }
    }

    // Enter: 唯一实心珊瑚操作键, return 符号 (无冗余文字)。
    private var enterFace: some View {
        Image(systemName: sym("return", "arrow.turn.down.left"))
            .font(.system(size: 26, weight: .semibold)).foregroundStyle(resolved.1)
    }

    // Esc: escape 符号 (不重复印 "Esc"); 仅当作者另设非占位 label 时才标注。
    private var escapeFace: some View {
        let showLabel = !cap.label.isEmpty && cap.label.lowercased() != "esc" && cap.label != "Esc" && cap.label != "ESC"
        return VStack(spacing: 4) {
            Image(systemName: sym("escape")).font(.system(size: 24, weight: .medium)).foregroundStyle(resolved.1)
            if showLabel { microLabel(loc(cap.label), color: resolved.1) }
        }
    }

    // 空格: 自绘 ⎵ 标记 + 「空格」。
    private var spaceFace: some View {
        let labelText = (cap.label.isEmpty || cap.label.lowercased() == "space") ? String(localized: "空格") : loc(cap.label)
        return VStack(spacing: 6) {
            SpaceBarShape()
                .stroke(theme.textSecondary, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .frame(width: 34, height: 12)
            microLabel(labelText, color: theme.textSecondary)
        }
    }

    // 切层键: 叠层图标 + 层名 (实心珊瑚, 与 Enter 并列为仅有的两个实心键)。
    private var layerFace: some View {
        VStack(spacing: 4) {
            Image(systemName: sym("square.stack.3d.up.fill", "square.stack.3d.up", "rectangle.stack.fill"))
                .font(.system(size: 22, weight: .medium)).foregroundStyle(resolved.1)
            if !cap.label.isEmpty { microLabel(loc(cap.label), color: resolved.1) }
        }
    }

    /// 默认键面 (工作模式 / 自定义键 / Enter / Typeless 等):
    /// 组合键优先呈现真实快捷键符号, 中文功能名作为次级说明; 没有组合键时退回图标 / 文字。
    private var defaultFace: some View {
        let isRecord = cap.kind == .record
        let hasIcon = !(cap.icon ?? "").isEmpty
        let hasLabel = !cap.label.isEmpty
        let shortcut = shortcutTitle
        let titleIsShortcut = shortcut != nil
        let title = shortcut ?? plainTitle
        let showSubtitle = hasLabel && loc(cap.label) != title   // 用本地化后的标签比较, 避免 title/副标重复 (L-2)
        return VStack(spacing: 4) {
            if let title {
                Text(title)
                    .font(.system(size: titleIsShortcut ? 25 : 24, weight: .medium, design: .rounded))
            } else if isRecord {
                Image("TypelessLogo").renderingMode(.template).resizable().scaledToFit()
                    .frame(width: 30, height: 30)
            } else if cap.icon == "typeless" {
                // 用 icon="typeless" 这个特殊值, 让任意普通键也能贴 Typeless logo (保留键本身的 code/mods)。
                Image("TypelessLogo").renderingMode(.template).resizable().scaledToFit()
                    .frame(width: hasLabel ? 26 : 30, height: hasLabel ? 26 : 30)
            } else if hasIcon {
                Image(systemName: cap.icon!).font(.system(size: hasLabel ? 27 : 30, weight: .medium))
            }
            if showSubtitle {
                Text(loc(cap.label))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
            }
        }
        .foregroundStyle(resolved.1)
    }

    // MARK: - 种类判定
    private var isBackspace: Bool { cap.kind == .normal && cap.code.lowercased() == "backspace" }
    /// 无修饰键的独立 Enter/Esc/空格 → 用专属图标脸; 带修饰键的组合(如 ⇧Enter)仍走 defaultFace 显示组合符号。
    private var isPlainSpecial: Bool { cap.kind == .normal && cap.mods.isEmpty && (cap.sendText ?? "").isEmpty }
    private var isEnter: Bool { isPlainSpecial && ["enter", "return"].contains(cap.code.lowercased()) }
    private var isEscape: Bool { isPlainSpecial && ["esc", "escape"].contains(cap.code.lowercased()) }
    private var isSpace: Bool { isPlainSpecial && cap.code.lowercased() == "space" }
    private var isCommand: Bool { cap.kind == .normal && !(cap.sendText ?? "").isEmpty && (cap.icon ?? "").isEmpty }
    private var isArrowFace: Bool {
        cap.kind == .normal && cap.tint == nil && cap.mods.isEmpty
            && ["up", "down", "left", "right"].contains(cap.code.lowercased())
    }
    private var isMonoChar: Bool {
        cap.kind == .normal && cap.mods.isEmpty && (cap.sendText ?? "").isEmpty
            && cap.code.count == 1
            && cap.code.range(of: "^[0-9a-zA-Z]$", options: .regularExpression) != nil
    }

    /// 仅当按键具有修饰键或可识别的特殊键码时显示快捷键标题，避免把普通「Home」重复显示两次。
    private var shortcutTitle: String? {
        guard cap.kind == .normal, !cap.code.isEmpty else { return nil }
        let code = keyGlyph(cap.code)
        let modifiers = cap.mods.compactMap(modifierGlyph).joined()
        guard !modifiers.isEmpty || isSpecialCode(cap.code) else { return nil }
        return modifiers.isEmpty ? code : "\(modifiers) \(code)"
    }

    private var plainTitle: String? {
        guard cap.kind != .record else { return nil }
        if let icon = cap.icon, !icon.isEmpty { return nil }
        return cap.label.isEmpty ? nil : loc(cap.label)   // 标签显示时本地化 (L-2)
    }

    private func isSpecialCode(_ code: String) -> Bool {
        ["enter", "return", "backspace", "esc", "escape", "left", "right", "up", "down"].contains(code.lowercased())
    }

    private func keyGlyph(_ code: String) -> String {
        switch code.lowercased() {
        case "enter", "return": return "↵"
        case "backspace": return "⌫"
        case "esc", "escape": return "Esc"
        case "left": return "←"
        case "right": return "→"
        case "up": return "↑"
        case "down": return "↓"
        case "page_up": return "PgUp"
        case "page_down": return "PgDn"
        default: return code.uppercased()
        }
    }

    private func modifierGlyph(_ modifier: String) -> String? {
        switch modifier.lowercased() {
        case "primary", "cmd", "command", "lcmd", "rcmd": return "⌘"
        case "shift", "lshift", "rshift": return "⇧"
        case "ctrl", "control", "lctrl", "rctrl": return "⌃"
        case "alt", "option", "lalt", "ralt", "alt_gr": return "⌥"
        default: return nil
        }
    }

    private var isModifierOnly: Bool { cap.code.isEmpty && !cap.mods.isEmpty }

    /// (填充, 文字)。录音键 = accentLight + accent; layer = 珊瑚实心; permission = 白底(描边在 body); normal 按 tint/修饰键/普通。
    private var resolved: (AnyShapeStyle, Color) {
        switch cap.kind {
        case .record:     return (AnyShapeStyle(theme.accentLight), theme.accent)
        case .layer:      return (AnyShapeStyle(theme.accent), theme.accentText)
        case .permission: return (AnyShapeStyle(theme.keyFill), theme.keyText)
        case .trackpad:   return (AnyShapeStyle(theme.surfaceMuted), theme.textSecondary)
        case .mouseButton:                              // 左键 = 浅珊瑚强调; 右键 = 中性白键
            return cap.code.lowercased() == "right" ? (AnyShapeStyle(theme.keyFill), theme.keyText)
                                                    : (AnyShapeStyle(theme.accentLight), theme.accent)
        case .effort:
            if let t = cap.tint { return theme.tintStyle(t) }
            return (AnyShapeStyle(theme.keyFill), theme.keyText)
        case .normal:
            if let t = cap.tint { return theme.tintStyle(t) }
            return isModifierOnly ? (AnyShapeStyle(theme.keyModFill), theme.keyModText)
                                  : (AnyShapeStyle(theme.keyFill), theme.keyText)
        }
    }
}

/// 键帽阴影: 静态=柔光抬升; 按下/选中=收紧的内嵌阴影。
private struct KeyShadow: ViewModifier {
    let theme: SidekeyTheme
    let pressed: Bool
    let selected: Bool
    let p: (color: Color, radius: CGFloat, y: CGFloat)
    func body(content: Content) -> some View {
        if pressed {
            content.shadow(color: p.color, radius: p.radius, x: 0, y: p.y)
        } else {
            content.raisedShadow(theme)
                .shadow(color: selected ? theme.accent.opacity(0.18) : .clear, radius: 8, x: 0, y: 3)
        }
    }
}

/// 正常模式下可点击的按键: 轻点抬手即触发并震动; 普通键按住一会儿会「连发」(带脉冲环)。
/// 手指明显移动时视为「滑动」→ 取消这次按键 (把手势让给左右滑翻页), 避免滑动误触发键。
///
/// 用 UIKit 手势识别器跟踪按下/松开, **而不是 SwiftUI DragGesture** —— 因为 DragGesture 在快速连点时
/// 会漏掉 onEnded, 让 pressed 卡在 true、连发 Task 变孤儿停不下来 (Backspace 连点后自动狂删的真凶)。
/// UIKit 保证每个 .began 都有且仅有一个终结态(.ended/.cancelled/.failed), pressed 必定复位, 杜绝卡死。
struct KeyCapButton: View {
    let cap: KeyCap
    let enabled: Bool
    var repeatable: Bool = false
    var permissionMode: PermissionMode = .ask
    var effortLevel: EffortLevel = .high
    let action: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var pressed = false
    @State private var repeating = false
    @State private var didRepeat = false    // 这次按压是否真的进入过连发 (决定松手要不要补一次轻点)
    @State private var pressID = 0
    @State private var repeatTask: Task<Void, Never>?

    // 连发起始延迟: Backspace/方向键稍短(更跟手地删除/移动), 其它键较长, 避免正常轻点被当成长按。
    private var repeatDelayNanos: UInt64 {
        ["backspace", "left", "right", "up", "down"].contains(cap.code.lowercased()) ? 450_000_000 : 650_000_000
    }

    var body: some View {
        KeyTile(cap: cap, enabled: enabled, pressed: pressed, repeating: repeating,
                permissionMode: permissionMode, effortLevel: effortLevel)
            .animation(.easeOut(duration: 0.08), value: pressed)
            .overlay(KeyPressTracker(onDown: pressDown, onUp: pressUp, onCancel: cancelPress))
            .onDisappear { cancelPress() }
            .onChange(of: scenePhase) { phase in if phase != .active { cancelPress() } }
            .onChange(of: enabled) { on in if !on { cancelPress() } }
    }

    // MARK: - 按压生命周期 (来自 KeyPressTracker, 均在主线程)
    private func pressDown() {
        guard enabled, !pressed else { return }   // 未连接(禁用)键不响应、不闪
        pressed = true
        didRepeat = false
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if repeatable { startRepeat() }
    }

    private func pressUp() {
        let fired = didRepeat                 // 真连发过 → 松手不再补轻点
        stopRepeat()
        let shouldFire = enabled && !fired
        pressed = false
        if shouldFire { action() }
    }

    /// 滑动翻页 / 移出键面 / 被系统取消 / 退后台 / 断连 —— 统一取消本次按压, 不触发、不卡连发。
    private func cancelPress() {
        stopRepeat()
        pressed = false
    }

    private func startRepeat() {
        repeatTask?.cancel()
        pressID &+= 1
        let myID = pressID
        let delay = repeatDelayNanos
        repeatTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, myID == pressID, pressed else { return }
            repeating = true
            didRepeat = true
            while !Task.isCancelled, myID == pressID, pressed {
                action()
                try? await Task.sleep(nanoseconds: 90_000_000)
            }
        }
    }

    private func stopRepeat() {
        pressID &+= 1            // 让任何在跑的连发循环的 myID != pressID, 即刻失效(与 cancel 双保险)
        repeatTask?.cancel()
        repeatTask = nil
        repeating = false
    }
}

/// 可靠的「按下/松开/取消」跟踪 (UIKit UILongPressGestureRecognizer, minimumPressDuration=0)。
/// 关键: `cancelsTouchesInView=false` + 允许与其它手势同时识别 → 不挡父级左右滑翻页;
/// UIKit 保证 .began 必配一个 .ended/.cancelled/.failed, 所以 onUp/onCancel 一定会来, pressed 不会卡死。
private struct KeyPressTracker: UIViewRepresentable {
    let onDown: () -> Void
    let onUp: () -> Void
    let onCancel: () -> Void

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        let lp = UILongPressGestureRecognizer(target: context.coordinator,
                                              action: #selector(Coordinator.handle(_:)))
        lp.minimumPressDuration = 0          // 触地即 .began
        lp.allowableMovement = 10000         // 不靠它判滑动, 移动由我们在 .changed 里自己判, 全程掌控
        lp.cancelsTouchesInView = false      // 不吞触摸, 父级翻页手势照样收到
        lp.delegate = context.coordinator
        v.addGestureRecognizer(lp)
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) { context.coordinator.parent = self }
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: KeyPressTracker
        private var moved = false
        private var start: CGPoint = .zero   // 触地点; 位移超阈值即视为滑动 → 取消本键, 让位给翻页
        init(_ p: KeyPressTracker) { parent = p }

        // 相对触地点的位移超过阈值(横 12 / 纵 16, 与旧 DragGesture 一致) → 算滑动。比"滑出键面"更早,
        // 宽键(如 SPACE)也能尽早让位给翻页, 减少滑动时误触发一次。
        private func movedTooFar(_ g: UILongPressGestureRecognizer) -> Bool {
            guard let view = g.view else { return false }
            let p = g.location(in: view)
            return abs(p.x - start.x) > 12 || abs(p.y - start.y) > 16
        }

        @objc func handle(_ g: UILongPressGestureRecognizer) {
            switch g.state {
            case .began:
                moved = false
                start = g.view.map { g.location(in: $0) } ?? .zero
                parent.onDown()
            case .changed:
                if !moved, movedTooFar(g) {
                    moved = true
                    parent.onCancel()        // 已滑动 → 取消本键 (翻页由父级同时识别的手势接手)
                }
            case .ended:
                // 兜底: 若没收到中途 .changed 就直接松手, 这里再判一次位移, 避免滑动也补发一次。
                if !moved, movedTooFar(g) { moved = true }
                if !moved { parent.onUp() }
            case .cancelled, .failed:
                parent.onCancel()
            default:
                break
            }
        }

        // 与父级翻页 / 滚动手势同时识别, 不互相吞
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}
