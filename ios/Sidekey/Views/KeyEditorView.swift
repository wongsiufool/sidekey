import SwiftUI

/// 按键编辑 (brief C3): 顶部 112 实时预览 + SoftPanel 行表单; 修饰键为珊瑚 pill; 色板 28pt; 底部「保存更改」+ 红色删除。
/// 学习按键 / 类型切换 / 主键列表 / 修饰键 / 删除 逻辑保留。
struct KeyEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.sidekeyTheme) private var theme
    @ObservedObject var client: SidekeyClient
    @State private var cap: KeyCap
    @State private var showCodePicker = false
    @State private var showAdvancedMods = false
    @State private var binding = false          // 正在等电脑回「当前最前窗口」
    @State private var loadingList = false       // 正在拉窗口列表
    @State private var windowList: [SidekeyClient.WindowRef] = []
    @State private var showWindowPicker = false
    /// 横屏 (竖向紧凑) 或系统键盘弹出时, 保存 / 删除跟着内容一起滚动, 不再固定在底部占掉滚动区 —— 否则键盘一出来表单视口就没了 (M1 横屏, v1.8 补充)。
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var keyboardShown = false
    /// 键盘在屏幕上的位置和本页底边: 某些情况下 (例如 Duo 外屏横屏的浮动 / 覆盖式键盘) 系统不会替这页让开键盘,
    /// 就自己把滚动视口的底边抬到键盘上方 (系统已经让开时重叠为 0, 不会重复让)。
    @State private var keyboardMinY: CGFloat = .infinity
    @State private var pageMaxY: CGFloat = 0
    private var keyboardOverlap: CGFloat { keyboardShown ? max(0, pageMaxY - keyboardMinY) : 0 }
    private var actionsInline: Bool { verticalSizeClass == .compact || keyboardShown }
    /// 正在编辑的文本框: 键盘弹出 / 切换焦点时把它滚到可见区。
    private enum Field: Hashable { case name, icon, sendText }
    @FocusState private var focused: Field?
    let onSave: (KeyCap) -> Bool          // 返回修改是否生效 (保存失败时修改仍保留在内存, 见「未保存」状态条)
    let onDelete: () -> Void

    init(cap: KeyCap, client: SidekeyClient,
         onSave: @escaping (KeyCap) -> Bool, onDelete: @escaping () -> Void) {
        _cap = State(initialValue: cap)
        _client = ObservedObject(wrappedValue: client)
        self.onSave = onSave
        self.onDelete = onDelete
    }

    private var canSave: Bool {
        if cap.kind == .normal { return !cap.code.isEmpty || !cap.mods.isEmpty || !(cap.sendText ?? "").isEmpty }
        return true
    }
    private var isPureModifier: Bool {
        cap.kind == .normal && cap.code.isEmpty && !cap.mods.isEmpty && (cap.sendText ?? "").isEmpty
    }
    /// Typeless 触发键: icon 标记或同名。它是纯修饰键, 但不是「无效」—— 依赖电脑端的 Typeless app, 单独给说明 (审计 M-7)。
    private var isTypeless: Bool {
        cap.icon == "typeless" || cap.label.caseInsensitiveCompare("typeless") == .orderedSame
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(onBack: { dismiss() }, title: String(localized: "编辑按键"))
                .padding(.horizontal, 20)

            ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 20) {
                    preview.padding(.top, 4)

                    SoftSegmentedControl(
                        items: [(title: String(localized: "普通"), tag: KeyCap.Kind.normal),
                                (title: String(localized: "录音"), tag: KeyCap.Kind.record),
                                (title: String(localized: "权限"), tag: KeyCap.Kind.permission),
                                (title: "Effort", tag: KeyCap.Kind.effort),
                                (title: String(localized: "窗口"), tag: KeyCap.Kind.window)],
                        selection: $cap.kind
                    )

                    if cap.kind == .window {
                        windowBindPanel
                    } else if cap.kind == .normal {
                        if client.status == .connected || client.capturing {
                            learnButton
                        }
                        formPanel
                        if isTypeless {
                            // Typeless 触发键不是「无效」, 而是依赖电脑端的 Typeless app —— 给清楚的说明 (审计 M-7)。
                            HStack(alignment: .top, spacing: 8) {
                                Image("TypelessLogo").renderingMode(.template).resizable().scaledToFit()
                                    .frame(width: 18, height: 18).foregroundStyle(theme.accentInk).padding(.top, 1)
                                Text("Typeless 触发键: 需要电脑装了 Typeless 并把触发设成「左 Ctrl」, 按它才会开始/停止语音输入。没装 Typeless 时, 单按左 Ctrl 在 macOS 上不会有反应。")
                                    .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 14).fill(theme.accent.opacity(0.10)))
                        } else if isPureModifier {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(theme.warning)
                                Text("纯修饰键(没有主键)在 macOS 上通常无效 —— 建议配一个主键, 或改用「发送文本」。")
                                    .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 14).fill(theme.warning.opacity(0.12)))
                        }
                    } else {
                        SoftPanel(padding: 0) {
                            VStack(spacing: 0) { nameRow }
                        }
                    }
                    if actionsInline { actions.padding(.top, 4) }
                }
                .padding(.horizontal, 20).padding(.bottom, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .padding(.bottom, keyboardOverlap)
            .onChange(of: focused) { f in scrollToFocused(f, proxy) }
            .onChange(of: keyboardShown) { _ in scrollToFocused(focused, proxy) }
            .onChange(of: keyboardOverlap) { _ in scrollToFocused(focused, proxy) }
            }

            if !actionsInline {
                actions.padding(.horizontal, 20).padding(.top, 6).padding(.bottom, 12)
            }
        }
        .background(GeometryReader { g in
            Color.clear
                .onAppear { pageMaxY = g.frame(in: .global).maxY }
                .onChange(of: g.frame(in: .global).maxY) { pageMaxY = $0 }
        })
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { n in
            if let f = n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect { keyboardMinY = f.minY }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { n in
            if let f = n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect { keyboardMinY = f.minY }
            keyboardShown = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardShown = false; keyboardMinY = .infinity }
        .background(theme.bgGradient.ignoresSafeArea())
        .onChange(of: client.captured) { newValue in
            guard let c = newValue else { return }
            cap.code = c.code
            cap.mods = c.mods
            let t = cap.label.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t == "新键" { cap.label = suggestedLabel(cap) }
            client.captured = nil
        }
        .sheet(isPresented: $showCodePicker) { CodePickerView(cap: $cap).unsavedBanner() }
        .onAppear {
            if DebugArgs.has("--codepicker") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { showCodePicker = true }
            }
        }
    }

    /// 保存 / 删除: 竖屏且没有键盘时固定在底部; 横屏或键盘弹出时放进滚动内容末尾 (都能点到)。
    private var actions: some View {
        VStack(spacing: 10) {
            CoralButton(title: String(localized: "保存更改"), enabled: canSave) {
                if cap.label.trimmingCharacters(in: .whitespaces).isEmpty { cap.label = suggestedLabel(cap) }
                guard onSave(cap) else { return }; dismiss()
            }
            Button(role: .destructive) { onDelete(); dismiss() } label: {
                Text("删除此按键").font(.system(size: 15, weight: .medium)).foregroundStyle(theme.dangerText)
                    .frame(maxWidth: .infinity).frame(height: 44)
            }.buttonStyle(.plain)
        }
    }

    /// 把正在编辑的文本框滚到可见区 (等键盘动画开始后再滚, 视口已经缩小)。
    private func scrollToFocused(_ f: Field?, _ proxy: ScrollViewProxy) {
        guard let f else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(f, anchor: .center) }
        }
    }

    // MARK: - 窗口快捷键: 绑定当前窗口 (Phase 1)
    private var windowBindPanel: some View {
        VStack(spacing: 14) {
            SoftPanel {
                HStack(spacing: 12) {
                    Image(systemName: "macwindow")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle((cap.winTitle ?? "").isEmpty ? theme.hint : theme.accentInk)
                    VStack(alignment: .leading, spacing: 3) {
                        Text((cap.winTitle ?? "").isEmpty ? String(localized: "未绑定窗口") : (cap.winTitle ?? ""))
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(theme.textPrimary).lineLimit(1)
                        if let a = cap.winApp, !a.isEmpty {
                            Text(a).font(.system(size: 13)).foregroundStyle(theme.textSecondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }

            // 主推: 从电脑的窗口列表里挑任意一个 (不用先把它切到最前)
            CoralButton(title: loadingList ? String(localized: "读取窗口列表…") : String(localized: "从窗口列表选择"),
                        enabled: client.status == .connected && !loadingList) {
                loadingList = true
                client.listWindows { list in
                    loadingList = false
                    windowList = list
                    showWindowPicker = true
                }
            }

            // 次选: 直接绑「当前最前窗口」(适合那个窗口已经在最前时)
            Button {
                binding = true
                client.bindCurrentWindow { ref in
                    binding = false
                    guard let ref else { return }
                    cap.winApp = ref.app
                    cap.winTitle = ref.title
                    cap.winId = ref.winId
                }
            } label: {
                Text(binding ? String(localized: "读取中…") : String(localized: "或: 绑定当前最前窗口"))
                    .font(.system(size: 15, weight: .medium)).foregroundStyle(theme.accentInk)
                    .frame(maxWidth: .infinity).frame(height: 40)
            }
            .buttonStyle(.plain)
            .disabled(client.status != .connected || binding)

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle").foregroundStyle(theme.textSecondary).padding(.top, 1)
                Text("从列表挑一个窗口(Paseo 对话 / 终端 / 浏览器都行)。之后点这个键, 电脑就会把那个窗口切到最前。")
                    .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(theme.accent.opacity(0.08)))

            if client.status != .connected {
                Text("需要先连接电脑才能绑定窗口。")
                    .font(.system(size: 13)).foregroundStyle(theme.warningText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .sheet(isPresented: $showWindowPicker) { windowPickerSheet.unsavedBanner() }
    }

    // 窗口选择器: 列出电脑所有可聚焦窗口, 点一个即绑定。
    private var windowPickerSheet: some View {
        NavigationView {
            List {
                if windowList.isEmpty {
                    Text("没有可选的窗口(确认电脑已连接、且有打开的窗口)")
                        .font(.system(size: 14)).foregroundStyle(theme.textSecondary)
                }
                ForEach(Array(windowList.enumerated()), id: \.offset) { _, w in
                    Button {
                        cap.winApp = w.app
                        cap.winTitle = w.title
                        cap.winId = w.winId
                        showWindowPicker = false
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(w.app).font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(theme.textPrimary)
                            Text(w.title).font(.system(size: 13))
                                .foregroundStyle(theme.textSecondary).lineLimit(1)
                        }
                    }
                }
            }
            .navigationTitle(Text("选择窗口"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "取消")) { showWindowPicker = false }
                }
            }
        }
    }

    // MARK: - 预览
    private var preview: some View {
        KeyTile(cap: cap, enabled: true)
            .frame(width: 112, height: 100)
    }

    // MARK: - 表单
    private var formPanel: some View {
        SoftPanel(padding: 0) {
            VStack(spacing: 0) {
                nameRow
                RowDivider(inset: 16)
                PanelRow(label: String(localized: "主键"), chevron: true, onTap: { showCodePicker = true }) {
                    Text(cap.code.isEmpty ? "无" : cap.code).font(.system(size: 16)).foregroundStyle(theme.textSecondary)
                }.padding(.horizontal, 16)
                RowDivider(inset: 16)
                modifiersRow
                RowDivider(inset: 16)
                iconRow
                RowDivider(inset: 16)
                tintRow
                RowDivider(inset: 16)
                sendTextRow
            }
        }
    }

    private var nameRow: some View {
        HStack(spacing: 12) {
            Text("显示名称").font(.system(size: 16)).foregroundStyle(theme.textPrimary)
            Spacer(minLength: 8)
            TextField("名称", text: $cap.label)
                .font(.system(size: 16)).foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.trailing)
                .focused($focused, equals: .name)
            if cap.kind == .normal && !(cap.code.isEmpty && cap.mods.isEmpty) {
                Button { cap.label = suggestedLabel(cap) } label: {
                    Image(systemName: "wand.and.stars").font(.system(size: 15)).foregroundStyle(theme.accentInk)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16).frame(height: 56)
        .id(Field.name)
    }

    private var modifiersRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("修饰键").font(.system(size: 16)).foregroundStyle(theme.textPrimary)
                Spacer()
                Button { withAnimation { showAdvancedMods.toggle() } } label: {
                    Text(showAdvancedMods ? "收起" : "左右键").font(.system(size: 13)).foregroundStyle(theme.accentInk)
                }.buttonStyle(.plain)
            }
            HStack(spacing: 8) {
                ForEach(KeyCatalog.modifiers) { m in modPill(m.code) }
                Spacer(minLength: 0)
            }
            if showAdvancedMods {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) { ForEach(KeyCatalog.modifiersLR) { m in modPill(m.code) } }
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func modPill(_ code: String) -> some View {
        let on = cap.mods.contains(code)
        return Button {
            if on { cap.mods.removeAll { $0 == code } } else { cap.mods.append(code) }
        } label: {
            Text(glyph(code))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(on ? theme.accentText : theme.textSecondary)
                .padding(.horizontal, 12).frame(height: 32)
                .background(Capsule().fill(on ? theme.accent : theme.surfaceMuted))
        }.buttonStyle(.plain)
    }

    private var iconRow: some View {
        HStack(spacing: 12) {
            Text("图标").font(.system(size: 16)).foregroundStyle(theme.textPrimary)
            Spacer(minLength: 8)
            if let ic = cap.icon, !ic.isEmpty { Image(systemName: ic).foregroundStyle(theme.textSecondary) }
            TextField("SF 符号名 (可选)", text: iconBinding)
                .font(.system(size: 15)).foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.trailing)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
                .focused($focused, equals: .icon)
        }
        .padding(.horizontal, 16).frame(height: 56)
        .id(Field.icon)
    }

    private var tintRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("分组色").font(.system(size: 16)).foregroundStyle(theme.textPrimary)
            HStack(spacing: 12) {
                swatch(nil)
                ForEach(KeyTint.allCases, id: \.self) { swatch($0) }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func swatch(_ t: KeyTint?) -> some View {
        let selected = cap.tint == t
        return Button { cap.tint = t } label: {
            ZStack {
                Circle().fill(swatchColor(t)).frame(width: 28, height: 28)
                if t == nil { Image(systemName: "slash.circle").font(.system(size: 13)).foregroundStyle(theme.textSecondary) }
            }
            .overlay(Circle().strokeBorder(selected ? theme.accent : theme.hairline, lineWidth: selected ? 3 : 1))
        }.buttonStyle(.plain)
    }

    private var sendTextRow: some View {
        HStack(spacing: 12) {
            Text("发送文本").font(.system(size: 16)).foregroundStyle(theme.textPrimary)
            Spacer(minLength: 8)
            TextField("如 /init (留空=不发)", text: sendTextBinding)
                .font(.system(size: 15)).foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.trailing)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
                .focused($focused, equals: .sendText)
        }
        .padding(.horizontal, 16).frame(height: 56)
        .id(Field.sendText)
    }

    private var learnButton: some View {
        Button { client.requestCapture() } label: {
            HStack(spacing: 10) {
                Image(systemName: "wand.and.stars")
                Text(client.capturing ? "在电脑键盘上按下你要的键…" : "从电脑学习按键").font(.system(size: 16, weight: .medium))
                Spacer()
                if client.capturing { ProgressView() }
            }
            .foregroundStyle(theme.accentInk)
            .padding(.horizontal, 16).frame(height: 52)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.accentLight.opacity(0.6)))
        }
        .buttonStyle(.plain)
        .disabled(client.status != .connected || client.capturing)
    }

    // MARK: - bindings / helpers (逻辑不变)
    private var iconBinding: Binding<String> {
        Binding(get: { cap.icon ?? "" }, set: { cap.icon = $0.isEmpty ? nil : $0 })
    }
    private var sendTextBinding: Binding<String> {
        Binding(get: { cap.sendText ?? "" }, set: { cap.sendText = $0.isEmpty ? nil : $0 })
    }

    private func swatchColor(_ t: KeyTint?) -> Color {
        switch t {
        case .none:     return Color(white: 0.92)
        case .accent:   return Color(hex: 0xFF5A3C)
        case .coral:    return Color(hex: 0xFF7D62)
        case .mint:     return Color(hex: 0x2BB389)
        case .sky:      return Color(hex: 0x3B82D6)
        case .lavender: return Color(hex: 0x7B6AD6)
        case .amber:    return Color(hex: 0xD79A2E)
        case .neutral:  return Color(white: 0.6)
        case .success:  return Color(hex: 0x2E9D5E)
        case .danger:   return Color(hex: 0xD2433C)
        }
    }

    private func suggestedLabel(_ c: KeyCap) -> String {
        let parts = c.mods.map(glyph) + (c.code.isEmpty ? [] : [c.code.uppercased()])
        let s = parts.joined()
        return s.isEmpty ? "新键" : s
    }

    private func glyph(_ t: String) -> String {
        let map: [String: String] = [
            "primary": "⌘", "cmd": "⌘", "shift": "⇧", "ctrl": "⌃", "alt": "⌥", "option": "⌥",
            "rcmd": "⌘R", "lcmd": "⌘L", "rshift": "⇧R", "lshift": "⇧L",
            "rctrl": "⌃R", "lctrl": "⌃L", "ralt": "⌥R", "lalt": "⌥L", "alt_gr": "⌥Gr",
        ]
        return map[t] ?? t
    }
}

