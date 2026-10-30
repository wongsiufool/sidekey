import SwiftUI

/// UI 测试时用一份干净的 UserDefaults (不碰用户真实数据), 正常运行用 .standard。
enum AppDefaults {
    static func resolve() -> UserDefaults {
        guard DebugArgs.has("--uitest") else { return .standard }
        let name = "sidekey.uitest"
        let d = UserDefaults(suiteName: name) ?? .standard
        d.removePersistentDomain(forName: name)
        return d
    }
}

struct ContentView: View {
    // App 级共享状态 (AppEnvironment, 所有窗口共用) —— §7 状态拆分
    @StateObject private var client = AppEnvironment.shared.client
    @StateObject private var store = AppEnvironment.shared.store
    @StateObject private var bannerLayout = AppEnvironment.shared.bannerLayout
    @State private var credentialNoticeDismissed = false
    @State private var handledDiscardGeneration = AppEnvironment.shared.store.discardGeneration
    @StateObject private var perComputer = AppEnvironment.shared.perComputer
    @StateObject private var discovery = AppEnvironment.shared.discovery
    @StateObject private var themeManager = AppEnvironment.shared.themeManager
    private let pool = AppEnvironment.shared.connections
    // 窗口级状态: 当前电脑 / 模式 / 页 / 子页。被系统回收后用 @SceneStorage 还原。
    @StateObject private var window = WindowState(defaultsFrom: AppEnvironment.shared.store)
    @SceneStorage("window.computer") private var sceneComputer = ""
    @SceneStorage("window.mode") private var sceneMode = ""
    @SceneStorage("window.layer") private var sceneLayer = ""
    // §5.2 输入守卫 (窗口级): 鼠标键仲裁 + 布局变化时立即结束输入并冻结
    @StateObject private var inputGuard = InputGuard(
        windowID: UUID(), computerID: { AppEnvironment.shared.store.currentComputerID },
        transport: AppEnvironment.shared.client, arbiter: AppEnvironment.shared.mouseArbiter)
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.scenePhase) private var scenePhase

    /// 当前页 id (窗口级)。
    private var currentLayerID: String {
        get { window.layerID }
        nonmutating set { window.layerID = newValue }
    }
    /// 这个窗口正在用的那套键位的页: 内屏上有大屏键位就用大屏键位 (§1 两套键位), 否则用原键位。
    /// 页回退 (§5.1「目标页不存在时退回第 1 页」)、跳转键、翻页都按这套页走。
    private var layers: [KeyLayer] {
        if let l = innerLarge { return l.layers }
        return store.layers(computer: window.computerID, mode: window.modeID)
    }
    /// 内屏上这个窗口用的大屏键位 (nil = 手机屏, 或大屏键位暂时不可用 → 内屏也先用手机屏的排法)。
    private var innerLarge: LargeLayout? {
        guard screenKind == .inner else { return nil }
        return store.largeLayout(computer: window.computerID, mode: window.modeID)
    }
    private var currentComputer: Computer? { store.computer(window.computerID) }
    @State private var dragX: CGFloat = 0
    @State private var showKeyEditor = false
    /// 编辑器打开时锁定的目标: 在点击动作里算好 (可能要生成并保存大屏键位), sheet 构造时只读这个值, 不写 store。
    @State private var keyEditorTarget: LayoutTarget?
    /// 这个窗口所在的屏幕 (§3.1)。内屏: 打开模式时生成大屏键位 (§6.2), 编辑器编辑大屏键位 (§4.8)。
    /// 内屏的整套布局 (用大屏键位排键盘区 + 触控板区) 属于 M3; M2 只做数据和编辑闭环。
    @State private var screenKind: ScreenKind = .phone
    /// 本次运行里已经关掉「大屏键位读不出来」的提示。
    @State private var largeNoticeDismissed = false
    /// 「这套键位有超出范围的按键」提示 (§6.4 第 5 条): 每个模式本次运行只提示一次。
    @State private var outOfBoundsNotice = false
    @State private var outOfBoundsNoticed: Set<UUID> = []
    // M3 内屏布局 (§7 四层): 层 1 观测 → 层 2 防抖 → 层 3 DuoLayout → 这里渲染
    @State private var duoHinge: DuoHinge = .unknown
    /// 层 2 驱动 (防抖 + 守卫联动 + 离开内屏重置, M3 审计 B1 / B5)。引用类型, 窗口内只有一个。
    @State private var duoDriver = DuoLayoutDriver()
    /// 层 2 输出的稳定观测 (nil = 还没有)。
    @State private var duoStable: DuoObservation?
    /// 一键调换偏好 (§4.4): 竖屏 (上下分区)、横屏 (左右分区) 各一个, 全局保存。
    @AppStorage("sidekey.swap.portrait") private var swapPortrait = false
    @AppStorage("sidekey.swap.landscape") private var swapLandscape = false
    /// 内屏显示状态栏 (§4 开头): 默认关 = 内屏隐藏系统状态栏。外屏和普通 iPhone 不受影响。
    @AppStorage(InnerStatusBar.key) private var innerShowStatusBar = false
    /// 调换动画进行中 (§4.4: 约 250 ms; 期间不接受任何输入)。
    @State private var swapAnimating = false
    /// 「减少动态效果」时调换改成淡出 → 换位 → 淡入。
    @State private var swapFadeOut = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 内屏语音面板 (§4.8): 三种形态共用的草稿; 系统键盘在本窗口坐标里的 frame (收起 = 高 0)。
    @StateObject private var voiceDraft = VoiceDraft()
    @State private var keyboardFrame: CGRect = .zero
    /// DEBUG 验收: --fake-keyboard <高度> 模拟一块贴在窗口底部的系统键盘 (真键盘只有 264 / 351 两种高度, 用它截三档和模态语音页)。
    @State private var debugKeyboardHeight: CGFloat?
    /// 内屏上权限 / 思考强度从被按的那个键旁边弹出 (popover); 记下是哪个键。
    @State private var popoverKeyID: UUID?
    /// 权限 / 思考强度面板: 窗口级的一份状态 (M3 审计 I9), 按屏幕选容器 —— 内屏网格里有锚点时用 popover, 否则用 sheet;
    /// 浮层打开时合屏 / 展开, 面板换个容器继续显示, 不会丢。
    enum Palette: Equatable { case permission, effort }
    @State private var palette: Palette?
    /// 面板换容器的过渡期: 旧容器 (popover) 先关掉, 再呈现新容器 (sheet), 否则系统会丢掉同时发生的新呈现。
    @State private var paletteHandoff = false
    /// 面板正显示在哪种容器里 (nil = 没开)。只有「已开着、容器又变了」才交接, 刚打开不算。
    @State private var paletteShownInGrid: Bool?
    @State private var paletteHandoffToken = 0
    #if DEBUG
    @State private var testBounceCount = 0
    @State private var testBounceLog: [String] = []
    #endif
    // 笔记本键盘模式 (§4.9): 粘滞修饰键按窗口记; 「用触控板」是空间不够时的临时显示; 外屏提示卡上选了「使用触控板」
    @StateObject private var laptop = LaptopSession()
    @State private var laptopUseTrackpad = false
    @State private var laptopOuterTrackpad = false
    @State private var showDictation = false
    @State private var showConnection = false
    @State private var showModeManager = false
    @State private var showSettings = false
    @State private var showSetupGuide = false            // 首启引导: 讲清需要电脑端免费小助手
    @State private var addingMode = false
    @State private var newModeName = ""
    /// 手填首连(TOFU)学到的证书指纹: 弹一次「请核对」提示, 让首次信任不再是静默的 (审计 M-3)。
    @State private var tofuVerifyFP: String?
    @AppStorage("sidekey.agent.selected") private var selectedAgent = "claude"
    @AppStorage("sidekey.agent.auto") private var agentAuto = true
    /// Claude Code 权限模式 / Effort (用户主动选择后的本地显示状态)。持久化, 重启保留。
    /// 是否把 auto/bypass 纳入 Shift+Tab 循环 (需用户已在 Claude Code 会话启用)。默认关 = 安全的 3 档循环。
    @AppStorage("sidekey.permission.extras") private var permissionExtras = false
    /// 首启引导只对「全新用户」弹一次(展示过就记住)。
    @AppStorage("sidekey.setupGuideSeen") private var setupGuideSeen = false

    /// 权限模式 / 思考强度按「当前电脑」分开存 (§4.7); 同一台电脑的多个窗口共用一份。
    private var permissionRaw: Int { perComputer.permissionRaw(for: window.computerID) }
    private var effortRaw: Int { perComputer.effortRaw(for: window.computerID) }
    private func setPermissionRaw(_ raw: Int) { perComputer.setPermission(raw, for: window.computerID) }
    private func setEffortRaw(_ raw: Int) { perComputer.setEffort(raw, for: window.computerID) }

    private var theme: SidekeyTheme { themeManager.theme(system: systemScheme) }
    /// 当前权限模式。若存档里是需会话启用的档 (auto/bypass) 但 extras 关着, 一律按 Ask 显示/计算, 避免错位。
    private var permissionMode: PermissionMode {
        let m = PermissionMode(rawValue: permissionRaw) ?? .ask
        return (m.requiresSetup && !permissionExtras) ? .ask : m
    }
    private var effortLevel: EffortLevel { EffortLevel(rawValue: effortRaw) ?? .high }

    private var shownAgent: String {
        agentAuto ? (client.activeAgent ?? selectedAgent) : selectedAgent
    }

    var body: some View {
        GeometryReader { geo in
            // 内屏 + 大屏键位可用: 按 DuoLayout 排 (§4.2 / §4.3)。稳定的观测还没出来的头一帧仍按手机排法, 不闪空白。
            if isLaptopMode, screenKind == .inner, let obs = duoStable {
                innerLaptopBody(geo, obs: obs).onAppear { bannerLayout.portraitNonInput = nil }
            } else if isLaptopMode, screenKind == .phone, !laptopOuterTrackpad {
                laptopFoldedBody.onAppear { bannerLayout.portraitNonInput = nil }
            } else if isLaptopMode, screenKind == .phone {
                laptopPhoneTrackpadBody.onAppear { bannerLayout.portraitNonInput = nil }
            } else if let large = innerLarge, let obs = duoStable {
                innerBody(geo, large: large, obs: obs).onAppear { bannerLayout.portraitNonInput = nil }
            // 只看窗口实际形状, 不读设备方向 (§7): 宽 > 高 = 横屏 (§4.1.2)。
            // 「未保存」状态条在根视图上内缩, 这里拿到的是扣掉状态条后的内容区: 判断方向 / 要不要侧栏要加回状态条高度 (按完整窗口的形状), 布局仍用真实可用尺寸。
            } else if geo.size.width > geo.size.height + bannerLayout.rootHeight {
                landscapeBody(geo.size).onAppear { bannerLayout.portraitNonInput = nil }
            } else { portraitBody(PhoneMetrics.portrait(width: geo.size.width), contentHeight: geo.size.height) }
        }
        .background(GeometryReader { geo in
            // 层 1: 观测 (只在内屏采集; 手机屏沿用 M1 的排法)
            let obs = duoObservation(geo)
            Color.clear
                .onAppear { feedDuo(obs) }
                .onChange(of: obs) { feedDuo($0) }
        })
        // 内屏的键盘避让由语音面板按「和本窗口的重叠」自己算 (§4.8), 容器尺寸里不能再扣一次键盘高度
        .ignoresSafeArea(.keyboard)
        .background(KeyboardFrameReader { keyboardFrame = $0 })
        .duoHinge($duoHinge)
        .statusBarHidden(screenKind == .inner && !innerShowStatusBar)
        .modifier(WindowChrome(self))
    }

    private func portraitBody(_ m: PhoneMetrics, contentHeight: CGFloat) -> some View {
        ZStack {
            theme.bgGradient.ignoresSafeArea()
            VStack(spacing: m.blockSpacing) {
                topBar
                if client.status == .connected && !client.serverAXAuthorized {
                    axBanner
                }
                failureBanner
                if let fp = tofuVerifyFP { tofuBanner(fp) }
                if layers.count > 1 { layerIndicator }
                pager
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .allowsHitTesting(!inputGuard.frozen)      // §5.2 第 4 步: 布局变化后冻结输入, 稳定 150 ms 才恢复
                    .background(GeometryReader { g in
                        Color.clear
                            .onAppear { publishPortraitBudget(pager: g.size.height, content: contentHeight) }
                            .onChange(of: g.size.height) { publishPortraitBudget(pager: $0, content: contentHeight) }
                            .onChange(of: contentHeight) { publishPortraitBudget(pager: g.size.height, content: $0) }
                    })
                dock
            }
            .padding(.horizontal, m.hPadding)
            .padding(.top, m.topPadding)
            .padding(.bottom, m.bottomPadding)
        }
    }
}

/// 窗口级的公共修饰 (主题、输入守卫、各弹窗、状态同步等)。竖屏和横屏两套主体共用, 避免各写一遍。
private struct WindowChrome: ViewModifier {
    let v: ContentView
    init(_ v: ContentView) { self.v = v }
    func body(content: Content) -> some View { v.chrome(content) }
}
/// 笔记本键盘和调换相关的状态联动 (拆出来让编译器类型检查不至于太慢)。
private struct LaptopHooks: ViewModifier {
    let v: ContentView
    func body(content: Content) -> some View { v.laptopHooks(content) }
}

private struct ChromeMiddle: ViewModifier {
    let v: ContentView
    func body(content: Content) -> some View { v.chromeMiddle(content) }
}

private struct ChromeSheets: ViewModifier {
    let v: ContentView
    func body(content: Content) -> some View { v.chromeSheets(content) }
}

/// chrome 的后半段 (提示框等), 拆开是为了让编译器类型检查不至于太慢。
private struct ChromeTail: ViewModifier {
    let v: ContentView
    func body(content: Content) -> some View { v.chromeTail(content) }
}

