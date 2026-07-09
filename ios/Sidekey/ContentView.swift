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
    @StateObject private var client = SidekeyClient()
    @StateObject private var store = LayoutStore(defaults: AppDefaults.resolve())
    @StateObject private var discovery = Discovery()
    @StateObject private var themeManager = ThemeManager(defaults: AppDefaults.resolve())
    @Environment(\.colorScheme) private var systemScheme

    @State private var currentLayerID = "base"
    @State private var dragX: CGFloat = 0
    @State private var showKeyEditor = false
    @State private var showDictation = false
    @State private var showConnection = false
    @State private var showModeManager = false
    @State private var showSettings = false
    @State private var showPermission = false
    @State private var showEffort = false
    @State private var showSetupGuide = false            // 首启引导: 讲清需要电脑端免费小助手
    @State private var addingMode = false
    @State private var newModeName = ""
    /// 手填首连(TOFU)学到的证书指纹: 弹一次「请核对」提示, 让首次信任不再是静默的 (审计 M-3)。
    @State private var tofuVerifyFP: String?
    @AppStorage("sidekey.agent.selected") private var selectedAgent = "claude"
    @AppStorage("sidekey.agent.auto") private var agentAuto = true
    /// Claude Code 权限模式 / Effort (用户主动选择后的本地显示状态)。持久化, 重启保留。
    @AppStorage("sidekey.permission.mode") private var permissionRaw = PermissionMode.ask.rawValue
    /// 是否把 auto/bypass 纳入 Shift+Tab 循环 (需用户已在 Claude Code 会话启用)。默认关 = 安全的 3 档循环。
    @AppStorage("sidekey.permission.extras") private var permissionExtras = false
    @AppStorage("sidekey.effort.level") private var effortRaw = EffortLevel.high.rawValue
    /// 首启引导只对「全新用户」弹一次(展示过就记住)。
    @AppStorage("sidekey.setupGuideSeen") private var setupGuideSeen = false

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
        ZStack {
            theme.bgGradient.ignoresSafeArea()
            VStack(spacing: 16) {
                topBar
                if client.status == .connected && !client.serverAXAuthorized {
                    axBanner
                }
                failureBanner
                if let fp = tofuVerifyFP { tofuBanner(fp) }
                if store.layers.count > 1 { layerIndicator }
                pager
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                dock
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 12)
        }
        .environment(\.sidekeyTheme, theme)
        .preferredColorScheme(themeManager.preferredColorScheme)
        .onAppear { client.statusDeep = themeManager.statusDeep; maybeAutotest(); applyDebugUI(); discovery.start(); autoConnectIfNeeded(); maybeShowSetupGuide() }
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
        .sheet(isPresented: $showKeyEditor) {
            KeyGridEditorView(store: store, client: client, initialPage: currentLayerID)
        }
        .sheet(isPresented: $showDictation) {
            DictationView(client: client)
        }
        .sheet(isPresented: $showConnection) {
            ConnectionSheet(store: store, client: client, discovery: discovery)
        }
        .sheet(isPresented: $showSetupGuide) {
            // 首启引导:「现在扫码」→ 关引导后打开电脑列表(用户在那里扫码/添加电脑)
            SetupGuideView(onScan: {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showConnection = true }
            })
        }
        .sheet(isPresented: $showModeManager) {
            ModeManagerView(store: store) { _ in currentLayerID = "base" }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(themeManager: themeManager, store: store, client: client)
        }
        .sheet(isPresented: $showPermission) {
            PermissionPaletteView(
                current: permissionMode,
                extras: Binding(
                    get: { permissionExtras },
                    set: { on in
                        // 关掉 extras 时, 若存档里是 auto/bypass 则回到核心档, 避免循环长度错位。
                        // 注意要测「原始存档值」, 不能测 permissionMode (它已按 extras 钳到 .ask, 测了恒为 core)。
                        let wasNonCore = !(PermissionMode(rawValue: permissionRaw) ?? .ask).isCore
                        permissionExtras = on
                        if !on, wasNonCore { permissionRaw = PermissionMode.ask.rawValue }
                    }
                )
            ) { mode in
                let presses = mode.shiftTabPresses(from: permissionMode, includingExtras: permissionExtras)
                client.sendShiftTab(times: presses)           // 真实机制: Shift+Tab 循环
                permissionRaw = mode.rawValue                 // 持久化本地显示状态
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showEffort) {
            EffortPaletteView(current: effortLevel) { level in
                client.sendEffort(level)                      // 发 /effort <级别>
                effortRaw = level.rawValue                    // 持久化本地显示状态
            }
            .presentationDetents([.medium, .large])
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
            moreComputersButton
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
    private func computerCircle(_ c: Computer) -> some View {
        let isCurrent = c.id == store.currentComputerID
        let ring: Color? = isCurrent ? statusColor : nil     // statusColor: 已连绿 / 连接中黄 / 失败红 / 断开灰
        return Button {
            store.selectComputer(c.id)
            reconcileConnection()
        } label: {
            Text(circleGlyph(c))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isCurrent ? theme.accent : theme.textSecondary)
                .frame(width: 40, height: 40)
                .background(Circle().fill(isCurrent ? theme.accentLight.opacity(0.5) : theme.surface).raisedShadow(theme))
                .overlay(Circle().strokeBorder(ring ?? theme.hairline, lineWidth: ring == nil ? 1 : 2.5))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(isCurrent ? "computerCircleCurrent" : "computerCircle")
        .accessibilityLabel(NSLocalizedString(c.name, comment: ""))
    }

    /// 圆圈里显示的字: 电脑名第一个字符 (中文首字 / 英文首字母大写)。
    private func circleGlyph(_ c: Computer) -> String {
        let name = NSLocalizedString(c.name, comment: "").trimmingCharacters(in: .whitespaces)
        guard let first = name.first else { return "?" }
        return String(first).uppercased()
    }

    /// 「…」更多: 打开完整电脑列表。虚线淡圆 + 小三点, 明显轻于实体电脑圆圈, 一眼是"更多"辅助按钮。
    private var moreComputersButton: some View {
        Button { showConnection = true } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.textTertiary)
                .frame(width: 36, height: 36)
                .background(Circle().fill(theme.surface.opacity(0.5)))
                .overlay(Circle().strokeBorder(theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [3, 2.5])))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("moreComputers")
        .accessibilityLabel(String(localized: "更多电脑"))
    }

    /// 切换电脑后按「当前电脑」对齐连接 (与 ConnectionSheet.reconcileConnection 同逻辑: client.connect 幂等)。
    private func reconcileConnection() {
        guard let c = store.currentComputer, !c.host.isEmpty else { client.disconnect(); return }
        client.connect(to: c)
    }

    /// 多页指示: 2 页 = 主键盘/导航 自绘分段; >2 页 = 圆点。
    @ViewBuilder private var layerIndicator: some View {
        let ls = store.layers
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
            Button { showDictation = true } label: {
                Image(systemName: "mic.fill")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(theme.accent))
                    .shadow(color: theme.accent.opacity(0.34), radius: 14, x: 0, y: 6)
                    .shadow(color: theme.accent.opacity(0.18), radius: 3, x: 0, y: 1)
            }
            .accessibilityIdentifier("dockMic")
            Spacer()
            dockButton(icon: "gearshape", label: String(localized: "设置"), id: "settingsButton") { showSettings = true }
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
                .foregroundStyle(theme.warning)
            Text("Mac 上到「系统设置 → 隐私与安全性 → 辅助功能」把 Sidekey 助手打开, 再点重新检测。")
                .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
            Button("重新检测") {
                // 强制重连一次, 重走握手拿最新 AX 能力 (连接协调器幂等, 不 force 会因「配置没变」而不重连)。
                if let c = store.currentComputer, !c.host.isEmpty { client.connect(to: c, force: true) } else { client.connect() }
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16).frame(height: 38)
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
                    .foregroundStyle(theme.danger)
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
                .foregroundStyle(filled ? .white : theme.accent)
                .padding(.horizontal, 18).frame(height: 40)
                .background(Capsule().fill(filled ? theme.accent : theme.surface))
                .overlay(Capsule().strokeBorder(filled ? Color.clear : theme.accent.opacity(0.5), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func retryConnection() {
        if let c = store.currentComputer, !c.host.isEmpty { client.connect(to: c, force: true) }
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
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.accent)
            Text("已记住这台电脑的证书指纹。请核对前 16 位与电脑端横幅显示的一致:")
                .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
            Text(grouped)
                .font(.system(size: 15, weight: .semibold, design: .monospaced)).foregroundStyle(theme.textPrimary)
            Text("不一致可能是被冒充 —— 请到「电脑列表」删除这台重新扫码配对。")
                .font(.system(size: 12)).foregroundStyle(theme.textTertiary)
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

    // MARK: - 点键
    private func handle(_ cap: KeyCap) {
        if let t = cap.sendText, !t.isEmpty {
            client.sendPaste(t)
            client.sendKey(KeyCap(label: "", code: "enter"))
            return
        }
        switch cap.kind {
        case .layer:
            withAnimation { currentLayerID = cap.targetLayer ?? "base" }
        case .record:
            showDictation = true
        case .permission:
            showPermission = true
        case .effort:
            showEffort = true
        case .trackpad, .mouseButton:
            break   // 触控板/鼠标键由各自的视图直接处理触摸, 不经过 onKey
        case .normal:
            guard !cap.code.isEmpty || !cap.mods.isEmpty else { return }  // 纯视觉/配置键: 不发送
            client.sendKey(cap)
        }
    }

    /// 跟手翻页器。触控板页不挂翻页手势 (让触控板独占触摸; 翻页改用顶部分段控件)。
    private var pager: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            let pages = store.layers
            let idx = max(0, pages.firstIndex { $0.id == currentLayerID } ?? 0)
            // 含触控板或鼠标键的页面: 不挂左右滑翻页, 让这些手势(移动/按住)独占触摸; 翻页用顶部分段。
            let onTrackpad = pages.indices.contains(idx)
                && pages[idx].keys.contains { $0.kind == .trackpad || $0.kind == .mouseButton }
            // 「可发键」= 已连接 且 电脑端辅助功能已授权。没授权时按键/触控板必无效, 直接禁用防呆
            // (切层键在 KeyboardView 内单独放行, 离线/未授权也能翻页) —— 修审计 M-4。
            let usable = client.status == .connected && client.serverAXAuthorized
            let stack = HStack(spacing: 0) {
                ForEach(pages) { lyr in
                    KeyboardView(layer: lyr, connected: usable,
                                 permissionMode: permissionMode, effortLevel: effortLevel,
                                 client: client, onKey: handle)
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
            .id(store.currentModeID)
        }
    }

    private func autoConnectIfNeeded() {
        let args = DebugArgs.all   // Release 恒空 → 正式包永远走自动连接(测试参数仅 DEBUG 生效)
        guard !args.contains("--autotest"), !args.contains("--autodiscover") else { return }
        if let c = store.currentComputer, !c.host.isEmpty {
            client.connect(to: c)
        }
    }

    /// 全新用户(还没配过任何电脑)首启弹一次引导, 讲清需要电脑端免费小助手; 老用户不打扰。
    private func maybeShowSetupGuide() {
        guard DebugArgs.all.isEmpty, !setupGuideSeen else { return }   // 调试/UI测试态、或已展示过 → 不弹
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
        if args.contains("--t-dark") { themeManager.appearance = .dark }
        if args.contains("--appearance") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { showSettings = true }
        }
        if args.contains("--permission") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { showPermission = true }
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { showKeyEditor = true }
        }
        if args.contains("--dictation") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showDictation = true }
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

#Preview {
    ContentView()
}