/// 键码选择 (brief D1): 搜索框 + 分组 SoftPanel + 48pt 行(52×30 微键帽 + 选择圈)。写入行为不变。
struct CodePickerView: View {
    @Binding var cap: KeyCap
    @Environment(\.dismiss) private var dismiss
    @Environment(\.sidekeyTheme) private var theme
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: String(localized: "选择主键"), onClose: { dismiss() }).padding(.horizontal, 20)

            SoftField(label: String(localized: "搜索"), text: $query, placeholder: String(localized: "搜索键名 / 键码"))
                .padding(.horizontal, 20).padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(filteredGroups, id: \.name) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(NSLocalizedString(group.name, comment: "")).font(.system(size: 13, weight: .medium)).foregroundStyle(theme.hint)
                                .padding(.leading, 4)
                            SoftPanel(padding: 0) {
                                VStack(spacing: 0) {
                                    ForEach(Array(group.entries.enumerated()), id: \.element.id) { i, e in
                                        if i > 0 { RowDivider(inset: 72) }
                                        codeRow(e)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 16)
            }
        }
        .background(theme.bgGradient.ignoresSafeArea())
    }

    private func codeRow(_ e: KeyCatalog.Entry) -> some View {
        let sel = cap.code == e.code
        return Button {
            cap.code = e.code
            let t = cap.label.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t == "新键" { cap.label = e.label }
            dismiss()
        } label: {
            HStack(spacing: 14) {
                SoftKeyChip(label: NSLocalizedString(e.label, comment: ""), fill: theme.surfaceMuted, width: 52, height: 30, fontSize: 12)
                Text(e.code).font(.system(size: 16)).foregroundStyle(theme.textPrimary)
                Spacer()
                Image(systemName: sel ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20)).foregroundStyle(sel ? theme.accentInk : theme.hint)
            }
            .padding(.horizontal, 16).frame(height: 48)
        }.buttonStyle(.plain)
    }

    private var filteredGroups: [KeyCatalog.Group] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return KeyCatalog.groups }
        return KeyCatalog.groups.compactMap { g in
            let es = g.entries.filter { $0.label.lowercased().contains(q) || $0.code.lowercased().contains(q) }
            return es.isEmpty ? nil : KeyCatalog.Group(name: g.name, entries: es)
        }
    }
}