extension ContentView {
    fileprivate func chrome(_ content: some View) -> some View {
        content
        .environment(\.sidekeyTheme, theme)
        .environment(\.inputGuard, inputGuard)
        .overlay(alignment: .top) {
            if inputGuard.needsRetap {
                Text("输入已暂停，请抬手后重新点按")
                    .font(.footnote.weight(.semibold)).foregroundColor(theme.onWarning)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Capsule().fill(theme.warning))
                    .padding(.top, 8).allowsHitTesting(false)
            }
        }
        .background(ScreenKindReader { screenKind = $0 })
        #if DEBUG
        // UI 测试 (`--test-screen-toggle`): 一个注入换屏的按钮, 用实际呈现验证跨屏交接 (模拟器的开合没法自动化)
        .overlay(alignment: .bottom) {
            if DebugArgs.has("--test-screen-toggle") {
                Button { screenKind = screenKind == .inner ? .phone : .inner } label: {
                    Text(verbatim: screenKind == .inner ? "→手机屏" : "→内屏").font(.system(size: 11)).frame(width: 64, height: 44)
                        .background(Color.yellow.opacity(0.6))
                }
                .accessibilityIdentifier("testToggleScreen")
                .padding(.bottom, 2)
            }
        }
        // `--test-screen-bounce`: 语音打开 8 秒后开始, 每 2.5 秒自动换一次屏, 共 40 次 (往返 20 次, R-B1 验收)。
        // 每次换屏 2 秒后记下当前容器里输入框的实际状态 (哪个框 / 文字 / 选区 / 是否第一响应者); 结束后整段写到 testBounce,
        // UI 测试逐次断言 (键盘弹着时 XCUI 每次查询都要拍整棵树, 逐次在测试里查会漏拍)
        .overlay(alignment: .top) {
            if DebugArgs.has("--test-screen-bounce") {
                Text(verbatim: testBounceLog.count == 40 ? "done;" + testBounceLog.joined(separator: ";") : "\(testBounceCount)")
                    .font(.system(size: 6)).frame(width: 60, height: 14).background(Color.yellow.opacity(0.6))
                    .accessibilityIdentifier("testBounce").allowsHitTesting(false)
            }
        }
        .onChange(of: showDictation) { on in
            guard on, testBounceCount == 0, DebugArgs.has("--test-screen-bounce") else { return }
            func probe() -> String {
                func walk(_ v: UIView) -> [UITextView] { (v as? UITextView).map { [$0] } ?? v.subviews.flatMap(walk) }
                let id = usesInnerPresentation ? "voiceText" : "phoneVoiceText"
                let views = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).flatMap(walk)
                guard let v = views.first(where: { $0.accessibilityIdentifier == id && $0.window != nil }) else { return "\(id),missing" }
                return "\(id),\(v.text ?? ""),\(v.selectedRange.location),\(v.selectedRange.length),\(v.isFirstResponder ? 1 : 0)"
            }
            func step(_ i: Int) {
                guard i <= 40 else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + (i == 1 ? 8 : 2.5)) {   // 先留 8 秒给测试输入文字、收键盘
                    screenKind = screenKind == .inner ? .phone : .inner
                    testBounceCount = i
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { testBounceLog.append(probe()) }
                    step(i + 1)
                }
            }
            step(1)
        }
        // 面板显示时点按钮会被系统当成「点外面关闭」吃掉: `--test-toggle-on-palette` 在面板打开 1 秒后自动换屏
        .onChange(of: palette) { p in
            guard p != nil, DebugArgs.has("--test-toggle-on-palette") else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { screenKind = screenKind == .inner ? .phone : .inner }
        }
        #endif
        .environment(\.screenKind, screenKind)
        .onChange(of: screenKind) { _ in ensureLargeIfInner(); followStoreSelection() }   // 跨屏: 两套键位的页可能不一样 (§5.1)
        .onChange(of: window.modeID) { _ in ensureLargeIfInner() }
        .onChange(of: window.computerID) { _ in ensureLargeIfInner() }
        .background(TouchTracker(onCount: { inputGuard.touchCountChanged($0) }, onLost: { inputGuard.touchTrackingLost() }, onResync: { inputGuard.touchesResynced($0) }))   // 数手指: 解冻要等所有手指离开屏幕
        .background(GeometryReader { g in                       // 窗口尺寸变化 (旋转、缩放、Split View) → 结束输入
            Color.clear.onChange(of: g.size) { _ in DebugTimeline.record("size change \(g.size)"); inputGuard.interrupt() }
        })
        .preferredColorScheme(themeManager.preferredColorScheme)
        .onAppear {
            inputGuard.bind(windowID: window.id, computerID: { window.computerID })
            #if DEBUG
            ContentViewTestHooks.current = self
            #endif
            if !DebugArgs.has("--uitest") { restoreWindowState() }
            client.statusDeep = themeManager.statusDeep; maybeAutotest(); applyDebugUI(); discovery.start(); autoConnectIfNeeded(); maybeShowSetupGuide()
        }
        .onChange(of: store.computers.count) { _ in
            pruneComputerPrefsIfSaved()
            followStoreSelection()
        }
        .onChange(of: store.hasUnsavedChanges) { _ in pruneComputerPrefsIfSaved() }   // 保存成功后才清掉已删电脑的偏好 (未保存期间放弃修改电脑会回来)
        .onChange(of: store.currentComputerID) { _ in followStoreSelection() }
        .onChange(of: store.currentModeID) { _ in followStoreSelection() }
        .onChange(of: layers) { _ in inputGuard.interrupt(); followStoreSelection() }   // 键位被修改导致重排; 删除当前页时窗口回退到有效页
        .onChange(of: store.discardGeneration) { _ in inputGuard.interrupt(); _ = handleDiscardIfNeeded(); reconcileConnection() }   // 放弃修改: 各窗口的电脑 / 模式 / 页按 §5 修正
        .onChange(of: window.modeID) { _ in inputGuard.interrupt(); window.subpageRow = 0 }
        .onChange(of: window.layerID) { _ in inputGuard.interrupt(); window.subpageRow = 0 }
        .onChange(of: window.subpageRow) { _ in inputGuard.interrupt() }      // 兜底: 任何途径改了子页 / 单区都结束输入
        .onChange(of: window.singleZone) { _ in inputGuard.interrupt() }
        .modifier(LaptopHooks(v: self))
        .modifier(ChromeMiddle(v: self))
        .unsavedBanner(store, isRoot: true)
        .modifier(ChromeTail(v: self))
    }

    fileprivate var keyEditorSheet: some View {
        KeyGridEditorView(store: store, client: client,
                          target: keyEditorTarget ?? LayoutTarget(computer: window.computerID, mode: window.modeID, set: .original),
                          initialPage: currentLayerID).unsavedBanner(store)
            .environment(\.screenKind, screenKind)   // sheet 不一定继承自定义环境值: 显式传这个窗口的屏幕上下文
            .statusBarHidden(screenKind == .inner && !innerShowStatusBar)   // 全屏的大屏编辑器不继承主界面的设置, 显式跟随「内屏显示状态栏」
    }

    fileprivate var permissionPalette: some View {
            PermissionPaletteView(
                current: permissionMode,
                extras: Binding(
                    get: { permissionExtras },
                    set: { on in
                        // 关掉 extras 时, 若存档里是 auto/bypass 则回到核心档, 避免循环长度错位。
                        // 注意要测「原始存档值」, 不能测 permissionMode (它已按 extras 钳到 .ask, 测了恒为 core)。
                        let wasNonCore = !(PermissionMode(rawValue: permissionRaw) ?? .ask).isCore
                        permissionExtras = on
                        if !on, wasNonCore { setPermissionRaw(PermissionMode.ask.rawValue) }
                    }
                )
            ) { mode in
                let presses = mode.shiftTabPresses(from: permissionMode, includingExtras: permissionExtras)
                client.sendShiftTab(times: presses)           // 真实机制: Shift+Tab 循环
                setPermissionRaw(mode.rawValue)               // 持久化本地显示状态 (按电脑)
            }
    }

    fileprivate var effortPalette: some View {
            EffortPaletteView(current: effortLevel) { level in
                client.sendEffort(level)                      // 发 /effort <级别>
                setEffortRaw(level.rawValue)                  // 持久化本地显示状态 (按电脑)
            }
    }

    fileprivate func laptopHooks(_ content: some View) -> some View {
        content
        // 笔记本键盘 (§4.9): 切电脑、切模式、切到后台、断线时清空粘滞修饰键 (含锁定); 旋转、调换、开合时保留
        .onChange(of: window.computerID) { _ in laptop.clearAll() }
        .onChange(of: window.modeID) { _ in laptop.clearAll(); laptopUseTrackpad = false }
        .onChange(of: scenePhase) { p in if p == .background { laptop.clearAll() } }
        .onChange(of: client.status) { st in if st != .connected { laptop.clearAll() } }
        .onChange(of: screenKind) { k in if k == .inner { laptopOuterTrackpad = false } }      // 展开后回到笔记本键盘 (T-KB-5)
        // 排法跟电脑走: ready.platform 按电脑记住; 排法变化时按 §5.2 结束输入
        .onChange(of: client.serverPlatform) { raw in
            guard let raw, let p = LaptopPlatform(serverPlatform: raw), client.connectedComputerID == window.computerID else { return }
            if perComputer.platform(for: window.computerID) != p { inputGuard.interrupt() }
            perComputer.setPlatform(p, for: window.computerID)
        }
        // 调换偏好是全局的 (§4.4): 别的窗口点了调换, 形状相同的这个窗口也跟着换, 换之前先结束自己的输入
        .onChange(of: swapPortrait) { _ in inputGuard.interrupt() }
        .onChange(of: swapLandscape) { _ in inputGuard.interrupt() }
    }

    fileprivate func chromeMiddle(_ content: some View) -> some View {
        content
        .onChange(of: window.computerID) { id in
            inputGuard.interrupt()
            pool.select(window: window.id, computer: id, foreground: scenePhase != .background)
            saveWindowState()
        }
        .onChange(of: window.modeID) { _ in saveWindowState() }
        .onChange(of: window.layerID) { _ in saveWindowState() }
        .onChange(of: scenePhase) { phase in
            DebugTimeline.record("scenePhase \(phase)")
            if phase != .active { inputGuard.interrupt() }                              // 退后台 / 弹系统界面 (§5.2 第 1–3 步先立即执行)
            if phase == .background { store.retryUnsavedSave() }                        // 有未保存的修改: 进入后台时再试一次 (在中断输入之后)
            if phase == .active, store.unreadableTokenCount > 0 { store.retryUnreadableTokens(); reconcileConnection() }    // 设备解锁后重读读不出来的令牌
            pool.scenePhaseChanged(window: window.id, phase: phase)
        }
        .onDisappear { inputGuard.teardown(); pool.close(window: window.id) }
        .onChange(of: themeManager.statusDeep) { client.applyStatusDeep($0) }
        .onChange(of: client.learnedFingerprint) { learned in
            // TOFU: 手填连接首连学到的指纹, 固定到「发起这次握手的那台电脑」, 之后转严格 pin。
            guard let learned else { return }
            // 切换电脑的竞态保护: 学到指纹的那台必须仍是当前连接目标, 否则丢弃, 别把 A 的指纹安到 B (审计复审 #2)。
            guard learned.computerID == client.connectedComputerID else { return }
            client.adoptFingerprint(learned.fp)                              // 本会话后续重连立即受 pin 保护
            if let id = learned.computerID { store.learnFingerprint(learned.fp, for: id) }  // 持久化到这台电脑
            tofuVerifyFP = learned.fp                                        // 弹「请核对指纹」提示 (审计 M-3)
        }
        .modifier(ChromeSheets(v: self))
    }

    fileprivate func chromeSheets(_ content: some View) -> some View {
        content
        .sheet(isPresented: Binding(get: { store.recovery != nil }, set: { _ in })) {
            RecoveryView(store: store).environment(\.sidekeyTheme, theme)
        }
        .alert("不能生成大屏键位", isPresented: $outOfBoundsNotice) {
            Button("知道了", role: .cancel) { outOfBoundsNoticed.insert(window.modeID) }
        } message: {
            Text("这套键位有超出范围的按键，不能生成大屏键位。内屏暂时用原键位，原键位照常可用，这些按键不会被裁掉或挪动。")
        }
        // 大屏键位读不出来 (§6.4 第 5 条): 不挡住手机屏, 只提示一次 (可关), 处理入口在设置里
        .alert("大屏键位读不出来", isPresented: Binding(get: { store.recovery == nil && store.largeRecovery != nil && !largeNoticeDismissed },
                                                  set: { if !$0 { largeNoticeDismissed = true } })) {
            Button("知道了", role: .cancel) { largeNoticeDismissed = true }
            Button("去设置处理") { largeNoticeDismissed = true; showSettings = true }
        } message: {
            Text("电脑、模式和手机屏的键位都正常，原始数据已另外备份、没有被覆盖。可以在「设置」里导出原始数据，或丢弃后重新生成大屏键位。")
        }
        // 大屏编辑器全屏打开 (§4.8); 手机屏 / 原键位照旧 sheet
        .sheet(isPresented: Binding(get: { showKeyEditor && keyEditorTarget?.set != .large }, set: { showKeyEditor = $0 })) { keyEditorSheet }
        .fullScreenCover(isPresented: Binding(get: { showKeyEditor && keyEditorTarget?.set == .large }, set: { showKeyEditor = $0 })) { keyEditorSheet }
        // 手机屏用 sheet, 内屏用非模态面板 (按屏幕上下文选, 笔记本模式也一样, M3 审计 I1); 两边共用窗口级草稿 (B7)。
        .sheet(isPresented: phoneVoiceBinding) { DictationView(client: client, draft: voiceDraft) }
        .onChange(of: keyboardFrame) { _ in if showDictation, screenKind == .inner { inputGuard.interrupt() } }   // 重排前结束输入 (§4.8; 笔记本模式也算)
        .onChange(of: showDictation) { _ in inputGuard.interrupt() }        // 兜底: 任何途径打开 / 关闭语音面板都结束输入
        .sheet(isPresented: $showConnection) {
            ConnectionSheet(store: store, client: client, discovery: discovery).unsavedBanner(store)
        }
        .sheet(isPresented: $showSetupGuide) {
            // 首启引导:「现在扫码」→ 关引导后打开电脑列表(用户在那里扫码/添加电脑)
            SetupGuideView(onScan: {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showConnection = true }
            })
        }
        .sheet(isPresented: $showModeManager) {
            ModeManagerView(store: store) { _ in currentLayerID = "base" }.unsavedBanner(store)
                .environment(\.screenKind, screenKind)   // 笔记本键盘只在内屏的模式列表里出现
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(themeManager: themeManager, store: store, client: client, editTarget: { editorTarget() }).unsavedBanner(store)
                .environment(\.screenKind, screenKind)
                .onAppear { DebugTimeline.record("settings sheet appeared") }
        }
        .onChange(of: palette) { p in if p == nil { paletteShownInGrid = nil } }
        .onChange(of: paletteInGrid) { inGrid in
            // 容器换了 (跨屏 / 网格消失或出现): 等旧容器关掉再呈现新的, 面板不丢 (M3 审计 I9 / N-I4)
            guard palette != nil else { return }
            defer { paletteShownInGrid = inGrid }
            guard let shown = paletteShownInGrid, shown != inGrid else { return }
            // 快速往返 (手机屏 → 内屏) 时以最后一次交接为准, 前一次的计时不提前结束交接
            paletteHandoffToken &+= 1
            let t = paletteHandoffToken
            paletteHandoff = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { if paletteHandoffToken == t { paletteHandoff = false } }
        }
        .sheet(isPresented: paletteBinding(.permission, inGrid: false)) { permissionPalette.presentationDetents([.medium, .large]) }
        .sheet(isPresented: paletteBinding(.effort, inGrid: false)) { effortPalette.presentationDetents([.medium, .large]) }
    }

    fileprivate func chromeTail(_ content: some View) -> some View {
        content
        .alert("凭证暂时读不出来", isPresented: Binding(get: { store.unreadableTokenCount > 0 && !credentialNoticeDismissed }, set: { if !$0 { credentialNoticeDismissed = true } })) {
            Button("好") {}
        } message: { Text("有电脑的连接凭证暂时读不出来（设备锁定或系统暂时不可用），这些电脑暂时无法连接，已有的凭证不会被删除。解锁后会自动重试。") }
        .alert("上次有修改没能保存，已恢复到最后一次保存的内容。", isPresented: Binding(get: { store.previousSessionLostChanges }, set: { if !$0 { store.acknowledgePreviousSessionLoss() } })) {
            Button("好") {}
        }
        .alert("新建模式", isPresented: $addingMode) {
            TextField("模式名称, 如 工作", text: $newModeName).autocorrectionDisabled()
            Button("创建") {
                if let id = store.addMode(named: newModeName) { store.selectMode(id); currentLayerID = "base" }
                newModeName = ""
            }
            Button("取消", role: .cancel) { newModeName = "" }
        } message: {
            Text("新模式会带一套默认按键, 之后在 ⚙️ 设置里改。")
        }
    }

    // MARK: - 顶栏: 左上 = agent 状态灯(替代旧 logo) · 右 = 电脑药丸。设置移到底部栏。
    private var topBar: some View {
        HStack(spacing: 10) {
            if themeManager.statusLightOn {
                AgentLightBar(
                    status: client.agentStatuses[shownAgent],
                    agent: shownAgent,
                    auto: agentAuto,
                    orientation: themeManager.lightOrientation,
                    connected: client.status == .connected,
                    compact: true
                ) { sel in
                    if sel == "__auto__" { agentAuto = true }
                    else { agentAuto = false; selectedAgent = sel }
                }
            } else {
                BrandMark(size: 22)   // 状态灯关掉时退回品牌
            }
            Spacer(minLength: 6)
            computerCirclesBar
        }
    }

    // MARK: - 顶栏右上: 常用电脑圆圈(最多 3 个)+ 「…」更多。圆圈=一台电脑, 连上的那台外围绿环。
    private var computerCirclesBar: some View {
        HStack(spacing: 5) {
            ForEach(quickComputers) { computerCircle($0) }
            moreComputersButton()
        }
    }

    /// 参与右上角圆圈的电脑: 置顶的排前, 其余按序补齐, 最多 3 个 (其余进「…」完整列表)。
    private var quickComputers: [Computer] {
        let pinned = store.computers.filter { $0.isPinned }
        let rest = store.computers.filter { !$0.isPinned }
        return Array((pinned + rest).prefix(3))
    }

    /// 单个电脑圆圈: 名字首字 + 连接状态环。当前电脑: 已连=绿 / 连接中=黄 / 失败=红 / 断开=灰 描边; 非当前=细边无色。
    /// 点一下 = 切到这台电脑并对齐连接。
    private func computerCircle(_ c: Computer, hitInset: CGFloat = 0) -> some View {
        let isCurrent = c.id == window.computerID
        let ring: Color? = isCurrent ? statusColor : nil     // statusColor: 已连绿 / 连接中黄 / 失败红 / 断开灰
        return Button {
            selectComputer(c.id)
        } label: {
            Text(circleGlyph(c))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isCurrent ? theme.accentInk : theme.textSecondary)
                .frame(width: 40, height: 40)
                .background(Circle().fill(isCurrent ? theme.accentLight.opacity(0.5) : theme.surface).raisedShadow(theme))
                .overlay(Circle().strokeBorder(ring ?? theme.hairline, lineWidth: ring == nil ? 1 : 2.5))
                .overlay(alignment: .bottomTrailing) {
                    if isCurrent { ConnectionBadge(state: badgeState).offset(x: 2, y: 2) }   // 状态不只靠环色 (§4.10)
                }
                .padding(hitInset)                      // 横屏侧栏: 把命中区放大到 ≥ 44 × 44 (占布局)
                // 竖屏: 不改布局, 只把命中区向外扩 2 pt (40 → 44), 外围控件命中区下限 (§3.5)
                .contentShape(Rectangle().inset(by: hitInset == 0 ? -2 : 0))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(isCurrent ? "computerCircleCurrent" : "computerCircle")
        .accessibilityLabel(NSLocalizedString(c.name, comment: ""))
        .accessibilityValue(isCurrent ? badgeState.title : "")
    }

    private var badgeState: ConnectionBadgeState {
        switch client.status {
        case .connected: return .ok
        case .connecting: return .wait
        case .failed: return .fail
        case .disconnected: return .off
        }
    }

    /// 圆圈里显示的字: 电脑名第一个字符 (中文首字 / 英文首字母大写)。
    private func circleGlyph(_ c: Computer) -> String {
        let name = NSLocalizedString(c.name, comment: "").trimmingCharacters(in: .whitespaces)
        guard let first = name.first else { return "?" }
        return String(first).uppercased()
    }

    /// 「…」更多: 打开完整电脑列表。虚线淡圆 + 小三点, 明显轻于实体电脑圆圈, 一眼是"更多"辅助按钮。
    private func moreComputersButton(hitInset: CGFloat = 0) -> some View {
        Button { showConnection = true } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.hint)
                .frame(width: 36, height: 36)
                .background(Circle().fill(theme.surface.opacity(0.5)))
                .overlay(Circle().strokeBorder(theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [3, 2.5])))
                .padding(hitInset)
                .contentShape(Rectangle().inset(by: hitInset == 0 ? -4 : 0))      // 36 → 44
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("moreComputers")
        .accessibilityLabel(String(localized: "更多电脑"))
    }

    /// 切换电脑后按「当前电脑」对齐连接 (与 ConnectionSheet.reconcileConnection 同逻辑: client.connect 幂等)。
    private func reconcileConnection() {
        pool.select(window: window.id, computer: window.computerID, foreground: scenePhase != .background)
        guard let c = currentComputer, !c.host.isEmpty else { client.disconnect(); return }
        store.retryUnreadableTokens()
        if store.isTokenUnknown(c.id) { client.disconnect(); return }      // 令牌暂时读不出来: 不按「没有令牌」去连接 (顶部提示, 解锁后自动重试)
        client.connect(to: store.computer(c.id) ?? c)
    }

    /// 多页指示: 2 页 = 主键盘/导航 自绘分段; >2 页 = 圆点。
    @ViewBuilder private var layerIndicator: some View {
        let ls = layers
        if ls.count == 2 {
            SoftSegmentedControl(
                items: [(title: String(localized: "主页 · 输入"), tag: ls[0].id), (title: String(localized: "第 2 页 · 快捷"), tag: ls[1].id)],
                selection: Binding(
                    get: { ls.contains { $0.id == currentLayerID } ? currentLayerID : ls[0].id },
                    set: { id in withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) { currentLayerID = id } }
                )
            )
        } else {
            HStack(spacing: 6) {
                ForEach(ls.indices, id: \.self) { i in
                    let on = ls[i].id == currentLayerID
                    Capsule()
                        .fill(on ? theme.accent : theme.textTertiary.opacity(0.4))
                        .frame(width: on ? 18 : 6, height: 6)
                        .animation(.easeInOut(duration: 0.2), value: currentLayerID)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - 底部 dock: 左=模式(选择/管理) · 中=语音 · 右=设置(外观+按键编辑)
    private var dock: some View {
        HStack {
            dockButton(icon: "square.stack.3d.up", label: String(localized: "模式"), id: "modeButton") { showModeManager = true }
            Spacer()
            Button { openVoice() } label: {
                Image(systemName: "mic.fill")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(theme.accentText)
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(theme.accent))
                    .shadow(color: theme.accent.opacity(0.34), radius: 14, x: 0, y: 6)
                    .shadow(color: theme.accent.opacity(0.18), radius: 3, x: 0, y: 1)
            }
            .accessibilityIdentifier("dockMic")
            Spacer()
            dockButton(icon: "gearshape", label: String(localized: "设置"), id: "settingsButton") { DebugTimeline.record("settingsButton action (dock)"); showSettings = true }
        }
        .padding(.horizontal, 28)
        .frame(height: 72)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous).fill(theme.surface).raisedShadow(theme)
        )
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(theme.hairline, lineWidth: 1))
    }

    private func dockButton(icon: String, label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 19, weight: .medium))
                Text(label).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(theme.textSecondary)
            .frame(minWidth: 56)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    private var statusColor: Color {
        switch client.status {
        case .connected:    return theme.success
        case .connecting:   return theme.warning
        case .failed:       return theme.danger
        case .disconnected: return theme.textTertiary
        }
    }

    /// 已连接但 Mac 没授权辅助功能 → 阻断式提示 + 重新检测 (审计【阻断】#2)。
    private var axBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("电脑未授权「辅助功能」,按键不会生效", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.warningText)
            Text("Mac 上到「系统设置 → 隐私与安全性 → 辅助功能」把 Sidekey 助手打开, 再点重新检测。")
                .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
            Button("重新检测") {
                // 强制重连一次, 重走握手拿最新 AX 能力 (连接协调器幂等, 不 force 会因「配置没变」而不重连)。
                if let c = currentComputer, !c.host.isEmpty { client.connect(to: c, force: true) } else { client.connect() }
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(theme.onWarning)
            .padding(.horizontal, 16).frame(minHeight: 44)          // 外围控件命中区 ≥ 44 (§3.5)
            .background(Capsule().fill(theme.warning))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: theme.radiusCard, style: .continuous).fill(theme.warning.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: theme.radiusCard, style: .continuous).strokeBorder(theme.warning.opacity(0.4), lineWidth: 1))
    }

    /// 连接失败时的主屏 banner (审计 H-3): 把具体原因和可操作的「重试 / 重新扫码配对」摆到用户眼前,
    /// 而不是让「按键没反应」变成一个静默失败。令牌/证书类以「重新扫码配对」为主操作。
    @ViewBuilder private var failureBanner: some View {
        if case .failed(let kind) = client.status {
            VStack(alignment: .leading, spacing: 8) {
                Label(kind.shortTitle, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.dangerText)
                Text(kind.detail)
                    .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                HStack(spacing: 10) {
                    if kind.needsRepair {
                        bannerButton(String(localized: "重新扫码配对"), filled: true) { showConnection = true }
                        bannerButton(String(localized: "重试"), filled: false) { retryConnection() }
                    } else {
                        bannerButton(String(localized: "重试"), filled: true) { retryConnection() }
                        bannerButton(String(localized: "电脑列表"), filled: false) { showConnection = true }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: theme.radiusCard, style: .continuous).fill(theme.danger.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: theme.radiusCard, style: .continuous)
                .strokeBorder(theme.danger.opacity(0.35), lineWidth: 1))
        }
    }

    private func bannerButton(_ title: String, filled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 14, weight: .semibold))
                .foregroundStyle(filled ? theme.accentText : theme.accentInk)
                .padding(.horizontal, 18).frame(height: 40)
                .background(Capsule().fill(filled ? theme.accent : theme.surface))
                .overlay(Capsule().strokeBorder(filled ? Color.clear : theme.accent.opacity(0.5), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func retryConnection() {
        if let c = currentComputer, !c.host.isEmpty { client.connect(to: c, force: true) }
        else { client.connect() }
    }

    /// 手填首连(TOFU)后弹一次「请核对证书指纹」(审计 M-3): 把「首次信任并记住」从静默变成可核对,
    /// 让用户对比前 16 位与电脑端横幅是否一致 —— 不一致即可能是局域网中间人冒充。
    private func tofuBanner(_ fp: String) -> some View {
        let pfx = String(fp.prefix(16))
        let grouped = stride(from: 0, to: pfx.count, by: 4).map { i -> String in
            let s = pfx.index(pfx.startIndex, offsetBy: i)
            let e = pfx.index(s, offsetBy: min(4, pfx.count - i))
            return String(pfx[s..<e])
        }.joined(separator: " ")
        return VStack(alignment: .leading, spacing: 8) {
            Label("首次连接 · 请核对电脑证书", systemImage: "checkmark.shield")
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.accentInk)
            Text("已记住这台电脑的证书指纹。请核对前 16 位与电脑端横幅显示的一致:")
                .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
            Text(grouped)
                .font(.system(size: 15, weight: .semibold, design: .monospaced)).foregroundStyle(theme.textPrimary)
            Text("不一致可能是被冒充 —— 请到「电脑列表」删除这台重新扫码配对。")
                .font(.system(size: 12)).foregroundStyle(theme.hint)
            HStack(spacing: 10) {
                bannerButton(String(localized: "核对无误"), filled: true) { tofuVerifyFP = nil }
                bannerButton(String(localized: "电脑列表"), filled: false) { showConnection = true }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: theme.radiusCard, style: .continuous).fill(theme.accent.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: theme.radiusCard, style: .continuous)
            .strokeBorder(theme.accent.opacity(0.35), lineWidth: 1))
    }

    // MARK: - 大屏键位 (M2)
    /// 内屏上打开 (或切到) 一个模式: 还没生成大屏键位就生成一次 (§6.2; 已有的一律不覆盖)。
    private func ensureLargeIfInner() {
        guard screenKind == .inner else { return }
        if store.ensureLarge(computer: window.computerID, mode: window.modeID) == nil,
           store.largeUnavailableReason(computer: window.computerID, mode: window.modeID) == .outOfBounds,
           !outOfBoundsNoticed.contains(window.modeID) {
            outOfBoundsNotice = true                          // 原键位有超出范围的旧数据: 不生成, 提示一次 (这个模式本次运行只提示一次)
        }
    }

    /// 面板放在哪: 内屏网格还在 (有锚点) → popover; 否则 (手机屏、笔记本模式) → sheet。
    /// 按实际锚点选容器 (M3 审计 N-I4): 内屏网格真的在画、并且触发面板的那个键就在当前显示的键里, 才用 popover;
    /// 网格因为回退消失 (单区触控板、窗口太小、语音面板让位等) 时改用 sheet, 面板不丢。
    fileprivate var paletteInGrid: Bool {
        guard let id = popoverKeyID, let keys = innerGridKeys() else { return false }
        return keys.contains { $0.id == id }
    }

    /// 内屏这一刻实际采用的是大屏 / 笔记本呈现 (而不是「内屏但暂用原键位」的手机排法, M3 审计 N-I1)。
    fileprivate var usesInnerPresentation: Bool {
        screenKind == .inner && duoStable != nil && (isLaptopMode || innerLarge != nil)
    }

    /// 内屏网格这一刻实际显示的键 (nil = 网格没在画)。和 innerBody 用同一套计算。
    fileprivate func innerGridKeys() -> [KeyCap]? {
        guard usesInnerPresentation, !isLaptopMode, let large = innerLarge, let obs = duoStable else { return nil }
        let pages = large.layers
        guard let page = pages.first(where: { $0.id == currentLayerID }) ?? pages.first else { return nil }
        let info = DuoPageInfo(columns: page.columns, rowCount: page.rowCount, keys: page.keys, pageCount: pages.count)
        let arr = DuoLayout.plan(obs, page: info, swapped: false).arrangement
        let plan = DuoLayout.plan(obs, page: info, swapped: swapped(for: arr), singleChoice: window.singleZone)
        guard let g = plan.grid else { return nil }
        let vk = showDictation ? DuoVoiceKeyboardPlan.plan(base: plan, keyboard: innerKeyboardFrame(obs), window: obs.window) : nil
        if vk != nil, plan.arrangement == .stacked { return nil }
        let subIdx = SubpageSplitter.subpageIndex(containingRow: window.subpageRow, in: plan.subpages)
        // 和 innerGrid 渲染同一个过滤: 被语音面板挡住的行不算 (R-I1)
        return InnerGridShown.compute(pageKeys: page.keys, rowCount: page.rowCount, subpages: plan.subpages, subIdx: subIdx,
                                      height: g.height, visibleHeight: vk?.panel.map { $0.minY - SubpageSplitter.rowGap - g.minY }).shown
    }

    /// 内屏用的系统键盘 frame (DEBUG 可用 debugKeyboardHeight 模拟)。渲染和面板判断共用。
    fileprivate func innerKeyboardFrame(_ obs: DuoObservation) -> CGRect {
        debugKeyboardHeight.map { CGRect(x: 0, y: obs.window.height - $0, width: obs.window.width, height: $0) } ?? keyboardFrame
    }

    /// 打开面板: 同步记下这一刻用的容器, 之后容器真的变了才交接 (刚打开不走交接延迟)。
    fileprivate func openPalette(_ p: Palette, key: UUID) {
        popoverKeyID = key; palette = p
        paletteShownInGrid = paletteInGrid
    }

    /// 只有「当前该用的那个容器」报告关闭, 才算用户关了面板; 换屏造成的旧容器关闭不清状态。
    fileprivate func paletteBinding(_ p: Palette, inGrid: Bool) -> Binding<Bool> {
        Binding(get: { palette == p && paletteInGrid == inGrid && !paletteHandoff },
                set: { if !$0, palette == p, paletteInGrid == inGrid { palette = nil } })
    }

    /// 跨屏时系统会关掉旧的 sheet: 只在手机屏上关闭才算「用户关了语音」, 换屏造成的关闭不清掉语音状态。
    fileprivate var phoneVoiceBinding: Binding<Bool> {
        // 按实际采用的呈现选 (M3 审计 N-I1): 内屏暂用原键位 (手机排法) 时也用 sheet
        Binding(get: { showDictation && !usesInnerPresentation },
                set: { (on: Bool) in if !on, !usesInnerPresentation { closeVoice() } })
    }

    /// 打开 / 关闭语音 (§4.8): 改变输入区域之前先同步结束输入 (M3 审计 B1)。
    fileprivate func openVoice() {
        guard !showDictation else { return }
        inputGuard.interrupt()
        voiceDraft.wantsFocus = true                 // 打开时聚焦 (之后跨屏按草稿里的焦点意图恢复)
        showDictation = true
    }
    fileprivate func closeVoice() {
        guard showDictation else { return }
        inputGuard.interrupt()
        showDictation = false
    }

    /// 打开编辑器 (点击动作里调用): 先锁定目标, 再弹 sheet。
    private func openKeyEditor() {
        keyEditorTarget = editorTarget()
        showKeyEditor = true
    }

    /// 编辑器打开时锁定的目标 (§4.8): 内屏 → 这个窗口的模式的大屏键位 (还没生成就先生成); 手机屏 → 原键位。
    /// 大屏键位生成不了 (笔记本键盘等非网格模式、存档处于恢复状态) 时退回原键位。
    /// 可能生成并保存大屏键位 (改 @Published): **只能在点击动作里调用**, 不能在 view body / sheet 构造里调。
    private func editorTarget() -> LayoutTarget {
        let c = window.computerID, m = window.modeID
        if screenKind == .inner, store.ensureLarge(computer: c, mode: m) != nil {
            return LayoutTarget(computer: c, mode: m, set: .large)
        }
        return LayoutTarget(computer: c, mode: m, set: .original)
    }

    // MARK: - 点键
    private func handle(_ cap: KeyCap) {
        if let t = cap.sendText, !t.isEmpty {
            client.sendPaste(t)
            client.sendKey(KeyCap(label: "", code: "enter"))
            return
        }
        switch cap.kind {
        case .layer:
            // 未设置目标 (目标为空, 或目标页已被删, §6.3): 不跳转
            guard let t = cap.targetLayer, layers.contains(where: { $0.id == t }) else { return }
            withAnimation { currentLayerID = t }
        case .record:
            openVoice()
        case .permission:
            // 内屏: 从被按的那个键旁边弹出小浮层 (§4.8); 手机屏照旧 sheet
            openPalette(.permission, key: cap.id)
        case .effort:
            openPalette(.effort, key: cap.id)
        case .trackpad, .mouseButton:
            break   // 触控板/鼠标键由各自的视图直接处理触摸, 不经过 onKey
        case .unknown:
            break   // 本版不认识的键 (来自更新版本的存档): 占位, 绝不发出按键 (§6.4)
        case .window:
            // 窗口快捷键: 已绑定则让电脑把该窗口切到最前; 未绑定则打开编辑器去绑定
            if let title = cap.winTitle, !title.isEmpty {
                client.focusWindow(app: cap.winApp ?? "", title: title, winId: cap.winId)
            } else {
                openKeyEditor()   // 未绑定: 打开网格编辑器, 让用户去绑定这个窗口键
            }
        case .agentSlot:
            // 状态灯: 点击按来源分流 (claude 桌面版→resume · codex→codex://threads · sdk-cli→终端窗口)
            if client.agentSessions.indices.contains(cap.slot ?? 0) {
                let s = client.agentSessions[cap.slot ?? 0]
                client.activateSession(id: s.id, source: s.source, project: s.project)
            }
        case .normal:
            guard !cap.code.isEmpty || !cap.mods.isEmpty else { return }  // 纯视觉/配置键: 不发送
            client.sendKey(cap)
        }
    }

    /// 跟手翻页器。触控板页不挂翻页手势 (让触控板独占触摸; 翻页改用顶部分段控件)。
    /// 竖屏的一页: 按这一页实际需要的高度 (行数 × 40 + 行距) 判断 —— 放得下就整页铺满 (和原来一样);
    /// 放不下就按 §3.6 切成子页, 只显示当前子页 (超高子页压行高, 28 pt 下限), 右侧上下切换; 连一行都放不下就显示「窗口太小」占位。
    /// 保证当前子页的每个键都完整可见、可点 (能看到触控板不等于这一页能用)。
    @ViewBuilder
    private func portraitPage(_ lyr: KeyLayer, height: CGFloat, usable: Bool) -> some View {
        let rows = max(1, lyr.rowCount)
        let need = CGFloat(rows) * SubpageSplitter.minRowHeight + CGFloat(rows - 1) * SubpageSplitter.rowGap
        let fit = SubpageSplitter.rowsThatFit(height: height)
        if height <= 0 || height >= need {
            KeyboardView(layer: lyr, connected: usable,
                         permissionMode: permissionMode, effortLevel: effortLevel,
                         agentSessions: client.agentSessions,
                         client: client, onKey: handle, pageIDs: Set(layers.map(\.id)))
        } else if fit < 1 && SubpageSplitter.tallRowHeight(rows: 1, availableHeight: height).scrolls {
            Text("窗口太小，放不下这一页的按键。请加大窗口。")
                .font(.system(size: 13)).foregroundStyle(theme.hint).multilineTextAlignment(.center)
                .padding(8).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let subs = SubpageSplitter.split(keys: lyr.keys, totalRows: lyr.rowCount, maxRows: max(1, fit))
            let si = lyr.id == currentLayerID ? SubpageSplitter.subpageIndex(containingRow: window.subpageRow, in: subs) : 0
            let sp = subs.indices.contains(si) ? subs[si] : subs[0]
            let subKeys = SubpageSplitter.keys(in: sp, from: lyr.keys)
            // 子页里只有触控板 (可伸缩的触摸面): 直接铺满可用高度 (只要 ≥ 80), 不按 28 pt 行高下限去滚动 —— 触控板整块可见可用
            let onlyTrackpad = !subKeys.isEmpty && subKeys.allSatisfy { $0.kind == .trackpad } && height >= PhoneLandscape.minTrackpadHeight
            let tall: (rowHeight: CGFloat, scrolls: Bool)? = onlyTrackpad
                ? ((height - SubpageSplitter.rowGap * CGFloat(max(0, sp.rows.count - 1))) / CGFloat(max(1, sp.rows.count)), false)
                : ((sp.isTall || fit < 1) ? SubpageSplitter.tallRowHeight(rows: sp.rows.count, availableHeight: height) : nil)
            HStack(spacing: 6) {
                subpageAnchorReporter(subs, layerID: lyr.id).frame(width: 0)            // 手机竖屏也更新首行锚点 (N-I2)
                KeyboardView(layer: KeyLayer(id: lyr.id, columns: lyr.columns, keys: subKeys),
                             connected: usable, permissionMode: permissionMode, effortLevel: effortLevel,
                             agentSessions: client.agentSessions, client: client, onKey: handle, pageIDs: Set(layers.map(\.id)),
                             rowHeightOverride: tall?.rowHeight ?? SubpageSplitter.minRowHeight, scrollsContent: tall?.scrolls ?? false)
                if subs.count > 1 {
                    VStack(spacing: 0) {
                        Button { if si > 0 { setSubpageRow(subs[si - 1].rows.lowerBound) } } label: {
                            Image(systemName: "chevron.up").font(.system(size: 15, weight: .semibold))
                                .frame(width: 44, height: 44).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).disabled(si == 0)
                        Text("\(si + 1)/\(subs.count)").font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textSecondary)
                        Button { if si + 1 < subs.count { setSubpageRow(subs[si + 1].rows.lowerBound) } } label: {
                            Image(systemName: "chevron.down").font(.system(size: 15, weight: .semibold))
                                .frame(width: 44, height: 44).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).disabled(si + 1 >= subs.count)
                    }
                    .foregroundStyle(theme.textPrimary)
                    .frame(width: 44)
                    .accessibilityIdentifier("portraitSubpageNav")
                }
            }
        }
    }

    private var pager: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            let pages = layers
            let idx = max(0, pages.firstIndex { $0.id == currentLayerID } ?? 0)
            // 含触控板或鼠标键的页面: 不挂左右滑翻页, 让这些手势(移动/按住)独占触摸; 翻页用顶部分段。
            let onTrackpad = pages.indices.contains(idx)
                && pages[idx].keys.contains { $0.kind == .trackpad || $0.kind == .mouseButton }
            // 「可发键」= 已连接 且 电脑端辅助功能已授权。没授权时按键/触控板必无效, 直接禁用防呆
            // (切层键在 KeyboardView 内单独放行, 离线/未授权也能翻页) —— 修审计 M-4。
            let usable = (client.status == .connected && client.serverAXAuthorized) || DebugArgs.has("--assume-connected")
            let stack = HStack(spacing: 0) {
                ForEach(pages) { lyr in
                    portraitPage(lyr, height: geo.size.height, usable: usable)
                        .frame(width: w)
                }
            }
            .frame(width: w, alignment: .leading)
            .offset(x: -CGFloat(idx) * w + dragX)
            .contentShape(Rectangle())

            Group {
                if onTrackpad {
                    stack
                } else {
                    stack.simultaneousGesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { v in
                                let tx = v.translation.width
                                guard abs(tx) >= 2 else { dragX = 0; return }
                                let atEdge = (idx == 0 && tx > 0) || (idx == pages.count - 1 && tx < 0)
                                dragX = atEdge ? tx * 0.32 : tx
                            }
                            .onEnded { v in
                                let tx = v.translation.width
                                let predicted = v.predictedEndTranslation.width
                                var target = idx
                                if (tx < -w * 0.22 || predicted < -w * 0.5), idx < pages.count - 1 { target += 1 }
                                else if (tx > w * 0.22 || predicted > w * 0.5), idx > 0 { target -= 1 }
                                withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                                    dragX = 0
                                    currentLayerID = pages[target].id
                                }
                            }
                    )
                }
            }
            .id(window.modeID)
        }
    }

    private func autoConnectIfNeeded() {
        let args = DebugArgs.all   // Release 恒空 → 正式包永远走自动连接(测试参数仅 DEBUG 生效)
        guard !args.contains("--autotest"), !args.contains("--autodiscover") else { return }
        pool.select(window: window.id, computer: window.computerID, foreground: scenePhase != .background)   // 连接由连接池按生命周期规则发起
    }

    // MARK: - 窗口级状态: 选择 / 恢复 / 与 App 级的同步
    /// 在本窗口切换电脑: 同时记为「最近使用」, 连接由连接池按引用规则处理。
    private func selectComputer(_ id: UUID) {
        inputGuard.interrupt()          // 先结束输入、松开按住的鼠标键, 再切电脑 (残留的按住 / 连发 / 待发位移不能发到新电脑)
        guard store.selectComputer(id) else { return }      // 电脑已不存在才会失败
        window.computerID = id
        window.modeID = store.computer(id)?.lastModeID ?? store.computer(id)?.modes.first?.id ?? window.modeID
        reconcileConnection()
    }

    /// 被系统回收后恢复: 按 SceneStorage 还原, 目标已删除时回退 (§4.7)。
    private func restoreWindowState() {
        let r = WindowState.resolve(computerRaw: sceneComputer, modeRaw: sceneMode, layerRaw: sceneLayer,
                                    computers: store.computers, recentComputerID: store.currentComputerID,
                                    recentModeID: store.currentModeID)
        window.apply(r)
        // 「最近使用」只是新窗口的默认值。
        if r.computerID != store.currentComputerID { _ = store.selectComputer(r.computerID) }
        if r.modeID != store.currentModeID { _ = store.selectMode(r.modeID) }
    }

    private func saveWindowState() {
        sceneComputer = window.computerID.uuidString
        sceneMode = window.modeID.uuidString
        sceneLayer = window.layerID
    }

    /// 放弃修改 (`discardGeneration` 变了) 只处理一次: 先于普通的 `followStoreSelection` 修正窗口。
    private func handleDiscardIfNeeded() -> Bool {
        guard store.discardGeneration != handledDiscardGeneration else { return false }
        handledDiscardGeneration = store.discardGeneration
        fixWindowAfterDiscard()
        return true
    }

    /// 放弃修改后: 只在窗口当前的电脑 / 模式 / 页**找不到**时才退回 (§5), 仍然有效的选择保留; 打开着的编辑器、弹窗在各自视图里响应 `discardGeneration` 关闭。
    private func fixWindowAfterDiscard() {
        let r = WindowState.resolve(computerRaw: window.computerID.uuidString, modeRaw: window.modeID.uuidString,
                                    layerRaw: window.layerID, computers: store.computers,
                                    recentComputerID: store.currentComputerID, recentModeID: store.currentModeID)
        window.apply(r)
        if r.computerID != store.currentComputerID { _ = store.selectComputer(r.computerID) }
        if r.modeID != store.currentModeID { _ = store.selectMode(r.modeID) }
    }

    /// 按电脑存的偏好 (权限 / 思考强度) 的清理要等存档里确实没有这台电脑: 有未保存修改时不动。
    private func pruneComputerPrefsIfSaved() {
        guard !store.hasUnsavedChanges else { return }
        perComputer.prune(keeping: store.computers.map(\.id))
    }

    /// 窗口当前的电脑 / 模式 / 页被删除时回退; M1 只有一个窗口, 外部 (连接页、模式管理) 改了选择时窗口跟随。
    private func followStoreSelection() {
        if handleDiscardIfNeeded() { return }          // 放弃修改的那一批变化: 统一在一个事务里修正, 不让普通跟随先把有效的窗口选择切走
        let r = WindowState.resolve(computerRaw: store.currentComputerID.uuidString, modeRaw: store.currentModeID.uuidString,
                                    layerRaw: window.layerID, computers: store.computers,
                                    recentComputerID: store.currentComputerID, recentModeID: store.currentModeID)
        var r2 = r
        // 内屏用大屏键位 (§1 两套键位): 页按这个窗口正在用的那套校验 (resolve 只认识原键位的页)。
        // 目标页在这套里不存在时退回第 1 页 (§5.1); 跨屏切换 (内屏 ↔ 手机屏) 时同理。
        if r.computerID == window.computerID, r.modeID == window.modeID {
            let ids = layers.map(\.id)
            r2.layerID = ids.contains(window.layerID) ? window.layerID : (ids.first ?? r.layerID)
        }
        // 完整应用解析结果 (含回退后的有效页): 电脑 / 模式没变但页被删时也要回退到第 1 页
        guard r2 != WindowState.Resolved(computerID: window.computerID, modeID: window.modeID, layerID: window.layerID) else { return }
        window.apply(r2)
    }

    /// 全新用户(还没配过任何电脑)首启弹一次引导, 讲清需要电脑端免费小助手; 老用户不打扰。
    private func maybeShowSetupGuide() {
        guard DebugArgs.all.isEmpty, !setupGuideSeen, store.recovery == nil else { return }   // 调试/UI测试态、或已展示过 → 不弹
        setupGuideSeen = true
        let configured = store.computers.contains { !$0.host.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !configured else { return }                              // 已配过电脑的老用户不打扰
        // 等欢迎页(展示 1.8s + 淡出 0.5s)走完再弹, 免得叠在欢迎页上。
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { showSetupGuide = true }
    }

    private func maybeAutotest() {
        guard DebugArgs.has("--autotest") else { return }
        client.host = "127.0.0.1"
        client.port = "8765"
        client.token = "sidekey-test"
        client.connect()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            client.sendKey(KeyCap(label: "Enter", code: "enter"))
            client.sendKey(KeyCap(label: "↥R⇧R", code: "", mods: ["ralt", "rshift"]))
            client.sendPaste("你好 Sidekey 语音输入")
        }
    }

    private func applyDebugUI() {
        let args = DebugArgs.all   // Release 恒空 → 下面所有 --xxx 调试钩子在正式包里全部失效
        if args.contains("--reseed") { store.reseedBuiltins(); currentLayerID = "base" }
        if args.contains("--resetcurrent") { store.resetCurrentModeLayout(); currentLayerID = "base" }
        if let i = args.firstIndex(of: "--pintest"), i + 2 < args.count {
            store.updateComputerConnection(id: store.currentComputerID, host: "127.0.0.1", port: 8765,
                                           token: args[i + 1], fingerprint: args[i + 2])
            if let c = store.currentComputer { client.connect(to: c) }
        }
        if args.contains("--t-minimal") { themeManager.style = .minimal }
        if args.contains("--t-lively") { themeManager.style = .lively }
        if args.contains("--t-apple") { themeManager.style = .apple }
        // 横屏回退验收夹具 (DEBUG): --fixture wide18 / wide20 / wide20tp / subpages / tallpage / singlezone / mixed / twopages
        // 夹具代码只在 DEBUG 编译 (Debug/Fixtures.swift), 调用处也必须编译期隔离, 否则 Release 编不过
        #if DEBUG
        if let i = args.firstIndex(of: "--fixture"), i + 1 < args.count, store.installFixture(named: args[i + 1]) != nil {
            currentLayerID = "base"
        }
        if let i = args.firstIndex(of: "--fake-keyboard"), i + 1 < args.count, let h = Double(args[i + 1]) { debugKeyboardHeight = h }
        // 笔记本键盘验收 (DEBUG): --modelaptop 切到笔记本键盘模式; --laptop-platform windows 预设「没识别出来时」用的排法
        if args.contains("--modelaptop"), let m = store.currentComputer?.modes.first(where: { $0.kind == .laptopKeyboard }) {
            store.selectMode(m.id)
        }
        if let i = args.firstIndex(of: "--laptop-platform"), i + 1 < args.count, LaptopPlatform(rawValue: args[i + 1]) != nil {
            perComputer.setPlatform(LaptopPlatform(rawValue: args[i + 1])!, for: window.computerID)
        }
        // 单区验收 (DEBUG): --zone trackpad 让单区先显示触控板
        if args.contains("--zone"), args.contains("trackpad") { window.singleZone = .trackpad }
        #endif
        // 「未保存」状态条验收 (DEBUG): 把读取上限压到 1 KB 再做一次修改, 保存必然失败 → 横幅显示; --unsaved-demo-restore 2 秒后把上限还原 (测自动重试)
        if args.contains("--unsaved-demo") {
            JSONParser.maxBytes = 1000
            _ = store.addPage()
        }
        // 删页回退验收 (DEBUG): 先切到 p2 页, 1.5 秒后删掉它, 看窗口是否回退到第 1 页
        if args.contains("--delete-p2") {
            currentLayerID = "p2"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { store.deleteLayer(id: "p2") }
        }
        // 截图 / 验收用: --mode <模式名> 选中当前电脑上的这个模式 (横屏 A / C 类验收)
        if let i = args.firstIndex(of: "--mode"), i + 1 < args.count,
           let m = store.currentComputer?.modes.first(where: { $0.name == args[i + 1] }) {
            store.selectMode(m.id); currentLayerID = "base"
        }
        if args.contains("--t-dark") { themeManager.appearance = .dark }
        if args.contains("--appearance") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { showSettings = true }
        }
        if args.contains("--permission") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { palette = .permission }
        }
        if args.contains("--setupguide") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { showSetupGuide = true }
        }
        if args.contains("--seeddemo") {
            if store.currentComputer?.modes.count == 1 {
                store.renameComputer(id: store.currentComputerID, to: "办公台式机")
                _ = store.addMode(named: "工作")
            }
            if store.computers.count == 1 {
                store.addComputer(Computer.make(name: "家里笔记本", host: "192.168.1.30", token: "demo"))
            }
            // demo: 再加一台 + 把示例电脑全部置顶, 直接演示顶栏快捷切换条
            if store.computers.count == 2 {
                store.addComputer(Computer.make(name: "客厅 Mac mini", host: "192.168.1.42", token: "demo"))
            }
            for c in store.computers where !c.isPinned { store.togglePin(c.id) }
        }
        if args.contains("--modes") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { showModeManager = true }
        }
        if args.contains("--layermore") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { currentLayerID = "more" }
        }
        if args.contains("--modework") || args.contains("--modemouse") {
            if let m = store.currentComputer?.modes.first(where: { $0.name == "鼠标模式" }) {
                store.selectMode(m.id); currentLayerID = "base"
            }
        }
        if args.contains("--autoteststore") {
            store.updateComputerConnection(id: store.currentComputerID,
                                           host: "127.0.0.1", port: 8765, token: "")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                client.sendKey(KeyCap(label: "Enter", code: "enter"))
                client.sendPaste("Sidekey store 路径 E2E")
            }
        }
        if args.contains("--settings") || args.contains("--editkey") || args.contains("--codepicker") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { openKeyEditor() }   // 等判屏结果出来 (内屏要打开大屏编辑器)
        }
        if args.contains("--dictation") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { openVoice() }
        }
        if args.contains("--connection") || args.contains("--addcomputer") || args.contains("--pairing") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { showConnection = true }
        }
        if args.contains("--autodiscover") {
            client.token = "sidekey-test"
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                if let s = discovery.servers.first {
                    client.host = s.host
                    client.port = String(s.port)
                    client.connect()
                }
            }
        }
    }
}

