#if DEBUG
import Combine
import SwiftUI
import UIKit

/// iPhone Duo 适配 · M0 测量页 (只在 DEBUG 构建里存在; Release 里整个文件不参与编译)。
/// 用来关掉需求文档 design/iphone-duo-v1/README.md 的 Q3(判屏)、Q4(外屏尺寸)、Q13(多窗口合屏)。
/// 入口: 启动参数 `--duoprobe` 直接以本页为根视图; 或 设置 → 帮助 →「Duo 测量（调试）」。
/// 每次关键数值变化记一条快照: 屏幕上显示、控制台打印 `DUOPROBE {json}`、追加到 Documents/duoprobe-log.jsonl。
struct DuoProbeView: View {
    var onClose: (() -> Void)? = nil

    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.verticalSizeClass) private var vSize
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.displayScale) private var displayScale
    @StateObject private var recorder = DuoProbeRecorder()
    @State private var window: UIWindow?
    @State private var hinge: DuoProbeHinge?
    @State private var label = ""
    @State private var tick = 0          // 每秒 +1, 触发重算: 屏幕/scene 属性变化时 SwiftUI 不一定会自己刷新
    @State private var sceneError: String?
    // M3 前置实测 (Q19 系统键盘、Q22 隐藏状态栏) 用
    @State private var keyboardFrame: CGRect = .zero      // 屏幕坐标; .zero = 没有键盘
    @State private var hideStatusBar = false
    @State private var backgroundTaps = 0
    // M3a 布局预览: 观测 → 层 2 防抖 → 层 3 DuoLayout, 把各区画出来并把 frame 记进日志
    @State private var layoutPreview = false
    @State private var previewSwapped = false
    @State private var previewSingle: SingleZone = .keys
    @State private var duoHinge: DuoHinge = .unknown
    @State private var stabilizer = LayoutStabilizer<DuoObservation>(posture: { o in DuoLayout.posture(o.normalized(), DuoLayout.classify(o.normalized())).rawValue })
    @State private var stablePlan: DuoLayoutPlan?

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { proxy in
            let regions = DuoProbeAPI.regions(proxy)
            let snap = makeSnapshot(container: proxy.size, safe: proxy.safeAreaInsets, regions: regions)
            let obs = observation(proxy)
            ZStack(alignment: .topLeading) {
                Color(.systemBackground)
                ScrollView { panel(snap) }
                regionOverlay(regions)
                if layoutPreview, let plan = stablePlan { layoutOverlay(plan, safe: proxy.safeAreaInsets) }
            }
            .onAppear { recorder.record(snap, event: "appear"); feed(obs) }
            .onChange(of: obs) { feed($0) }
            // 用回调参数里的新值, 不用闭包捕获的 snap: iOS 16 式 onChange 的闭包可能还是变化前那次渲染的。
            .onChange(of: snap) { recorder.record($0, event: "change") }
            .onReceive(ticker) { _ in tick &+= 1 }
        }
        .background(DuoProbeWindowReader { window = $0 })
        .duoProbeHinge($hinge)
        .duoHinge($duoHinge)
        .statusBarHidden(hideStatusBar)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { n in
            keyboardFrame = (n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect) ?? .zero
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in keyboardFrame = .zero }
    }

    // MARK: - 快照

    private func makeSnapshot(container: CGSize, safe: EdgeInsets, regions: [DuoProbeRegion]) -> DuoProbeSnapshot {
        _ = tick
        let scene = window?.windowScene
        let screen = scene?.screen
        let native = screen?.nativeBounds.size ?? .zero
        return DuoProbeSnapshot(
            time: "", event: "", label: label,
            sceneID: scene.map { String($0.session.persistentIdentifier.suffix(6)) } ?? "-",
            screenGuess: Self.guessScreen(screen?.bounds.size ?? .zero)
                + " · 正式判屏=" + (ScreenContext.classify(ScreenProbe.current(for: scene)) == .inner ? "内屏" : "手机屏")
                + " · " + String(describing: ScreenProbe.current(for: scene)) + " role=\(scene?.session.role.rawValue ?? "nil") mirrored=\(screen?.mirrored != nil)",
            screenNative: fmt(native),
            screenBounds: fmt(screen?.bounds.size ?? .zero),
            screenScale: Double(screen?.scale ?? 0),
            screenNativeScale: Double(screen?.nativeScale ?? 0),
            traitDisplayScale: Double(displayScale),
            sceneBounds: fmt(scene?.coordinateSpace.bounds.size ?? .zero),
            container: fmt(container),
            safeArea: String(format: "t%.0f l%.0f b%.0f r%.0f", safe.top, safe.leading, safe.bottom, safe.trailing),
            hSizeClass: Self.name(hSize), vSizeClass: Self.name(vSize),
            orientation: scene.map { Self.name($0.interfaceOrientation) } ?? "-",
            scenePhase: Self.name(scenePhase),
            hingeStatus: hinge?.status ?? "nil", hingeAngle: hinge?.angle,
            regions: regions,
            scenes: Self.allScenes(),
            supportsMultipleScenes: UIApplication.shared.supportsMultipleScenes,
            duoAPICompiled: DuoProbeAPI.compiled,
            keyboard: keyboardDescription(),
            statusBarHidden: hideStatusBar,
            statusBarFrame: fmtRect(scene?.statusBarManager?.statusBarFrame ?? .zero),
            backgroundTaps: backgroundTaps
        )
    }

    /// 键盘: 屏幕坐标的 frame, 以及和本窗口重叠的部分 (窗口坐标)。
    private func keyboardDescription() -> String {
        guard keyboardFrame != .zero else { return "无" }
        var s = "screen=\(fmtRect(keyboardFrame))"
        if let w = window {
            let inWindow = w.convert(keyboardFrame, from: w.screen.coordinateSpace)
            let overlap = inWindow.intersection(w.bounds)
            s += " window=\(fmt(w.bounds.size)) overlap=\(overlap.isNull ? "无" : fmtRect(overlap))"
        }
        return s
    }

    /// Q3 判屏(需求文档 v1.5 §3.1): 按 screen.bounds(点)的**短边**, ≥ 600 就是内屏。
    /// 内屏 669 / 外屏 466 / 现有 iPhone 最大 440。不用长边: iPhone 17 Pro 长边 874 会误判。
    /// 不用 nativeBounds(模拟器内屏 2007×2853 ≠ 规格页 1878×2670), 也不用 size class(内屏 Split View 里是 compact)。
    static func guessScreen(_ points: CGSize) -> String {
        let s = min(points.width, points.height)
        if s == 0 { return "未知" }
        return s >= 600 ? "内屏" : "手机屏"
    }

    private static func allScenes() -> [String] {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.map { s in
            let n = s.screen.nativeBounds.size
            return "\(s.session.persistentIdentifier.suffix(6)) \(name(s.activationState)) screen=\(Int(n.width))x\(Int(n.height)) bounds=\(fmt(s.coordinateSpace.bounds.size))"
        }.sorted()
    }

    // MARK: - 界面

    private func panel(_ s: DuoProbeSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(verbatim: "Duo 测量（M0）").font(.headline)
                Spacer()
                if let onClose { Button(action: onClose) { Text(verbatim: "关闭") } }
            }
            TextField(text: $label) { Text(verbatim: "标签，例如：外屏竖屏 / 内屏半折") }
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
            HStack(spacing: 8) {
                button("记录") { recorder.record(s, event: "manual") }
                button("复制最新") { UIPasteboard.general.string = recorder.entries.last?.jsonLine }
                button("复制全部") { UIPasteboard.general.string = recorder.entries.map(\.jsonLine).joined(separator: "\n") }
                button("新窗口") { requestNewWindow() }
                button("清空") { recorder.clear() }
            }
            HStack(spacing: 8) {
                button(hideStatusBar ? "显示状态栏" : "隐藏状态栏") { hideStatusBar.toggle() }
                button("背景点击 \(backgroundTaps)") { backgroundTaps += 1 }
                button("收起键盘") { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
            }
            HStack(spacing: 8) {
                button(layoutPreview ? "关闭布局预览" : "布局预览") { layoutPreview.toggle(); replan(event: "layout-toggle") }
                if layoutPreview {
                    button(previewSwapped ? "调换：开" : "调换：关") { previewSwapped.toggle(); replan(event: "layout-swap") }
                    button(previewSingle == .keys ? "单区选：键盘" : "单区选：触控板") {
                        previewSingle = previewSingle == .keys ? .trackpad : .keys; replan(event: "layout-single")
                    }
                }
            }
            if let sceneError { Text(verbatim: "新窗口失败：\(sceneError)").foregroundStyle(.red) }

            Group {
                row("判屏猜测", s.screenGuess)
                row("screen.nativeBounds", s.screenNative)
                row("screen.bounds", s.screenBounds)
                row("scale / nativeScale / trait", String(format: "%.3f / %.3f / %.3f", s.screenScale, s.screenNativeScale, s.traitDisplayScale))
                row("scene bounds", s.sceneBounds)
                row("容器尺寸", s.container)
                row("安全区", s.safeArea)
                row("size class (h/v)", "\(s.hSizeClass) / \(s.vSizeClass)")
                row("界面方向", s.orientation)
                row("scenePhase", s.scenePhase)
                row("铰链", s.hingeAngle.map { "\(s.hingeStatus) \(String(format: "%.1f°", $0))" } ?? s.hingeStatus)
                row("Duo API 已编译", s.duoAPICompiled ? "是" : "否（需要 iOS 27.1 SDK）")
                row("多场景", s.supportsMultipleScenes ? "已启用" : "未启用")
                row("系统键盘", s.keyboard)
                row("状态栏", "\(s.statusBarHidden ? "隐藏" : "显示") frame=\(s.statusBarFrame)")
            }
            Text(verbatim: "保留区（红=division 蓝=occlusion，含非激活）").font(.subheadline.bold())
            if s.regions.isEmpty { Text(verbatim: "无").foregroundStyle(.secondary) }
            ForEach(Array(s.regions.enumerated()), id: \.offset) { _, r in
                Text(verbatim: "\(r.kind) \(r.isActive ? "激活" : "非激活") frame=\(r.frame) margins=\(r.margins)")
            }
            Text(verbatim: "所有窗口（scene）").font(.subheadline.bold())
            ForEach(s.scenes, id: \.self) { Text(verbatim: $0) }
            Text(verbatim: "最近记录（共 \(recorder.entries.count) 条）").font(.subheadline.bold())
            ForEach(Array(recorder.entries.suffix(6).reversed()), id: \.time) { e in
                Text(verbatim: "\(e.time.suffix(12)) \(e.event) [\(e.label)] \(e.screenGuess) \(e.container) h\(e.hSizeClass) \(e.hingeStatus)")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(16)
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(verbatim: k).foregroundStyle(.secondary).frame(width: 170, alignment: .leading)
            Text(verbatim: v).textSelection(.enabled)
        }
    }

    private func button(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(verbatim: title) }.buttonStyle(.bordered)
    }

    /// 把保留区画在实际位置上, 截图即可看出折痕落在哪。宽度为 0 的非激活折痕画成 2pt 线。
    private func regionOverlay(_ regions: [DuoProbeRegion]) -> some View {
        ForEach(Array(regions.enumerated()), id: \.offset) { _, r in
            let color: Color = r.kind == "division" ? .red : .blue
            Rectangle()
                .fill(color.opacity(r.isActive ? 0.35 : 0.15))
                .overlay(Rectangle().stroke(color, style: StrokeStyle(lineWidth: 1, dash: r.isActive ? [] : [4, 3])))
                .frame(width: max(r.rect.width, 2), height: max(r.rect.height, 2))
                .offset(x: r.rect.minX, y: r.rect.minY)
                .allowsHitTesting(false)
        }
    }

    // MARK: - M3a 布局预览

    /// 层 1: 这一刻的观测快照 (窗口坐标)。
    private func observation(_ proxy: GeometryProxy) -> DuoObservation {
        _ = tick
        let safe = proxy.safeAreaInsets
        var kind = ScreenContext.classify(ScreenProbe.current(for: window?.windowScene))
        if DebugArgs.has("--screen-inner") { kind = .inner }
        return DuoObservation(screen: kind,
                              window: CGSize(width: proxy.size.width + safe.leading + safe.trailing,
                                             height: proxy.size.height + safe.top + safe.bottom),
                              safe: DuoInsets(top: safe.top, left: safe.leading, bottom: safe.bottom, right: safe.trailing),
                              regions: DuoSystemAPI.regions(proxy), hinge: duoHinge).normalized()
    }

    /// 层 2: 观测进防抖; 一变就记「立即结束输入」, 稳定后记新布局。
    private func feed(_ o: DuoObservation) {
        let now = ProcessInfo.processInfo.systemUptime
        let first = stabilizer.stable == nil
        if stabilizer.observe(o, at: now) == .interruptNow { recorder.note(["event": "interruptNow"]) }
        if first { replan(event: "layout") }
        scheduleTick()
    }

    private func scheduleTick() {
        guard let d = stabilizer.deadline else { return }
        let wait = max(0, d - ProcessInfo.processInfo.systemUptime) + 0.005
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
            if stabilizer.tick(at: ProcessInfo.processInfo.systemUptime) != nil { replan(event: "layout") }
            scheduleTick()
        }
    }

    /// 预览用的页: 内置 Vibe Coding 生成的大屏键位第 1 页。
    private static let previewPage: DuoPageInfo = {
        let l = LargeLayoutGenerator.generate(from: BuiltinModes.vibe())!
        let base = l.layers[0]
        return DuoPageInfo(columns: base.columns, rowCount: base.rowCount, keys: base.keys, pageCount: l.layers.count)
    }()

    /// 层 3: 按稳定的观测重算, 并把每个区域的 frame 记进日志 (窗口坐标)。
    private func replan(event: String) {
        guard let o = stabilizer.stable else { return }
        let plan = DuoLayout.plan(o, page: Self.previewPage, swapped: previewSwapped, singleChoice: previewSingle)
        stablePlan = plan
        guard layoutPreview || event == "layout" else { return }
        var f: [String: String] = [
            "event": event, "screen": o.screen == .inner ? "inner" : "phone", "window": fmt(o.window), "hinge": o.hinge.rawValue,
            "arrangement": plan.arrangement.rawValue, "posture": plan.posture.rawValue, "divider": plan.divider.rawValue,
            "content": String(describing: plan.content), "narrow": String(plan.isNarrow), "swapped": String(previewSwapped),
            "rowsFit": String(plan.rowsFit), "subpages": plan.subpages.map { "\($0.rows.lowerBound)-\($0.rows.upperBound)\($0.isTall ? "T" : "")" }.joined(separator: ","),
            "swapAvailable": String(plan.swapAvailable),
            "usable": fmtRect(plan.usable), "topBar": fmtRect(plan.topBar), "bottomRow": fmtRect(plan.bottomRow), "dock": fmtRect(plan.dock),
            "edgeAvoid": plan.edgeAvoid.map(fmtRect).joined(), "camera": plan.camera.map(fmtRect).joined(),
            "topBarAvoid": plan.topBarAvoid.map(fmtRect).joined(),
        ]
        for (k, r) in [("dividerBand", plan.dividerBand), ("keyboard", plan.keyboard), ("pagerRow", plan.pagerRow), ("grid", plan.grid),
                       ("trackpad", plan.trackpad), ("mouseRow", plan.mouseRow)] { f[k] = r.map(fmtRect) ?? "-" }
        recorder.note(f)
    }

    /// 把各区画在窗口里 (overlay 在安全区坐标里, 所以减去安全区左、上两边)。
    private func layoutOverlay(_ p: DuoLayoutPlan, safe: EdgeInsets) -> some View {
        let items: [(String, CGRect?, Color)] = [
            ("顶栏", p.topBar, .gray), ("底行", p.bottomRow, .gray), ("胶囊", p.dock, .purple),
            ("分界", p.dividerBand, .red), ("分页行", p.pagerRow, .orange), ("网格", p.grid, .orange),
            ("触控板", p.trackpad, .green), ("鼠标键", p.mouseRow, .teal),
        ] + p.camera.map { ("摄像头", $0, .black) } + p.edgeAvoid.map { ("边缘避让", $0, .pink) }
        return ForEach(Array(items.enumerated()), id: \.offset) { _, it in
            if let r = it.1, r.width > 0, r.height > 0 {
                Rectangle().fill(it.2.opacity(0.18))
                    .overlay(Rectangle().stroke(it.2, lineWidth: 1.5))
                    .overlay(alignment: .topLeading) { Text(verbatim: it.0).font(.caption2.bold()).foregroundStyle(it.2).padding(2) }
                    .frame(width: r.width, height: r.height)
                    .offset(x: r.minX - safe.leading, y: r.minY - safe.top)
                    .allowsHitTesting(false)
            }
        }
    }

    /// 测 Q13 用: 只有 Info.plist 打开多场景时才可能成功 (见 design/iphone-duo-v1/M0-checklist.md)。
    private func requestNewWindow() {
        sceneError = nil
        UIApplication.shared.requestSceneSessionActivation(nil, userActivity: nil, options: nil) { error in
            DispatchQueue.main.async { sceneError = error.localizedDescription }
        }
    }

    // MARK: - 格式化

    private static func name(_ c: UserInterfaceSizeClass?) -> String {
        switch c { case .compact?: return "compact"; case .regular?: return "regular"; default: return "nil" }
    }
    private static func name(_ p: ScenePhase) -> String {
        switch p { case .active: return "active"; case .inactive: return "inactive"; case .background: return "background"; @unknown default: return "unknown" }
    }
    private static func name(_ s: UIScene.ActivationState) -> String {
        switch s {
        case .foregroundActive: return "前台活跃"
        case .foregroundInactive: return "前台非活跃"
        case .background: return "后台"
        case .unattached: return "未连接"
        @unknown default: return "unknown"
        }
    }
    private static func name(_ o: UIInterfaceOrientation) -> String {
        switch o {
        case .portrait: return "portrait"
        case .portraitUpsideDown: return "upsideDown"
        case .landscapeLeft: return "landscapeLeft"
        case .landscapeRight: return "landscapeRight"
        default: return "unknown"
        }
    }
}

