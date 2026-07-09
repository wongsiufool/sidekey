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
    let onSave: (KeyCap) -> Void
    let onDelete: () -> Void

    init(cap: KeyCap, client: SidekeyClient,
         onSave: @escaping (KeyCap) -> Void, onDelete: @escaping () -> Void) {
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

            ScrollView {
                VStack(spacing: 20) {
                    preview.padding(.top, 4)

                    SoftSegmentedControl(
                        items: [(title: String(localized: "普通"), tag: KeyCap.Kind.normal),
                                (title: String(localized: "录音"), tag: KeyCap.Kind.record),
                                (title: String(localized: "权限"), tag: KeyCap.Kind.permission),
                                (title: "Effort", tag: KeyCap.Kind.effort)],
                        selection: $cap.kind
                    )

                    if cap.kind == .normal {
                        if client.status == .connected || client.capturing {
                            learnButton
                        }
                        formPanel
                        if isTypeless {
                            // Typeless 触发键不是「无效」, 而是依赖电脑端的 Typeless app —— 给清楚的说明 (审计 M-7)。
                            HStack(alignment: .top, spacing: 8) {
                                Image("TypelessLogo").renderingMode(.template).resizable().scaledToFit()
                                    .frame(width: 18, height: 18).foregroundStyle(theme.accent).padding(.top, 1)
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
                }
                .padding(.horizontal, 20).padding(.bottom, 16)
            }

            VStack(spacing: 10) {
                CoralButton(title: String(localized: "保存更改"), enabled: canSave) {
                    if cap.label.trimmingCharacters(in: .whitespaces).isEmpty { cap.label = suggestedLabel(cap) }
                    onSave(cap); dismiss()
                }
                Button(role: .destructive) { onDelete(); dismiss() } label: {
                    Text("删除此按键").font(.system(size: 15, weight: .medium)).foregroundStyle(theme.danger)
                        .frame(maxWidth: .infinity).frame(height: 40)
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 20).padding(.top, 6).padding(.bottom, 12)
        }
        .background(theme.bgGradient.ignoresSafeArea())
        .onChange(of: client.captured) { newValue in
            guard let c = newValue else { return }
            cap.code = c.code
            cap.mods = c.mods
            let t = cap.label.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t == "新键" { cap.label = suggestedLabel(cap) }
            client.captured = nil
        }
        .sheet(isPresented: $showCodePicker) { CodePickerView(cap: $cap) }
        .onAppear {
            if DebugArgs.has("--codepicker") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { showCodePicker = true }
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
            if cap.kind == .normal && !(cap.code.isEmpty && cap.mods.isEmpty) {
                Button { cap.label = suggestedLabel(cap) } label: {
                    Image(systemName: "wand.and.stars").font(.system(size: 15)).foregroundStyle(theme.accent)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16).frame(height: 56)
    }

    private var modifiersRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("修饰键").font(.system(size: 16)).foregroundStyle(theme.textPrimary)
                Spacer()
                Button { withAnimation { showAdvancedMods.toggle() } } label: {
                    Text(showAdvancedMods ? "收起" : "左右键").font(.system(size: 13)).foregroundStyle(theme.accent)
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
                .foregroundStyle(on ? .white : theme.textSecondary)
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
        }
        .padding(.horizontal, 16).frame(height: 56)
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
        }
        .padding(.horizontal, 16).frame(height: 56)
    }

    private var learnButton: some View {
        Button { client.requestCapture() } label: {
            HStack(spacing: 10) {
                Image(systemName: "wand.and.stars")
                Text(client.capturing ? "在电脑键盘上按下你要的键…" : "从电脑学习按键").font(.system(size: 16, weight: .medium))
                Spacer()
                if client.capturing { ProgressView() }
            }
            .foregroundStyle(theme.accent)
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
                            Text(NSLocalizedString(group.name, comment: "")).font(.system(size: 13, weight: .medium)).foregroundStyle(theme.textTertiary)
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
                    .font(.system(size: 20)).foregroundStyle(sel ? theme.accent : theme.textTertiary)
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