// MARK: - 手机屏横屏 (§4.1.2): 顶栏 / 底栏改成左右侧栏, 按键区占满中间
extension ContentView {
    // §5.2: 子页 / 单区 / 页的切换统一走「先中断、后变更」, 立即松鼠标键、停连发、丢待发位移并冻结输入。
    fileprivate func setSubpageRow(_ row: Int) {
        guard row != window.subpageRow else { return }
        inputGuard.interrupt(); window.subpageRow = row
    }
    fileprivate func setSingleZone(_ zone: SingleZone) {
        DebugTimeline.record("zoneToggle action -> \(zone) (frozen=\(inputGuard.frozen))")
        guard zone != window.singleZone else { return }
        inputGuard.interrupt(); window.singleZone = zone
    }
    fileprivate func changeLayer(_ id: String) {
        guard id != currentLayerID else { return }
        inputGuard.interrupt()
        withAnimation { currentLayerID = id; window.subpageRow = 0 }
    }

    static let landscapeVPadding: CGFloat = 8
    /// 竖屏键盘区的最低高度 (按钮行 / 触控板按 §3.5 下限; 低于它显示占位)。
    static let portraitMinPagerHeight: CGFloat = 120

    /// 竖屏: 报告键盘区高度和「外围控件」高度 (内容区高度 − 键盘区高度), 状态条据此算真实输入区预算。
    fileprivate func publishPortraitBudget(pager: CGFloat, content: CGFloat) {
        bannerLayout.portraitPagerHeight = pager
        bannerLayout.portraitNonInput = max(0, content - pager)
    }