private func fmt(_ s: CGSize) -> String { String(format: "%.1fx%.1f", s.width, s.height) }
private func fmtRect(_ r: CGRect) -> String { String(format: "(%.1f,%.1f %.1fx%.1f)", r.minX, r.minY, r.width, r.height) }

// MARK: - 数据

struct DuoProbeHinge: Equatable {
    var status: String
    var angle: Double
}

struct DuoProbeRegion: Codable, Equatable {
    var kind: String
    var frame: String
    var margins: String
    var isActive: Bool
    var rect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
    private var x: Double, y: Double, w: Double, h: Double

    init(kind: String, frame: CGRect, margins: String, isActive: Bool) {
        self.kind = kind
        self.frame = String(format: "(%.1f,%.1f %.1fx%.1f)", frame.minX, frame.minY, frame.width, frame.height)
        self.margins = margins
        self.isActive = isActive
        (x, y, w, h) = (frame.minX, frame.minY, frame.width, frame.height)
    }
}

/// 相等 = 内容指纹(key)相同; onChange 靠它判断「值得记一条」。
struct DuoProbeSnapshot: Codable, Equatable {
    static func == (a: DuoProbeSnapshot, b: DuoProbeSnapshot) -> Bool { a.key == b.key }

    var time: String
    var event: String
    var label: String
    var sceneID: String
    var screenGuess: String
    var screenNative: String
    var screenBounds: String
    var screenScale: Double
    var screenNativeScale: Double
    var traitDisplayScale: Double
    var sceneBounds: String
    var container: String
    var safeArea: String
    var hSizeClass: String
    var vSizeClass: String
    var orientation: String
    var scenePhase: String
    var hingeStatus: String
    var hingeAngle: Double?
    var regions: [DuoProbeRegion]
    var scenes: [String]
    var supportsMultipleScenes: Bool
    var duoAPICompiled: Bool
    var keyboard: String = "无"
    var statusBarHidden: Bool = false
    var statusBarFrame: String = ""
    var backgroundTaps: Int = 0

