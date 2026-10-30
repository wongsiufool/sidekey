import SwiftUI
import UIKit

/// 笔记本键盘的窗口级会话 (§4.9): 粘滞修饰键按窗口分别记, 不在窗口之间共享。
@MainActor
final class LaptopSession: ObservableObject {
    @Published private(set) var sticky = StickyModifiers()
    /// 不挡操作的短提示 (约 2 秒), 例如 Mac 上点 ⇪。
    @Published private(set) var notice: String?
    private var noticeToken = 0

    func flash(_ text: String, seconds: Double = 2) {
        noticeToken &+= 1
        let t = noticeToken
        notice = text
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            if self?.noticeToken == t { self?.notice = nil }
        }
    }

    func tap(_ m: LaptopModifier) { sticky.tap(m, at: ProcessInfo.processInfo.systemUptime) }
    func tapFn() { sticky.tapFn() }
    func begin(_ g: UUID) -> StickyModifiers.Snapshot { sticky.begin(g) }
    func end(_ g: UUID) { sticky.end(g) }
    func clearAll() { sticky.clearAll() }

    /// 发一个键: 一条一次性 key 消息, 粘住的修饰键放进 mods; 第一次真正发出时用掉「一次」。
    func send(_ key: LaptopKey, snapshot: StickyModifiers.Snapshot, gesture: UUID, client: SidekeyClient) {
        guard let m = LaptopKeymap.message(for: key, snapshot: snapshot) else { return }
        client.sendKey(KeyCap(label: "", code: m.code, mods: m.mods))
        sticky.didSend(gesture)
    }
}

/// 笔记本键盘的一个键。按压跟踪沿用 KeyPressTracker; 和普通键的区别是要把手势的开始、第一次发出、结束告诉粘滞修饰键:
/// 开始时预留「一次」, 第一次发出时用掉, 发出之前被取消就退还 (§4.9, v1.7)。
struct LaptopKeyView: View {
    let key: LaptopKey
    let platform: LaptopPlatform
    let enabled: Bool
    @ObservedObject var session: LaptopSession
    let client: SidekeyClient
    @Environment(\.sidekeyTheme) private var theme
    @Environment(\.inputGuard) private var inputGuard
    @Environment(\.scenePhase) private var scenePhase
    @State private var guardID = UUID()
    @State private var pressed = false
    @State private var gesture: UUID?
    @State private var snapshot = StickyModifiers.Snapshot()
    @State private var didRepeat = false
    @State private var repeatTask: Task<Void, Never>?

    private var isModifier: Bool { key.modifier != nil || key.isFn }
    private var stickyState: StickyModifiers.State {
        if let m = key.modifier { return session.sticky.state(m) }
        if key.isFn { return session.sticky.fnOnce ? .once : .off }
        return .off
    }

    var body: some View {
        GeometryReader { g in
            face(g.size)
                .overlay(KeyPressTracker(onDown: down, onUp: up, onCancel: cancel))
        }
        .opacity(enabled ? 1 : 0.4)
        .onAppear {
            inputGuard?.register(guardID) { cancel() }                 // §5.2: 布局变化时取消这次按压
            #if DEBUG
            LaptopKeyTestHooks.last = self
            #endif
        }
        .onDisappear { cancel(); inputGuard?.unregister(guardID) }
        .onChange(of: scenePhase) { p in if p != .active { cancel() } }
        .onChange(of: enabled) { on in if !on { cancel() } }           // 禁用 / 断线: 取消按压和连发, 迟到的松手也不补发 (M3 审计 B2)
        .accessibilityElement()
        .accessibilityLabel([key.symbol, key.word].compactMap { $0 }.joined(separator: " ").isEmpty ? String(localized: "空格") : [key.symbol, key.word].compactMap { $0 }.joined(separator: " "))
        .accessibilityValue(stickyState == .locked ? String(localized: "已锁定") : stickyState == .once ? String(localized: "粘住一次") : "")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("laptop.\(key.id)")
    }

    // MARK: 键面: 主字 + 功能键下方小字 / 数字标点上方的 Shift 符号; 粘住一次 = 右上角圆点, 锁定 = 实心底 + 下方短线
    private func face(_ size: CGSize) -> some View {
        let shape = RoundedRectangle(cornerRadius: min(10, size.height * 0.24), style: .continuous)
        let locked = stickyState == .locked
        let fill: Color = locked ? theme.accent : (pressed ? theme.accentLight : (isModifier || key.word != nil ? theme.surfaceMuted : theme.surface))
        let ink: Color = locked ? theme.accentText : theme.textPrimary
        let showWord = key.word != nil && size.width >= 50 && size.height >= 36
        return shape.fill(fill)
            .overlay(shape.strokeBorder(theme.hairline, lineWidth: 1))
            .overlay {
                VStack(spacing: 1) {
                    if let h = key.shiftHint, size.height >= 36 {
                        Text(h).font(.system(size: 10.5, weight: .medium)).foregroundStyle(locked ? ink : theme.textSecondary)
                    }
                    Text(key.symbol)
                        .font(.system(size: key.symbol.count > 2 ? (size.height < 36 ? 12 : 13) : (size.height < 44 ? 15 : 17),
                                      weight: isModifier || key.word != nil ? .semibold : .medium))
                        .foregroundStyle(ink)
                    if showWord, let w = key.word {
                        Text(w).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(locked ? ink : theme.textSecondary)
                    }
                }
                .lineLimit(1)
            }
            .overlay(alignment: .topTrailing) {
                if stickyState == .once { Circle().fill(theme.accent).frame(width: 6, height: 6).padding(5) }
            }
            .overlay(alignment: .bottom) {
                if locked { Capsule().fill(theme.accentText).frame(width: 18, height: 3).padding(.bottom, 4) }
            }
    }