    fileprivate func landscapeBody(_ size: CGSize) -> some View {
        let availH = max(0, size.height - 2 * Self.landscapeVPadding)
        let pages = layers
        let idx = max(0, pages.firstIndex { $0.id == currentLayerID } ?? 0)
        let layer = pages.indices.contains(idx) ? pages[idx] : (pages.first ?? DefaultLayout.makeBase())
        // 宽度先收窄侧栏 (60 → 48), 再不够才显示「窗口太窄」占位 (§3.5); 每格 ≥ 20 pt 不降
        let sideW = PhoneLandscape.sideBarWidth(containerWidth: size.width, columns: layer.columns)
        let plan = PhoneLandscape.plan(keys: layer.keys, columns: layer.columns, rowCount: layer.rowCount,
                                       availableHeight: availH, availableWidth: size.width - 2 * sideW, zone: window.singleZone)
        let subIdx = SubpageSplitter.subpageIndex(containingRow: window.subpageRow, in: plan.subpages)
        return ZStack {
            theme.bgGradient.ignoresSafeArea()
            HStack(spacing: 0) {
                landscapeLeftBar(pages: pages, plan: plan, subIdx: subIdx)
                    .frame(width: sideW)
                ZStack(alignment: .top) {
                    landscapeContent(layer: layer, plan: plan, subIdx: subIdx, availH: availH, pageCount: pages.count, pageIdx: idx)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                        .allowsHitTesting(!inputGuard.frozen)
                        .background(subpageAnchorReporter(plan.subpages, layerID: layer.id))   // 手机横屏也更新首行锚点 (N-I2)
                    VStack(spacing: 6) {
                        if client.status == .connected && !client.serverAXAuthorized { axBanner }
                        failureBanner
                        if let fp = tofuVerifyFP { tofuBanner(fp) }
                    }
                }
                landscapeRightBar(plan: plan, sideW: sideW)
                    .frame(width: sideW)
            }
            .padding(.vertical, Self.landscapeVPadding)
        }
    }