    /// 去掉时间、事件后的内容指纹: 只有它变了才自动记一条。铰链角度取整, 免得连续开合时刷屏。
    var key: String {
        [label, sceneID, screenNative, screenBounds, sceneBounds, container, safeArea, hSizeClass, vSizeClass,
         orientation, scenePhase, hingeStatus, hingeAngle.map { String(Int($0.rounded())) } ?? "-",
         regions.map { "\($0.kind)\($0.frame)\($0.isActive)" }.joined(), scenes.joined(),
         keyboard, String(statusBarHidden), statusBarFrame, String(backgroundTaps)].joined(separator: "|")
    }

    var jsonLine: String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? enc.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

@MainActor
final class DuoProbeRecorder: ObservableObject {
    @Published private(set) var entries: [DuoProbeSnapshot] = []

    private static let fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("duoprobe-log.jsonl")
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    func record(_ snap: DuoProbeSnapshot, event: String) {
        var s = snap
        s.time = Self.iso.string(from: Date())
        s.event = event
        entries.append(s)
        if entries.count > 300 { entries.removeFirst(entries.count - 300) }
        let line = s.jsonLine
        print("DUOPROBE \(line)")
        Self.append(line + "\n")
    }

    /// 记一条自由格式的事件 (M3a 布局预览: 各区 frame、interruptNow)。
    func note(_ fields: [String: String]) {
        var f = fields
        f["time"] = Self.iso.string(from: Date())
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let line = (try? enc.encode(f)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        print("DUOPROBE \(line)")
        Self.append(line + "\n")
    }

    func clear() {
        entries.removeAll()
        try? FileManager.default.removeItem(at: Self.fileURL)
    }

    private static func append(_ text: String) {
        let data = Data(text.utf8)
        if let h = try? FileHandle(forWritingTo: fileURL) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }
    }
}

/// 拿到 SwiftUI 视图所在的 UIWindow (进而拿到 windowScene / screen)。
private struct DuoProbeWindowReader: UIViewRepresentable {
    let onChange: (UIWindow?) -> Void

    func makeUIView(context: Context) -> ReaderView {
        let v = ReaderView()
        v.onChange = onChange
        return v
    }

    func updateUIView(_ v: ReaderView, context: Context) { v.onChange = onChange }

    final class ReaderView: UIView {
        var onChange: ((UIWindow?) -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            let w = window
            DispatchQueue.main.async { [weak self] in self?.onChange?(w) }
        }
    }
}
#endif