    // MARK: 按压
    private func down() {
        guard enabled, inputGuard?.frozen != true, !pressed else { return }
        pressed = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        guard !isModifier else { return }                  // 修饰键 / fn: 松手时切换状态, 不发消息
        let g = UUID()
        gesture = g
        snapshot = session.begin(g)                        // 手势一开始就拍快照、预留「一次」
        didRepeat = false
        if key.repeats { startRepeat(g) }
    }

    private func up() {
        guard pressed else { return }
        pressed = false
        stopRepeat()
        guard enabled, inputGuard?.frozen != true else { if let g = gesture { session.end(g) }; gesture = nil; return }
        if let m = key.modifier { session.tap(m); return }
        if key.isFn { session.tapFn(); return }
        guard let g = gesture else { return }
        if !didRepeat { session.send(key, snapshot: snapshot, gesture: g, client: client) }
        // Mac 上 ⇪ 切换不了大写锁定 (§4.9, M3f 实测): 照样发 caps, 弹一条不挡操作的提示; Windows 不提示
        if key.id == "k.caps", platform == .mac { session.flash(String(localized: "Mac 上切换不了大写锁定，打大写请用 ⇧")) }
        session.end(g)
        gesture = nil
    }

    /// 被取消 (§5.2 的旋转、调换、开合、布局变化, 或手指移出): 还没发出就退还「一次」, 已发出的不退。
    private func cancel() {
        stopRepeat()
        pressed = false
        if let g = gesture { session.end(g) }
        gesture = nil
    }

    private func startRepeat(_ g: UUID) {
        repeatTask?.cancel()
        let delay: UInt64 = ["k.backspace", "k.left", "k.right", "k.up", "k.down"].contains(key.id) ? 450_000_000 : 650_000_000
        repeatTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delay)
            while !Task.isCancelled, pressed, gesture == g, enabled, inputGuard?.frozen != true {
                didRepeat = true
                session.send(key, snapshot: snapshot, gesture: g, client: client)   // 整串用开始时的快照
                try? await Task.sleep(nanoseconds: 90_000_000)
            }
        }
    }

    private func stopRepeat() { repeatTask?.cancel(); repeatTask = nil }
}

/// 一块键盘 (竖屏一整块, 或横屏分体的一半): 同一节距, 各行左对齐。
struct LaptopKeyBlock: View {
    let rows: [[LaptopKey]]
    let unit: CGFloat
    let rowHeight: CGFloat
    let platform: LaptopPlatform
    let enabled: Bool
    @ObservedObject var session: LaptopSession
    let client: SidekeyClient

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(rows.enumerated()), id: \.offset) { ri, row in
                let frames = LaptopLayoutPlan.keyFrames(row, in: CGRect(x: 0, y: 0, width: 0, height: 0), rowIndex: ri, unit: unit, rowH: rowHeight)
                ForEach(Array(row.enumerated()), id: \.offset) { ci, k in
                    LaptopKeyView(key: k, platform: platform, enabled: enabled, session: session, client: client)
                        .frame(width: frames[ci].width, height: frames[ci].height)
                        .offset(x: frames[ci].minX, y: frames[ci].minY)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// 掌托 (横屏左下 / 调换后右下): 空白, 不响应触摸。
struct LaptopPalmRest: View {
    @Environment(\.sidekeyTheme) private var theme
    var body: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(theme.hairline, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            .overlay(Text("掌托").font(.system(size: 12.5)).foregroundStyle(theme.textTertiary))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// 外屏 / 窗口放不下时的提示卡 (§4.9): 「使用触控板」+「切换模式 / 换个模式」。
struct LaptopNoticeCard: View {
    let title: String
    let detail: String
    let onTrackpad: () -> Void
    let onSwitchMode: () -> Void
    var switchTitle: String = String(localized: "切换模式")
    @Environment(\.sidekeyTheme) private var theme

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "laptopcomputer").font(.system(size: 30, weight: .medium)).foregroundStyle(theme.accentInk)
            Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(theme.textPrimary).multilineTextAlignment(.center)
            Text(detail).font(.system(size: 13)).foregroundStyle(theme.textSecondary).multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button(action: onTrackpad) {
                    Text("使用触控板").font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.accentText)
                        .frame(maxWidth: .infinity, minHeight: 44).background(Capsule().fill(theme.accent))
                }
                .buttonStyle(.plain).accessibilityIdentifier("laptopUseTrackpad")
                Button(action: onSwitchMode) {
                    Text(switchTitle).font(.system(size: 15)).foregroundStyle(theme.textPrimary)
                        .frame(maxWidth: .infinity, minHeight: 44).overlay(Capsule().strokeBorder(theme.hairline, lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain).accessibilityIdentifier("laptopSwitchMode")
            }
        }
        .padding(20)
        .frame(maxWidth: 420)
        .background(RoundedRectangle(cornerRadius: theme.radiusCard, style: .continuous).fill(theme.surface).raisedShadow(theme))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("laptopNoticeCard")
    }
}

#if DEBUG
/// 单测挂载用 (只在 DEBUG 编译)。
@MainActor enum LaptopKeyTestHooks { static var last: LaptopKeyView? }
extension LaptopKeyView {
    func testDown() { down() }
    func testUp() { up() }
    var testPressed: Bool { pressed }
}
#endif