    // MARK: 中间: 按键区
    @ViewBuilder
    private func landscapeContent(layer: KeyLayer, plan: PhoneLandscapePlan, subIdx: Int, availH: CGFloat,
                                  pageCount: Int, pageIdx: Int) -> some View {
        let usable = (client.status == .connected && client.serverAXAuthorized) || DebugArgs.has("--assume-connected")   // 后者只在 DEBUG 生效 (验收时让键可点、发送记录可见)
        switch plan.presentation {
        case .stacked(let blocks):
            VStack(spacing: PhoneLandscape.rowGap) {
                ForEach(blocks.indices, id: \.self) { i in
                    let b = blocks[i]
                    switch b.kind {
                    case .trackpad:
                        TrackpadView(client: client, enabled: usable).frame(height: b.height)
                    case .keys(let rows):
                        landscapeKeys(layer: layer, keys: SubpageSplitter.keys(in: Subpage(rows: rows, isTall: false), from: plan.keys),
                                      rowHeight: PhoneLandscape.keyRowHeight, scrolls: false, usable: usable)
                            .frame(height: b.height)
                    }
                }
            }
        case .tooNarrow(let required, let trackpadAvailable):
            VStack(spacing: 8) {
                Image(systemName: "arrow.left.and.right").font(.system(size: 22)).foregroundStyle(theme.hint)
                Text("窗口太窄").font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.textPrimary)
                // 只有这一页真的有触控板时才提示可以切过去 (侧栏里有对应的切换入口); 否则只说换模式
                Text(trackpadAvailable
                     ? "这一页的按键区至少需要 \(Int(required.rounded(.up))) pt 宽, 每格不低于 20 pt。可以切到触控板, 或换个模式。"
                     : "这一页的按键区至少需要 \(Int(required.rounded(.up))) pt 宽, 每格不低于 20 pt。请换个模式, 或加宽窗口。")
                    .font(.system(size: 13)).foregroundStyle(theme.hint).multilineTextAlignment(.center)
            }
            .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .tooSmallForTrackpad(let minW, let minH):
            VStack(spacing: 8) {
                Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 22)).foregroundStyle(theme.hint)
                Text("窗口太小").font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.textPrimary)
                Text("放不下触控板和鼠标键 (输入区至少需要 \(Int(minW)) × \(Int(minH.rounded(.up))) pt)。请切回键盘, 或加大窗口。")
                    .font(.system(size: 13)).foregroundStyle(theme.hint).multilineTextAlignment(.center)
            }
            .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .trackpadOnly:
            VStack(spacing: PhoneLandscape.rowGap) {
                TrackpadView(client: client, enabled: usable)
                HStack(spacing: PhoneLandscape.rowGap) {
                    ForEach(plan.mouseButtons) { cap in MouseKeyButton(cap: cap, client: client, enabled: usable) }
                }
                .frame(height: PhoneLandscape.mouseRowHeight)
            }
        case .grid, .keysOnly:
            if plan.subpages.indices.contains(subIdx) {
                let sp = plan.subpages[subIdx]
                let tall = sp.isTall ? SubpageSplitter.tallRowHeight(rows: sp.rows.count, availableHeight: availH) : nil
                landscapeKeys(layer: layer, keys: SubpageSplitter.keys(in: sp, from: plan.keys),
                              rowHeight: tall?.rowHeight, scrolls: tall?.scrolls ?? false, usable: usable)
                    // 滑动只是快捷方式 (§3.6): 没有触控板格子、也不是超高子页时, 上下滑翻子页; 左右滑翻真正的页 (点按入口始终都有)
                    .simultaneousGesture(landscapeSwipe(plan: plan, subIdx: subIdx, tall: sp.isTall, hasPointerKeys: (plan.presentation == .grid && plan.kind == .mixed) || layerHasMouseKeys(layer), pageCount: pageCount, pageIdx: pageIdx))
            } else {
                Color.clear
            }
        }
    }

    private func layerHasMouseKeys(_ layer: KeyLayer) -> Bool { layer.keys.contains { $0.kind == .mouseButton } }

    private func landscapeKeys(layer: KeyLayer, keys: [KeyCap], rowHeight: CGFloat?, scrolls: Bool, usable: Bool) -> some View {
        KeyboardView(layer: KeyLayer(id: layer.id, columns: layer.columns, keys: keys), connected: usable,
                     permissionMode: permissionMode, effortLevel: effortLevel,
                     agentSessions: client.agentSessions, client: client, onKey: handle, pageIDs: Set(layers.map(\.id)),
                     rowHeightOverride: rowHeight, scrollsContent: scrolls)
    }

    private func landscapeSwipe(plan: PhoneLandscapePlan, subIdx: Int, tall: Bool, hasPointerKeys: Bool,
                                pageCount: Int, pageIdx: Int) -> some Gesture {
        DragGesture(minimumDistance: 20)
            .onEnded { v in
                let dx = v.translation.width, dy = v.translation.height
                if abs(dy) >= 30, abs(dy) > abs(dx) * 1.5 {
                    // 页里有触控板格子时上下滑不翻子页, 只能点圆点; 超高子页里上下滑只滚动内容
                    guard !tall, !hasPointerKeys else { return }
                    let n = subIdx + (dy < 0 ? 1 : -1)
                    if plan.subpages.indices.contains(n) { setSubpageRow(plan.subpages[n].rows.lowerBound) }
                } else if abs(dx) >= 30, abs(dx) > abs(dy) * 1.5, !hasPointerKeys {
                    let target = pageIdx + (dx < 0 ? 1 : -1)
                    if layers.indices.contains(target) { changeLayer(layers[target].id) }
                }
            }
    }

    // MARK: 左侧栏: 状态灯、电脑圆圈 (竖着排)、页码 / 子页入口
    private func landscapeLeftBar(pages: [KeyLayer], plan: PhoneLandscapePlan, subIdx: Int) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 4) {
                if themeManager.statusLightOn {
                    AgentLightBar(status: client.agentStatuses[shownAgent], agent: shownAgent, auto: agentAuto,
                                  orientation: themeManager.lightOrientation, connected: client.status == .connected,
                                  compact: true, iconOnly: true) { sel in
                        if sel == "__auto__" { agentAuto = true } else { agentAuto = false; selectedAgent = sel }
                    }
                } else {
                    BrandMark(size: 22).frame(width: 44, height: 44)
                }
                ForEach(quickComputers) { computerCircle($0, hitInset: 2) }
                moreComputersButton(hitInset: 4)
                if pages.count > 1 {
                    ForEach(pages.indices, id: \.self) { i in
                        let on = pages[i].id == currentLayerID
                        Button {
                            changeLayer(pages[i].id)
                        } label: {
                            Capsule().fill(on ? theme.accent : theme.textTertiary.opacity(0.4))
                                .frame(width: 6, height: on ? 18 : 6)
                                .frame(width: 44, height: 44).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(String(localized: "第 \(i + 1) 页"))
                    }
                }
                subpageEntry(plan: plan, subIdx: subIdx)
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// 子页入口: ≤ 3 个子页用圆点 (每个 44 × 44 命中), 更多收成「i/n」列表。点按始终可达每个子页。
    @ViewBuilder
    private func subpageEntry(plan: PhoneLandscapePlan, subIdx: Int) -> some View {
        if plan.hasSubpageDots {
            if plan.subpages.count <= 3 {
                ForEach(plan.subpages.indices, id: \.self) { i in
                    let on = i == subIdx
                    Button { setSubpageRow(plan.subpages[i].rows.lowerBound) } label: {
                        Circle().strokeBorder(on ? theme.accentInk : theme.hint, lineWidth: 1.5)
                            .background(Circle().fill(on ? theme.accentInk : Color.clear))
                            .frame(width: 10, height: 10)
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "子页 \(i + 1)/\(plan.subpages.count)"))
                }
            } else {
                Menu {
                    ForEach(plan.subpages.indices, id: \.self) { i in
                        Button(String(localized: "子页 \(i + 1)/\(plan.subpages.count)")) { setSubpageRow(plan.subpages[i].rows.lowerBound) }
                    }
                } label: {
                    Text("\(subIdx + 1)/\(plan.subpages.count)")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.accentInk)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
            }
        }
    }

    // MARK: 右侧栏: 语音、模式、设置 (+ 单区时的「键盘 / 触控板」切换)
    private func landscapeRightBar(plan: PhoneLandscapePlan, sideW: CGFloat) -> some View {
        // 放得下就按原样 (上下留白居中); 放不下 (例如「未保存」状态条 + 最大字号把主体压矮) 就收进可滚动的一列,
        // 每个控件的命中区不缩, 都能滚到、点到 (§3.5「外围控件命中区 ≥ 44, 放不下不压缩」)。
        ViewThatFits(in: .vertical) {
            VStack(spacing: 6) {
                if plan.needsZoneToggle { zoneToggle }
                Spacer(minLength: 0)
                rightBarControls(sideW: sideW)
                Spacer(minLength: 0)
            }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 6) {
                    if plan.needsZoneToggle { zoneToggle }
                    rightBarControls(sideW: sideW)
                }
            }
        }
    }

    @ViewBuilder
    private func rightBarControls(sideW: CGFloat) -> some View {
        Button { openVoice() } label: {
            Image(systemName: "mic.fill")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(theme.accentText)
                .frame(width: min(56, sideW - 4), height: min(56, sideW - 4))      // 窄侧栏 48 时 44 × 44, 命中区不缩到 44 以下
                .background(Circle().fill(theme.accent))
                .shadow(color: theme.accent.opacity(0.34), radius: 14, x: 0, y: 6)
        }
        .accessibilityIdentifier("dockMic")
        landscapeSideButton(icon: "square.stack.3d.up", label: String(localized: "模式"), id: "modeButton", width: sideW) { DebugTimeline.record("modeButton action (sidebar)"); showModeManager = true }
        landscapeSideButton(icon: "gearshape", label: String(localized: "设置"), id: "settingsButton", width: sideW) { DebugTimeline.record("settingsButton action (sidebar)"); showSettings = true }
    }

    private func landscapeSideButton(icon: String, label: String, id: String, width: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon).font(.system(size: 18, weight: .medium))
                Text(label).font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(theme.textSecondary)
            .frame(width: width, height: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    /// 「键盘 / 触控板」切换: 一个 56 × 44 的完整按钮, 写要切去的那个区。只改显示, 不改存档。
    private var zoneToggle: some View {
        let toTrackpad = window.singleZone == .keys
        return Button {
            setSingleZone(toTrackpad ? .trackpad : .keys)
        } label: {
            VStack(spacing: 1) {
                Image(systemName: toTrackpad ? "rectangle.and.hand.point.up.left" : "keyboard").font(.system(size: 15, weight: .medium))
                Text(toTrackpad ? String(localized: "触控板") : String(localized: "键盘")).font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(theme.accentInk)
            .frame(minWidth: 44, maxWidth: 56, minHeight: 44, maxHeight: 44)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.accentLight))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("zoneToggle")
    }
}

// MARK: - 内屏 (M3): 层 1 观测 → 层 2 防抖 → 层 3 DuoLayout → 按 frame 渲染 (§4.2 / §4.3)
/// 「内屏显示状态栏」设置 (§4 开头): 默认关。设置页和主界面共用这个 key。
enum InnerStatusBar {
    static let key = "sidekey.inner.showStatusBar"
}

extension ContentView {
    /// 层 1: 这一刻的观测 (窗口坐标)。只在内屏有意义; 手机屏返回空观测 (不采集、不触发防抖)。
    fileprivate func duoObservation(_ geo: GeometryProxy) -> DuoObservation {
        guard screenKind == .inner else { return .empty }
        let safe = geo.safeAreaInsets
        return DuoObservation(screen: .inner,
                              window: CGSize(width: geo.size.width + safe.leading + safe.trailing,
                                             height: geo.size.height + safe.top + safe.bottom),
                              safe: DuoInsets(top: safe.top, left: safe.leading, bottom: safe.bottom, right: safe.trailing),
                              regions: DuoSystemAPI.regions(geo), hinge: duoHinge).normalized()
    }

    /// 层 2: 观测进防抖。影响布局的结果一变就立即结束输入 (§5.2 第 1–3 步), 稳定后才换布局。
    fileprivate func feedDuo(_ o: DuoObservation) {
        duoDriver.input = inputGuard
        if duoDriver.feed(o, at: ProcessInfo.processInfo.systemUptime) { adoptDuo() }
        scheduleDuoTick()
    }

    private func scheduleDuoTick() {
        guard let d = duoDriver.deadline else { return }
        let gen = duoDriver.generation
        let wait = max(0, d - ProcessInfo.processInfo.systemUptime) + 0.005
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
            guard gen == duoDriver.generation else { return }          // 期间离开过内屏: 这次计时作废
            if duoDriver.tick(at: ProcessInfo.processInfo.systemUptime) {
                DebugTimeline.record("duo layout adopted \(duoDriver.stable?.window ?? .zero)")
                adoptDuo()
            }
            scheduleDuoTick()
        }
    }

    /// 采用新的稳定布局: 发布给界面, 并把子页锚点更新成新布局下当前子页的首行 (M3 审计 I5)。
    private func adoptDuo() {
        duoStable = duoDriver.stable
        guard let obs = duoStable else { return }
        // 首次采用 (重新展开后) 也要更新锚点 (M3 审计 N-I2)。异步执行 (不在视图求值期间写状态), 带上有效性检查:
        // 期间又离开过内屏 (generation 变了)、或换了页, 这次重锚作废
        let gen = duoDriver.generation, layer = currentLayerID
        DispatchQueue.main.async {
            guard gen == duoDriver.generation, layer == currentLayerID, duoStable == obs else { return }
            reanchorSubpage(obs)
        }
    }

    /// 形态切换后, 子页停在包含原第一可见行的子页上 (§3.6), 然后把锚点改成这个子页的实际首行,
    /// 下一次再变化时就从实际首行出发, 不会用过期的旧锚点。
    private func reanchorSubpage(_ obs: DuoObservation) {
        guard let large = innerLarge else { return }
        let pages = large.layers
        guard let page = pages.first(where: { $0.id == currentLayerID }) ?? pages.first else { return }
        let info = DuoPageInfo(columns: page.columns, rowCount: page.rowCount, keys: page.keys, pageCount: pages.count)
        let arr = DuoLayout.plan(obs, page: info, swapped: false).arrangement
        let plan = DuoLayout.plan(obs, page: info, swapped: swapped(for: arr), singleChoice: window.singleZone)
        guard !plan.subpages.isEmpty else { return }
        let first = SubpageSplitter.reanchor(row: window.subpageRow, in: plan.subpages)
        if first != window.subpageRow { window.subpageRow = first }
    }

    /// 手机排法也把锚点更新成当前子页的实际首行 (M3 审计 N-I2): 子页切法变化时 (跨屏、旋转、窗口变化) 异步更新,
    /// 只对当前页生效, 不在视图求值期间写状态。
    fileprivate func subpageAnchorReporter(_ subs: [Subpage], layerID: String) -> some View {
        let firsts = subs.map(\.rows.lowerBound)
        func update() {
            DispatchQueue.main.async {
                guard layerID == currentLayerID, !usesInnerPresentation, !subs.isEmpty else { return }
                let first = SubpageSplitter.reanchor(row: window.subpageRow, in: subs)
                if first != window.subpageRow { window.subpageRow = first }
            }
        }
        return Color.clear.onAppear { update() }.onChange(of: firsts) { _ in update() }
    }

    /// 当前布局用哪一个调换偏好: 上下分区 = 竖屏, 左右分区 = 横屏 (按窗口形状, 不读设备方向)。
    fileprivate func swapped(for arrangement: DuoArrangement) -> Bool {
        arrangement == .stacked ? swapPortrait : swapLandscape
    }

    /// 一键调换 (§4.4): 先结束输入, 再约 250 ms 滑动换位; 系统开了「减少动态效果」时改成淡入淡出。动画期间不接受任何输入。
    fileprivate func toggleSwap(_ arrangement: DuoArrangement) {
        guard !swapAnimating else { return }
        inputGuard.interrupt()                                   // 换之前先结束输入 (§5.2)
        swapAnimating = true
        let flip = { if arrangement == .stacked { swapPortrait.toggle() } else { swapLandscape.toggle() } }
        if reduceMotion {
            withAnimation(.easeInOut(duration: Self.swapDuration / 2)) { swapFadeOut = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.swapDuration / 2) {
                flip()
                withAnimation(.easeInOut(duration: Self.swapDuration / 2)) { swapFadeOut = false }
            }
        } else {
            withAnimation(.easeInOut(duration: Self.swapDuration)) { flip() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.swapDuration) {
            swapAnimating = false
            if let obs = duoStable { reanchorSubpage(obs) }           // 调换后子页数可能变了: 更新首行锚点 (I5)
        }
    }

    /// DEBUG `--slow-swap`: 把调换动画拉长到 1.5 秒, UI 测试用来稳定地验证「动画期间整个界面不接受输入」(Release 恒 0.25)。
    static var swapDuration: TimeInterval { DebugArgs.has("--slow-swap") ? 1.5 : 0.25 }

    /// 层 3 + 渲染。所有 frame 都是窗口坐标; 本视图在安全区里, 所以放置时减去安全区的左、上两边。
    fileprivate func innerBody(_ geo: GeometryProxy, large: LargeLayout, obs: DuoObservation) -> some View {
        let pages = large.layers
        let idx = max(0, pages.firstIndex { $0.id == currentLayerID } ?? 0)
        let page = pages.indices.contains(idx) ? pages[idx] : (pages.first ?? DefaultLayout.makeBase())
        let info = DuoPageInfo(columns: page.columns, rowCount: page.rowCount, keys: page.keys, pageCount: pages.count)
        let arrangement0 = DuoLayout.plan(obs, page: info, swapped: false).arrangement
        let plan = DuoLayout.plan(obs, page: info, swapped: swapped(for: arrangement0), singleChoice: window.singleZone)
        let safe = geo.safeAreaInsets
        let subIdx = SubpageSplitter.subpageIndex(containingRow: window.subpageRow, in: plan.subpages)
        let usable = (client.status == .connected && client.serverAXAuthorized) || DebugArgs.has("--assume-connected")
        func at(_ r: CGRect) -> CGPoint { CGPoint(x: r.midX - safe.leading, y: r.midY - safe.top) }
        // 语音面板打开且系统键盘挡住输入区时 (§4.8): 面板收成紧凑条, 触控板按可见区域分三档; 上下分区时键盘区暂时让给面板和触控板
        let kbFrame = innerKeyboardFrame(obs)
        let vk = showDictation ? DuoVoiceKeyboardPlan.plan(base: plan, keyboard: kbFrame, window: obs.window) : nil
        let hideGrid = vk != nil && plan.arrangement == .stacked

        return ZStack(alignment: .topLeading) {
            theme.bgGradient.ignoresSafeArea()
            innerTopBar(plan).frame(width: plan.topBar.width, height: plan.topBar.height).position(at(plan.topBar))
            Group {
                if !hideGrid, let pr = plan.pagerRow {
                    innerPagerRow(pages: pages, plan: plan, subIdx: subIdx)
                        .frame(width: pr.width, height: pr.height).position(at(pr))
                }
                if !hideGrid, let g = plan.grid {
                    innerGrid(page: page, plan: plan, subIdx: subIdx, width: g.width, height: g.height, usable: usable,
                              // 语音紧凑条压在键盘区上时: 被面板或系统键盘挡住一部分的行不画 (命中区本来就被挡住)
                              visibleHeight: vk?.panel.map { $0.minY - SubpageSplitter.rowGap - g.minY })
                        .frame(width: g.width, height: g.height)
                        .simultaneousGesture(innerSwipe(plan: plan, subIdx: subIdx, pageCount: pages.count, pageIdx: idx))
                        .position(at(g))
                }
                if let vk {
                    if let tp = vk.trackpad {
                        TrackpadView(client: client, enabled: usable)
                            .frame(width: tp.width, height: tp.height)
                            .accessibilityElement(children: .contain).accessibilityIdentifier("innerTrackpad")
                            .position(at(tp))
                        ForEach(Array(zip(large.mouseButtons.indices, vk.mouseButtons)), id: \.0) { i, r in
                            MouseKeyButton(cap: large.mouseButtons[i], client: client, enabled: usable)
                                .frame(width: r.width, height: r.height).position(at(r))
                        }
                    } else if !vk.modal {
                        // 第三档: 触控板暂时收起, 写明收起键盘后恢复 (写在面板旁边还看得见的地方)
                        let p = vk.panel ?? plan.topBar
                        let note = plan.arrangement == .stacked
                            ? CGRect(x: p.minX, y: p.maxY + 8, width: p.width, height: 44)
                            : CGRect(x: plan.trackpad?.minX ?? p.minX, y: plan.topBar.maxY + 12, width: plan.trackpad?.width ?? p.width, height: 44)
                        Text("触控板暂时收起，收起键盘后恢复")
                            .font(.system(size: 13)).foregroundStyle(theme.hint)
                            .frame(width: note.width, height: note.height).position(at(note))
                            .accessibilityIdentifier("trackpadHiddenNote")
                    }
                } else if let tp = plan.trackpad {
                    TrackpadView(client: client, enabled: usable)
                        .frame(width: tp.width, height: tp.height)
                        .accessibilityElement(children: .contain).accessibilityIdentifier("innerTrackpad")
                        .position(at(tp))
                }
                if vk == nil, let m = plan.mouseRow {
                    HStack(spacing: 8) {
                        ForEach(large.mouseButtons) { cap in MouseKeyButton(cap: cap, client: client, enabled: usable) }
                    }
                    .frame(width: m.width, height: m.height).position(at(m))
                }
                if case .tooNarrow(let w) = plan.content, let k = plan.keyboard ?? Optional(plan.usable) {
                    innerPlaceholder(title: String(localized: "窗口太窄"),
                                     text: String(localized: "这一页的按键区至少需要 \(Int(w.rounded(.up))) pt 宽, 每格不低于 20 pt。可以切到触控板, 或换个模式。"))
                        .frame(width: k.width, height: k.height).position(at(k))
                }
                if case .tooSmall(let need) = plan.content {
                    innerPlaceholder(title: String(localized: "窗口太小"),
                                     text: window.singleZone == .keys
                                        ? String(localized: "放不下一行按键 (按键区至少需要 \(Int(need.width)) × \(Int(need.height)) pt)。可以切到触控板, 或加大窗口。")
                                        : String(localized: "放不下触控板和鼠标键 (输入区至少需要 \(Int(need.width)) × \(Int(need.height)) pt)。请切回键盘, 或加大窗口。"))
                        .frame(width: plan.usable.width, height: plan.usable.height / 2).position(at(plan.usable))
                }
            }
            .opacity(swapFadeOut ? 0 : 1)
            .allowsHitTesting(!inputGuard.frozen && !swapAnimating)   // §5.2 第 4 步: 布局变化后冻结输入; 调换动画期间也不接受输入
            innerDock(plan.arrangement).frame(width: plan.dock.width, height: plan.dock.height).position(at(plan.dock))
                .opacity(swapFadeOut && plan.arrangement == .sideBySide ? 0 : 1)   // 横向时胶囊跟着键盘动
                .opacity(vk.map { plan.dock.maxY > $0.visibleBottom } == true ? 0 : 1)   // 被系统键盘盖住时不画 (键盘圆角处会露出一角)
            if showDictation { innerVoicePanel(plan: plan, vk: vk, at: at) }
            #if DEBUG
            if let h = debugKeyboardHeight {      // --fake-keyboard: 把模拟的系统键盘画出来, 截图好认
                let r = CGRect(x: 0, y: obs.window.height - h, width: obs.window.width, height: h)
                Rectangle().fill(Color.gray.opacity(0.35))
                    .overlay(Text(verbatim: "模拟系统键盘 \(Int(h)) pt（DEBUG）").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary))
                    .frame(width: r.width, height: r.height).position(at(r)).allowsHitTesting(false)
            }
            #endif
            VStack(spacing: 6) {
                if client.status == .connected && !client.serverAXAuthorized { axBanner }
                failureBanner
                if let fp = tofuVerifyFP { tofuBanner(fp) }
            }
            .frame(width: plan.topBar.width)
            .position(x: plan.topBar.midX - safe.leading, y: plan.topBar.maxY - safe.top + 60)
        }
        .frame(width: geo.size.width, height: geo.size.height)
        .allowsHitTesting(!swapAnimating)                  // §4.4: 调换动画期间整个交互容器 (顶栏、胶囊、语音面板) 都不接受输入 (M3 审计 I6)
        .accessibilityElement(children: .contain)          // 只标容器, 不覆盖里面各区自己的标识
        .accessibilityIdentifier("innerLayout")
    }

    /// 滑动只是快捷方式 (§3.6): 键盘区上下滑翻子页 (超高子页里只滚动), 左右滑翻真正的页。
    /// 大屏的键盘区里没有触控板和鼠标键 (都在自己的区里, §5.4 按区域判断), 所以不需要「页里有触控板就禁用」那条。
    private func innerSwipe(plan: DuoLayoutPlan, subIdx: Int, pageCount: Int, pageIdx: Int) -> some Gesture {
        DragGesture(minimumDistance: 20)
            .onEnded { v in
                let dx = v.translation.width, dy = v.translation.height
                if abs(dy) >= 30, abs(dy) > abs(dx) * 1.5 {
                    guard plan.subpages.indices.contains(subIdx), !plan.subpages[subIdx].isTall else { return }
                    let n = subIdx + (dy < 0 ? 1 : -1)
                    if plan.subpages.indices.contains(n) { setSubpageRow(plan.subpages[n].rows.lowerBound) }
                } else if abs(dx) >= 30, abs(dx) > abs(dy) * 1.5 {
                    let target = pageIdx + (dx < 0 ? 1 : -1)
                    if layers.indices.contains(target) { changeLayer(layers[target].id) }
                }
            }
    }

    // MARK: 内屏顶栏: 左 = 状态灯 + 电脑圆圈; 右 = (单区切换) / 调换 / 设置。都避开摄像头 (§3.8 第 4 条)
    @ViewBuilder
    private func innerTopBar(_ plan: DuoLayoutPlan) -> some View {
        if plan.isNarrow { innerNarrowTopBar(plan) } else { innerWideTopBar(plan) }
    }

    private func innerWideTopBar(_ plan: DuoLayoutPlan) -> some View {
        // 摄像头落在顶栏里时, 左段只排到摄像头左边 8 pt (右段从右往左排, 宽度固定)
        let leftLimit = plan.topBarAvoid.map { $0.minX - 8 - plan.topBar.minX }.min()
        return HStack(spacing: 8) {
            HStack(spacing: 12) {
                if themeManager.statusLightOn {
                    AgentLightBar(status: client.agentStatuses[shownAgent], agent: shownAgent, auto: agentAuto,
                                  orientation: themeManager.lightOrientation, connected: client.status == .connected,
                                  compact: true) { sel in
                        if sel == "__auto__" { agentAuto = true } else { agentAuto = false; selectedAgent = sel }
                    }
                } else {
                    BrandMark(size: 22)
                }
                computerCirclesBar
            }
            .frame(maxWidth: leftLimit.map { max(0, $0) } ?? .infinity, alignment: .leading)
            .clipped()
            Spacer(minLength: 0)
            if plan.showsZoneToggle { innerZoneToggle }
            if plan.swapAvailable {
                innerRoundButton(icon: plan.arrangement == .stacked ? "arrow.up.arrow.down" : "arrow.left.arrow.right",
                                 id: "swapButton", label: String(localized: "调换键盘和触控板")) { toggleSwap(plan.arrangement) }
            }
            innerRoundButton(icon: "gearshape", id: "settingsButton", label: String(localized: "设置")) {
                DebugTimeline.record("settingsButton action (inner)"); showSettings = true
            }
        }
    }

    /// 窄窗口顶栏 (§4.6): 状态圆钮 +「当前电脑」条 + 调换 / 单区切换 + 设置; 放不下时按 DuoTopBarPlan 逐级收起。
    private func innerNarrowTopBar(_ plan: DuoLayoutPlan) -> some View {
        let single = plan.showsZoneToggle
        let bar = DuoTopBarPlan.narrow(width: plan.topBar.width, single: single)
        return HStack(spacing: DuoTopBarPlan.gap) {
            if bar.showStatus, themeManager.statusLightOn {
                AgentLightBar(status: client.agentStatuses[shownAgent], agent: shownAgent, auto: agentAuto,
                              orientation: themeManager.lightOrientation, connected: client.status == .connected,
                              compact: true, iconOnly: true) { sel in
                    if sel == "__auto__" { agentAuto = true } else { agentAuto = false; selectedAgent = sel }
                }
                .frame(width: DuoTopBarPlan.button, height: DuoTopBarPlan.button)
            }
            if bar.tooNarrow {
                Text("窗口太窄").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.hint)
                    .frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
            } else {
                currentComputerChip.frame(width: bar.chipWidth)
            }
            if !bar.showStatus || !themeManager.statusLightOn { Spacer(minLength: 0) }
            if single { innerZoneToggle }
            if bar.collapsedMenu {
                Menu {
                    if plan.swapAvailable {
                        Button(String(localized: "调换键盘和触控板")) { toggleSwap(plan.arrangement) }
                    }
                    Button(String(localized: "设置")) { showSettings = true }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(theme.textSecondary).frame(width: 44, height: 44)
                        .background(Circle().fill(theme.surface).raisedShadow(theme))
                        .overlay(Circle().strokeBorder(theme.hairline, lineWidth: 1))
                }
                .accessibilityIdentifier("innerMoreMenu")
            } else {
                if !single, plan.swapAvailable {
                    innerRoundButton(icon: plan.arrangement == .stacked ? "arrow.up.arrow.down" : "arrow.left.arrow.right",
                                     id: "swapButton", label: String(localized: "调换键盘和触控板")) { toggleSwap(plan.arrangement) }
                }
                innerRoundButton(icon: "gearshape", id: "settingsButton", label: String(localized: "设置")) { showSettings = true }
            }
        }
    }

    /// 「当前电脑」条 (§4.6): 电脑名 + 当前模式, 状态点在里面; 名字太长截断; 点开是电脑列表 (能看到全名和连接状态)。
    /// 长按的「新窗口」菜单在 M5 做。
    private var currentComputerChip: some View {
        let name = currentComputer.map { NSLocalizedString($0.name, comment: "") } ?? ""
        let mode = store.mode(computer: window.computerID, mode: window.modeID).map { NSLocalizedString($0.name, comment: "") } ?? ""
        return Button { showConnection = true } label: {
            HStack(spacing: 8) {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.system(size: 14, weight: .bold)).lineLimit(1).truncationMode(.tail)
                    Text(mode).font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textSecondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.down").font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.textTertiary)
            }
            .foregroundStyle(theme.textPrimary)
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(Capsule().fill(theme.surface).raisedShadow(theme))
            .overlay(Capsule().strokeBorder(theme.hairline, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("currentComputerChip")
        .accessibilityLabel(name)
        .accessibilityValue("\(badgeState.title) · \(mode)")
    }

    /// 单区「键盘 / 触控板」切换 (§3.5): 全开时在顶栏右侧, 两段式, 每段 48 × 44 完整命中格; 两种单区下都能点到。
    private var innerZoneToggle: some View {
        HStack(spacing: 0) {
            ForEach([SingleZone.keys, .trackpad], id: \.self) { z in
                let on = window.singleZone == z
                Button { setSingleZone(z) } label: {
                    Image(systemName: z == .keys ? "keyboard" : "rectangle.and.hand.point.up.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(on ? theme.accentInk : theme.textSecondary)
                        .frame(width: 48, height: 44)
                        .background(Capsule().fill(on ? theme.accentLight : Color.clear).padding(3))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(z == .keys ? String(localized: "键盘") : String(localized: "触控板"))
                .accessibilityValue(on ? String(localized: "当前") : "")
            }
        }
        .background(Capsule().fill(theme.surface).raisedShadow(theme))
        .overlay(Capsule().strokeBorder(theme.hairline, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("innerZoneToggle")
    }

    private func innerRoundButton(icon: String, id: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
                .frame(width: 44, height: 44)
                .background(Circle().fill(theme.surface).raisedShadow(theme))
                .overlay(Circle().strokeBorder(theme.hairline, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .accessibilityLabel(label)
    }

    // MARK: 分页行: 分页条 + 子页圆点 (§3.6): 子页多于 3 个、或分页条会窄于 160 时, 圆点收成「子页 i/n ▾」
    private func innerPagerRow(pages: [KeyLayer], plan: DuoLayoutPlan, subIdx: Int) -> some View {
        let w = plan.pagerRow?.width ?? 0
        let n = plan.subpages.count > 1 ? plan.subpages.count : 0
        let dotsW = CGFloat(n) * 44
        let collapse = n > 3 || (pages.count > 1 && w - dotsW - 8 < 160)
        // 真正的页也按剩余宽度收成列表入口 (M3 审计 I3): 子页入口占掉的宽度之外, 放不下每页一个 44 宽的按钮、或窄于 160 就收起
        let pagesW = w - (n > 0 ? (collapse ? 104 : dotsW) + 8 : 0)
        let collapsePages = pages.count > 1 && (pagesW < 160 || (pages.count > 2 && CGFloat(pages.count) * 48 > pagesW))
        return HStack(spacing: 8) {
            if collapsePages {
                innerPageMenu(pages).frame(maxWidth: .infinity, alignment: .leading)
            } else if pages.count > 1 {
                innerPageSwitcher(pages)
            } else {
                Spacer(minLength: 0)
            }
            if n > 0 {
                if collapse {
                    Menu {
                        ForEach(plan.subpages.indices, id: \.self) { i in
                            Button(String(localized: "子页 \(i + 1)/\(n)")) { setSubpageRow(plan.subpages[i].rows.lowerBound) }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("子页 \(subIdx + 1)/\(n)").font(.system(size: 13, weight: .semibold))
                            Image(systemName: "chevron.down").font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(theme.textPrimary)
                        .frame(width: 104, height: 44)
                        .background(Capsule().fill(theme.surface))
                        .overlay(Capsule().strokeBorder(theme.hairline, lineWidth: 1))
                    }
                    .accessibilityIdentifier("innerSubpageMenu")
                } else {
                    HStack(spacing: 0) {
                        ForEach(plan.subpages.indices, id: \.self) { i in
                            let on = i == subIdx
                            Button { setSubpageRow(plan.subpages[i].rows.lowerBound) } label: {
                                Circle().fill(on ? theme.accent : theme.textTertiary.opacity(0.4))
                                    .frame(width: 8, height: 8)
                                    .frame(width: 44, height: 44).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(String(localized: "子页 \(i + 1)/\(n)"))
                        }
                    }
                    .accessibilityIdentifier("innerSubpageDots")
                }
            }
        }
    }

    /// 真正的页的列表入口 (44 高): 「第 i/n 页 ▾」, 点开是页列表, 每页都点得到。
    private func innerPageMenu(_ pages: [KeyLayer]) -> some View {
        let idx = (pages.firstIndex { $0.id == currentLayerID } ?? 0) + 1
        return Menu {
            ForEach(pages.indices, id: \.self) { i in
                Button(String(localized: "第 \(i + 1) 页")) { changeLayer(pages[i].id) }
            }
        } label: {
            HStack(spacing: 4) {
                Text("第 \(idx)/\(pages.count) 页").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(theme.textPrimary)
            .padding(.horizontal, 12).frame(height: 44)
            .background(Capsule().fill(theme.surface))
            .overlay(Capsule().strokeBorder(theme.hairline, lineWidth: 1))
        }
        .accessibilityIdentifier("innerPageMenu")
    }

    @ViewBuilder
    private func innerPageSwitcher(_ pages: [KeyLayer]) -> some View {
        if pages.count == 2 {
            SoftSegmentedControl(
                items: [(title: String(localized: "主页 · 输入"), tag: pages[0].id), (title: String(localized: "第 2 页 · 快捷"), tag: pages[1].id)],
                selection: Binding(get: { pages.contains { $0.id == currentLayerID } ? currentLayerID : pages[0].id },
                                   set: { changeLayer($0) }))
        } else {
            HStack(spacing: 4) {
                ForEach(pages.indices, id: \.self) { i in
                    let on = pages[i].id == currentLayerID
                    Button { changeLayer(pages[i].id) } label: {
                        Text("\(i + 1)").font(.system(size: 14, weight: on ? .bold : .medium))
                            .foregroundStyle(on ? theme.accentInk : theme.textSecondary)
                            .frame(minWidth: 44, minHeight: 44)
                            .background(Capsule().fill(on ? theme.accentLight : Color.clear))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "第 \(i + 1) 页"))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: 网格: 当前子页的键。行高按「刚好放下 / 均分」, 但不超过 maxKeyRowHeight; 键靠上排
    /// 某个键在网格里的位置 (和 KeyboardView 同一套算法: 列距、行距 8)。找不到就用网格左上角。
    private func keyRect(_ id: UUID?, in keys: [KeyCap], columns: Int, width: CGFloat, rowH: CGFloat) -> CGRect {
        guard let id, let k = keys.first(where: { $0.id == id }) else { return CGRect(x: 0, y: 0, width: 44, height: 44) }
        let gap = SubpageSplitter.rowGap, cols = CGFloat(max(1, columns))
        let cw = max(1, (width - gap * (cols - 1)) / cols)
        return CGRect(x: CGFloat(k.col) * (cw + gap), y: CGFloat(k.row) * (rowH + gap),
                      width: cw * CGFloat(k.colSpan) + gap * CGFloat(k.colSpan - 1), height: rowH * CGFloat(k.rowSpan) + gap * CGFloat(k.rowSpan - 1))
    }

    @ViewBuilder
    private func innerGrid(page: KeyLayer, plan: DuoLayoutPlan, subIdx: Int, width: CGFloat, height: CGFloat, usable: Bool,
                           visibleHeight: CGFloat? = nil) -> some View {
        // 只画完整露在可见高度里的键 (行底 ≤ visibleHeight); 面板锚点判断用同一个计算 (R-I1)
        let g = InnerGridShown.compute(pageKeys: page.keys, rowCount: page.rowCount, subpages: plan.subpages, subIdx: subIdx,
                                       height: height, visibleHeight: visibleHeight)
        let keys = g.keys, shown = g.shown, rowH = g.rowHeight, gridH = g.gridHeight
        VStack(spacing: 0) {
            KeyboardView(layer: KeyLayer(id: page.id, columns: page.columns, keys: shown), connected: usable,
                         permissionMode: permissionMode, effortLevel: effortLevel,
                         agentSessions: client.agentSessions, client: client, onKey: handle, pageIDs: Set(layers.map(\.id)),
                         rowHeightOverride: rowH, scrollsContent: g.scrolls)
                // 少画了被挡住的行时, 框高也只算画出的行, 免得 KeyboardView 竖直居中把剩下的行往下挪
                .frame(height: shown.count == keys.count ? gridH
                       : max(0, CGFloat(shown.map { $0.row + $0.rowSpan }.max() ?? 0) * (rowH + SubpageSplitter.rowGap) - SubpageSplitter.rowGap))
                // 权限 / 思考强度: 从被按的那个键旁边弹出小浮层 (§4.8), 箭头指向按键
                .popover(isPresented: paletteBinding(.permission, inGrid: true),
                         attachmentAnchor: .rect(.rect(keyRect(popoverKeyID, in: keys, columns: page.columns, width: width, rowH: rowH)))) {
                    permissionPalette.frame(width: 360, height: 500)      // 固定尺寸: 面板内容会尽量撑大, 不限制就铺满窗口、看不到指向按键的箭头
                }
                .popover(isPresented: paletteBinding(.effort, inGrid: true),
                         attachmentAnchor: .rect(.rect(keyRect(popoverKeyID, in: keys, columns: page.columns, width: width, rowH: rowH)))) {
                    effortPalette.frame(width: 320, height: 470)
                }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("innerGrid")
    }

    // MARK: 语音面板 (§4.8): 键盘没弹起 → 停靠在键盘区底部; 键盘挡住输入区 → 紧凑条; 紧凑条放不下 → 盖住整个窗口
    @ViewBuilder
    private func innerVoicePanel(plan: DuoLayoutPlan, vk: DuoVoiceKeyboardPlan?, at: (CGRect) -> CGPoint) -> some View {
        let target = currentComputer.map { NSLocalizedString($0.name, comment: "") } ?? ""
        let rect: CGRect = {
            // 模态语音页: 盖住整个窗口 (背景另画), 面板本身排在系统键盘以上看得见的那块
            if let vk, vk.modal { return CGRect(x: plan.topBar.minX, y: plan.usable.minY + 8, width: plan.topBar.width, height: max(DuoVoiceKeyboardPlan.panelHeight, vk.visibleBottom - plan.usable.minY - 8)) }
            if let r = vk?.panel { return r }
            let kb = plan.keyboard ?? plan.grid ?? CGRect(x: plan.topBar.minX, y: plan.topBar.maxY + 12, width: plan.topBar.width, height: plan.bottomRow.minY - plan.topBar.maxY - 20)
            let h = min(DuoVoicePanelMetrics.dockedHeight, kb.height)
            return CGRect(x: kb.minX, y: kb.maxY - h, width: kb.width, height: h)
        }()
        let style: InnerVoicePanel.Style = vk == nil ? .docked : (vk!.modal ? .page : .compact)
        if style == .page {
            theme.bgGradient.ignoresSafeArea().contentShape(Rectangle()).onTapGesture {}     // 模态: 下面的输入区不接受触摸
                .accessibilityHidden(true)
        }
        InnerVoicePanel(style: style, draft: voiceDraft, client: client, targetName: target) { closeVoice() }
            .frame(width: rect.width, height: rect.height).position(at(rect))
    }

    // MARK: 底行胶囊: 模式 + 语音 (竖向固定在底部右侧; 横向跟着键盘一侧)
    private func innerDock(_ arrangement: DuoArrangement) -> some View {
        HStack(spacing: 0) {
            Button { showModeManager = true } label: {
                VStack(spacing: 2) {
                    Image(systemName: "square.stack.3d.up").font(.system(size: 18, weight: .medium))
                    Text("模式").font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(theme.textSecondary)
                .frame(width: 52, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("modeButton")
            .padding(.leading, 18)
            Spacer(minLength: 8)
            GeometryReader { g in
                let d = min(g.size.height, 52)
                Button { openVoice() } label: {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(theme.accentText)
                        .frame(width: d, height: d)
                        .background(Circle().fill(theme.accent))
                        .shadow(color: theme.accent.opacity(0.34), radius: 10, x: 0, y: 4)
                }
                .accessibilityIdentifier("dockMic")
                .frame(width: g.size.width, height: g.size.height, alignment: .trailing)
            }
            .frame(width: 52)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
        }
        .background(Capsule().fill(theme.surface).raisedShadow(theme))
        .overlay(Capsule().strokeBorder(theme.hairline, lineWidth: 1))
    }

    private func innerPlaceholder(title: String, text: String) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.textPrimary)
            Text(text).font(.system(size: 13)).foregroundStyle(theme.hint).multilineTextAlignment(.center)
        }
        .padding(16)
    }
}

// MARK: - 笔记本键盘模式 (§4.9, M3f): 内屏竖屏一整块 / 横屏分体; 外屏显示提示卡
extension ContentView {
    fileprivate var isLaptopMode: Bool { store.mode(computer: window.computerID, mode: window.modeID)?.kind == .laptopKeyboard }
    /// 这台电脑的排法 (M3 审计 I7): 按电脑各记各的; 这台从没识别出来过就默认 Mac (不借用别的电脑的记录)。
    fileprivate var laptopPlatform: LaptopPlatform { perComputer.platform(for: window.computerID) ?? .mac }
    /// 「这次没识别出来」和「有没有历史值」分开: 只要这次连接没报告可识别的系统 (没连上 / 报了认不出的系统), 就标「系统待识别」。
    fileprivate var laptopPlatformPending: Bool {
        !(client.connectedComputerID == window.computerID && client.status == .connected
          && client.serverPlatform.flatMap(LaptopPlatform.init(serverPlatform:)) != nil)
    }

    fileprivate func innerLaptopBody(_ geo: GeometryProxy, obs: DuoObservation) -> some View {
        // 外框 (顶栏、分界、触控板区、底行) 借用网格模式的 DuoLayout: 用一页 12 列 × 6 行的占位页算
        let probe = DuoPageInfo(columns: 12, rowCount: 6, keys: [], pageCount: 1)
        let arrangement = DuoLayout.plan(obs, page: probe, swapped: false).arrangement
        // 竖屏调换照常 (键盘到另一侧后按实际区域重算); 横屏调换是本模式的例外: 键盘不动, 触控板和掌托互换
        let base = DuoLayout.plan(obs, page: probe, swapped: arrangement == .stacked ? swapPortrait : false)
        let lp = LaptopLayoutPlan.plan(base: base, swapped: arrangement == .sideBySide && swapLandscape)
        let safe = geo.safeAreaInsets
        let usable = (client.status == .connected && client.serverAXAuthorized) || DebugArgs.has("--assume-connected")
        func at(_ r: CGRect) -> CGPoint { CGPoint(x: r.midX - safe.leading, y: r.midY - safe.top) }
        let kbFrame = innerKeyboardFrame(obs)
        // 系统键盘弹起时 (语音面板), 笔记本键盘暂时让给语音面板, 收起后恢复 (§4.8 最后一条)
        // 语音避让按实际的笔记本排法算 (调换后触控板在哪一侧, M3 审计 I1)
        let vk = showDictation ? DuoVoiceKeyboardPlan.plan(base: LaptopLayoutPlan.voiceBase(base: base, laptop: lp), keyboard: kbFrame, window: obs.window) : nil
        // 「用触控板」: 复用单区触控板的选边和预算, 不跨内部分界 (M3 审计 B4)
        let single = DuoLayout.plan(obs, page: probe, swapped: arrangement == .stacked ? swapPortrait : swapLandscape,
                                    singleChoice: .trackpad, forceSingle: true)
        let rows = LaptopKeymap.rows(laptopPlatform, portrait: lp.kind == .portrait)
        let leftMouse = KeyCap(label: "左键", code: "left", kind: .mouseButton), rightMouse = KeyCap(label: "右键", code: "right", kind: .mouseButton)
        let tooSmall = lp.kind == .tooSmall
        let content = CGRect(x: base.topBar.minX, y: base.topBar.maxY + 12, width: base.topBar.width, height: max(0, base.bottomRow.minY - 8 - base.topBar.maxY - 12))

        return ZStack(alignment: .topLeading) {
            theme.bgGradient.ignoresSafeArea()
            innerTopBar(base).frame(width: base.topBar.width, height: base.topBar.height).position(at(base.topBar))
            if let chip = laptop.sticky.summary(laptopPlatform) {
                laptopStickyChip(chip.text).position(x: base.topBar.midX - safe.leading, y: base.topBar.midY - safe.top)
            } else if laptopPlatformPending, !tooSmall {
                // 没识别出排法: 放在顶栏中间 (有粘滞摘要时让位给摘要)
                Text("系统待识别 · 暂用 \(laptopPlatform == .mac ? "Mac" : "Windows") 排法")
                    .font(.system(size: 11.5, weight: .medium)).foregroundStyle(theme.hint)
                    .position(x: base.topBar.midX - safe.leading, y: base.topBar.midY - safe.top)
                    .allowsHitTesting(false)
            }
            Group {
                if vk == nil, !tooSmall {
                    LaptopKeyBlock(rows: rows.left, unit: lp.unit, rowHeight: lp.rowHeight, platform: laptopPlatform, enabled: usable, session: laptop, client: client)
                        .frame(width: lp.left.width, height: lp.left.height).position(at(lp.left))
                    if let r = lp.right {
                        LaptopKeyBlock(rows: rows.right, unit: lp.unit, rowHeight: lp.rowHeight, platform: laptopPlatform, enabled: usable, session: laptop, client: client)
                            .frame(width: r.width, height: r.height).position(at(r))
                    }
                }
                if let vk {
                    if let tp = vk.trackpad {
                        TrackpadView(client: client, enabled: usable).frame(width: tp.width, height: tp.height).position(at(tp))
                        ForEach(Array(zip([leftMouse, rightMouse], vk.mouseButtons).enumerated()), id: \.offset) { _, pair in
                            MouseKeyButton(cap: pair.0, client: client, enabled: usable).frame(width: pair.1.width, height: pair.1.height).position(at(pair.1))
                        }
                    }
                } else if tooSmall && laptopUseTrackpad {
                    // 「用触控板」: 这个模式的临时显示, 空间够了自动回到键盘
                    if case .single(.trackpad) = single.content, let tp = single.trackpad, let mr = single.mouseRow {
                        TrackpadView(client: client, enabled: usable).frame(width: tp.width, height: tp.height).position(at(tp))
                        HStack(spacing: 8) {
                            MouseKeyButton(cap: leftMouse, client: client, enabled: usable)
                            MouseKeyButton(cap: rightMouse, client: client, enabled: usable)
                        }
                        .frame(width: mr.width, height: mr.height).position(at(mr))
                    } else {
                        innerPlaceholder(title: String(localized: "窗口太小"),
                                         text: String(localized: "放不下触控板和鼠标键。请换个模式, 或加大窗口。"))
                            .frame(width: content.width).position(at(content))
                    }
                } else if tooSmall {
                    LaptopNoticeCard(title: String(localized: "空间不够，放不下笔记本键盘"),
                                     detail: String(localized: "单位键宽至少 28 pt、行高至少 40 pt。可以先用触控板，空间够了会自动回到键盘。"),
                                     onTrackpad: { inputGuard.interrupt(); laptopUseTrackpad = true },
                                     onSwitchMode: { showModeManager = true },
                                     switchTitle: String(localized: "换个模式"))
                        .padding(.horizontal, 12)
                        .frame(width: content.width).position(at(content))
                } else {
                    if let tp = lp.trackpad {
                        TrackpadView(client: client, enabled: usable).frame(width: tp.width, height: tp.height).position(at(tp))
                            .overlay(alignment: .top) { EmptyView() }
                        if !laptop.sticky.isEmpty {        // 修饰键对触控板不起作用 (§4.9)
                            Text("修饰键对触控板不起作用").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(theme.accentInk)
                                .frame(width: tp.width).position(x: tp.midX - safe.leading, y: tp.maxY - safe.top - 16)
                                .allowsHitTesting(false)
                        }
                    }
                    if let m = lp.mouseRow {
                        HStack(spacing: 8) {
                            MouseKeyButton(cap: leftMouse, client: client, enabled: usable)
                            MouseKeyButton(cap: rightMouse, client: client, enabled: usable)
                        }
                        .frame(width: m.width, height: m.height).position(at(m))
                    }
                    if let palm = lp.palm { LaptopPalmRest().frame(width: palm.width, height: palm.height).position(at(palm)) }
                }
            }
            .opacity(swapFadeOut ? 0 : 1)
            .allowsHitTesting(!inputGuard.frozen && !swapAnimating)
            // 竖屏: 胶囊在底行 (同普通双区); 横屏: 模式和语音竖排在左半外侧
            if let side = lp.sideControls, vk == nil {
                VStack(spacing: 14) {
                    innerRoundButton(icon: "square.stack.3d.up", id: "modeButton", label: String(localized: "模式")) { showModeManager = true }
                    Button { openVoice() } label: {
                        Image(systemName: "mic.fill").font(.system(size: 20, weight: .medium)).foregroundStyle(theme.accentText)
                            .frame(width: 52, height: 52).background(Circle().fill(theme.accent))
                    }
                    .accessibilityIdentifier("dockMic")
                }
                .frame(width: side.width).position(x: side.midX - safe.leading, y: side.minY - safe.top + 60)
            } else if lp.kind != .split {
                innerDock(base.arrangement).frame(width: base.dock.width, height: base.dock.height).position(at(base.dock))
                    .opacity(vk.map { base.dock.maxY > $0.visibleBottom } == true ? 0 : 1)
            }
            if showDictation { innerVoicePanel(plan: base, vk: vk, at: at) }
            // 放在最上层 (盖在键盘上面), 不挡操作
            if let note = laptop.notice {
                Text(note).font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.textPrimary)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Capsule().fill(theme.surface).raisedShadow(theme))
                    .position(x: base.topBar.midX - safe.leading, y: base.topBar.maxY - safe.top + 30)
                    .allowsHitTesting(false)                       // 不挡操作
                    .accessibilityIdentifier("laptopNotice")
            }
        }
        .frame(width: geo.size.width, height: geo.size.height)
        .allowsHitTesting(!swapAnimating)                  // §4.4: 调换动画期间整个交互容器都不接受输入
        .onChange(of: tooSmall) { small in inputGuard.interrupt(); if !small { laptopUseTrackpad = false } }   // 键盘重排前结束输入 (B1)
        .onChange(of: laptopPlatform) { _ in inputGuard.interrupt() }     // 空间够了自动回到键盘
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("laptopLayout")
    }

    /// 粘滞摘要 (§4.9): 「⌘ 粘住一次」/「3 个修饰键」+ 右边 ✕ 一键全部取消 (44 × 44, 不压缩)。
    private func laptopStickyChip(_ text: String) -> some View {
        let items = laptop.sticky.summaryItems(laptopPlatform)
        return HStack(spacing: 0) {
            if items.count > 1 {
                // 两个以上: 「3 个修饰键 ▾」, 点开看每一个的状态 (M3 审计 S2)
                Menu {
                    ForEach(items, id: \.self) { item in Button(item) {}.accessibilityLabel(item) }
                    Divider()
                    Button(String(localized: "全部取消"), role: .destructive) { laptop.clearAll() }
                } label: {
                    HStack(spacing: 4) {
                        Text(text).font(.system(size: 13, weight: .medium))
                        Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(theme.accentInk).lineLimit(1).padding(.leading, 12).frame(minHeight: 44)
                }
                .accessibilityLabel(text)
                .accessibilityValue(items.joined(separator: "，"))
                .accessibilityIdentifier("laptopStickyMenu")
            } else {
                Text(text).font(.system(size: 13, weight: .medium)).foregroundStyle(theme.accentInk).lineLimit(1).padding(.leading, 12)
            }
            Button { laptop.clearAll() } label: {
                Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.textTertiary)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "取消全部修饰键"))
        }
        .frame(height: 44)
        .background(Capsule().fill(theme.accentLight.opacity(0.6)))
        .overlay(Capsule().strokeBorder(theme.accent.opacity(0.35), lineWidth: 1))
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("laptopStickyChip")
    }

    /// 外屏 (合上) 时选着笔记本键盘 (§4.9): 提示卡「笔记本键盘需要展开屏幕」+「使用触控板」「切换模式」; 模式本身保留, 展开后恢复。
    fileprivate var laptopFoldedBody: some View {
        ZStack {
            theme.bgGradient.ignoresSafeArea()
            VStack(spacing: 16) {
                topBar
                Spacer(minLength: 0)
                LaptopNoticeCard(title: String(localized: "笔记本键盘需要展开屏幕"),
                                 detail: String(localized: "展开 iPhone 就会回到笔记本键盘。合上时可以先用触控板，或换个模式。"),
                                 onTrackpad: { inputGuard.interrupt(); laptopOuterTrackpad = true },
                                 onSwitchMode: { showModeManager = true })
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
    }

    /// 外屏上选了「使用触控板」: 整块触控板 + 左右键 (临时显示; 展开后回到笔记本键盘)。
    fileprivate var laptopPhoneTrackpadBody: some View {
        let usable = (client.status == .connected && client.serverAXAuthorized) || DebugArgs.has("--assume-connected")
        return ZStack {
            theme.bgGradient.ignoresSafeArea()
            VStack(spacing: 12) {
                topBar
                TrackpadView(client: client, enabled: usable)
                HStack(spacing: 8) {
                    MouseKeyButton(cap: KeyCap(label: "左键", code: "left", kind: .mouseButton), client: client, enabled: usable)
                    MouseKeyButton(cap: KeyCap(label: "右键", code: "right", kind: .mouseButton), client: client, enabled: usable)
                }
                .frame(height: 56)
                dock
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .allowsHitTesting(!inputGuard.frozen)
        }
    }
}

#if DEBUG
/// 单测挂载 ContentView 后用的接入钩子 (只在 DEBUG 编译): 把测试接到真实组件的生命周期上 (M3 审计「测试要求」)。
@MainActor enum ContentViewTestHooks { static var current: ContentView? }
extension ContentView {
    var testGuard: InputGuard { inputGuard }
    var testDriver: DuoLayoutDriver { duoDriver }
    var testStable: DuoObservation? { duoStable }
    var testVoiceDraft: VoiceDraft { voiceDraft }
    var testShowDictation: Bool { showDictation }
    var testPhoneVoicePresented: Bool { phoneVoiceBinding.wrappedValue }
    var testSwapAnimating: Bool { swapAnimating }
    var testSwapPortrait: Bool { swapPortrait }
    func testSetScreen(_ k: ScreenKind) { screenKind = k }
    func testFeed(_ o: DuoObservation) { feedDuo(o) }
    func testOpenVoice() { openVoice() }
    func testCloseVoice() { closeVoice() }
    func testToggleSwap(_ a: DuoArrangement) { toggleSwap(a) }
    func testOpenPalette(_ p: Palette) { palette = p }
    func testPalettePresented(_ p: Palette, inGrid: Bool) -> Bool { paletteBinding(p, inGrid: inGrid).wrappedValue }
    var testSubpageRow: Int { get { window.subpageRow } nonmutating set { window.subpageRow = newValue } }
    func testSelectMode(_ id: UUID) { store.selectMode(id); window.modeID = id; window.layerID = "base" }
    func testOpenPalette(_ p: Palette, key: UUID) { openPalette(p, key: key) }
    var testGridKeys: [KeyCap]? { innerGridKeys() }
    var testUsesInnerPresentation: Bool { usesInnerPresentation }
    /// 当前内屏网格里显示的子页首行 (没有子页时 0)。
    var testCurrentFirstRow: Int? {
        guard let large = innerLarge, let obs = duoStable,
              let page = large.layers.first(where: { $0.id == currentLayerID }) ?? large.layers.first else { return nil }
        let info = DuoPageInfo(columns: page.columns, rowCount: page.rowCount, keys: page.keys, pageCount: large.layers.count)
        let arr = DuoLayout.plan(obs, page: info, swapped: false).arrangement
        let plan = DuoLayout.plan(obs, page: info, swapped: swapped(for: arr), singleChoice: window.singleZone)
        guard !plan.subpages.isEmpty else { return 0 }
        return plan.subpages[SubpageSplitter.subpageIndex(containingRow: window.subpageRow, in: plan.subpages)].rows.lowerBound
    }
    func testSelectGridMode() {
        if let m = store.currentComputer?.modes.first(where: { $0.kind == .grid }) { store.selectMode(m.id); window.modeID = m.id }
    }
}
#endif

#Preview {
    ContentView()
}
