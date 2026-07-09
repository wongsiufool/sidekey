import SwiftUI

/// 电脑列表 (brief B1): 自绘 ScrollView + SoftPanel 卡片, 整页 canvas; 底部「添加电脑 / 扫码配对」。
struct ConnectionSheet: View {
    @ObservedObject var store: LayoutStore
    @ObservedObject var client: SidekeyClient
    @ObservedObject var discovery: Discovery
    @Environment(\.dismiss) private var dismiss
    @Environment(\.sidekeyTheme) private var theme

    @State private var showScan = false
    @State private var addManually = false
    @State private var editing: Computer?
    @State private var prefillServer: DiscoveredServer?
    @State private var showGuide = false

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(brandCenter: true, onClose: { dismiss() })
                .padding(.horizontal, 20)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        // 用独立语义 key 而非中文「我的电脑」: 否则与「默认电脑名」共用同一 key,
                        // en 表里两条同 key 互相覆盖, 分区标题会被错显示成 "My Computer" (审计: 重复 key)。
                        SectionTitle(text: NSLocalizedString("computers.section.title", value: "我的电脑", comment: "电脑列表分区标题"))
                        Text("选择一台电脑连接, 或添加新电脑。")
                            .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                    }
                    .padding(.top, 4)

                    // 首次使用入口: 随时再打开「需要电脑端小助手」引导
                    Button { showGuide = true } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "questionmark.circle.fill")
                            Text("首次使用？先在电脑上装免费小助手").font(.system(size: 13, weight: .medium))
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(theme.accent)
                        .padding(.horizontal, 14).padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: theme.radiusCard, style: .continuous)
                            .fill(theme.accentLight.opacity(0.40)))
                    }
                    .buttonStyle(.plain)

                    LazyVStack(spacing: 12) {
                        ForEach(store.computers) { c in
                            VStack(spacing: 8) {
                                computerCard(c)
                                // 当前电脑连接失败时, 卡片下方给出原因 + 可点的「重试 / 重新扫码配对」(审计 H-3)。
                                if c.id == store.currentComputerID, case .failed(let kind) = client.status {
                                    failureActions(kind, for: c)
                                }
                            }
                        }
                    }

                    if !newlyDiscovered.isEmpty {
                        Text("发现的电脑 (未保存)")
                            .font(.system(size: 13, weight: .medium)).foregroundStyle(theme.textTertiary)
                            .padding(.top, 4)
                        LazyVStack(spacing: 12) {
                            ForEach(newlyDiscovered) { discoveredCard($0) }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }

            VStack(spacing: 12) {
                CoralButton(title: String(localized: "添加电脑"), icon: "plus") { addManually = true }
                    .accessibilityIdentifier("手动添加电脑")
                OutlineButton(title: String(localized: "扫码配对"), icon: "qrcode.viewfinder") { showScan = true }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
        .background(theme.bgGradient.ignoresSafeArea())
        .onAppear {
            let a = DebugArgs.all
            if a.contains("--addcomputer") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { addManually = true } }
            if a.contains("--pairing") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { showScan = true } }
        }
        .presentationDetents([.large])
        .sheet(isPresented: $showScan) {
            PairingView(client: client) { handlePaired($0) }
        }
        .sheet(isPresented: $addManually) {
            EditComputerView(store: store, client: client, existing: nil,
                             onSaved: { selectAndConnect($0) }, onDeleted: { reconcileConnection() })
        }
        .sheet(item: $editing) { c in
            // 删除当前已连电脑也必须过连接协调器, 否则 socket 仍指向被删电脑 (修审计 H-2)。
            EditComputerView(store: store, client: client, existing: c,
                             onSaved: { selectAndConnect($0) }, onDeleted: { reconcileConnection() })
        }
        .sheet(item: $prefillServer) { s in
            EditComputerView(store: store, client: client, existing: nil,
                             prefill: (name: displayName(s), host: s.host, port: s.port),
                             onSaved: { selectAndConnect($0) }, onDeleted: { reconcileConnection() })
        }
        .sheet(isPresented: $showGuide) {
            SetupGuideView()        // 从电脑列表再次打开引导;「现在扫码」只需关引导回到本列表
        }
    }

    // MARK: - 卡片
    private func computerCard(_ c: Computer) -> some View {
        let isCurrent = c.id == store.currentComputerID
        return Button { selectAndConnect(c.id) } label: {
            HStack(spacing: 14) {
                IconChip(icon: c.name.contains("笔记") || c.name.lowercased().contains("book") ? "laptopcomputer" : "desktopcomputer",
                         tint: isCurrent ? theme.accent : theme.textSecondary, size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(NSLocalizedString(c.name, comment: "")).font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.textPrimary)  // 默认电脑名显示时本地化; 自定义名原样
                    Text(c.host.isEmpty ? String(localized: "未配置") : "\(c.host):\(String(c.port))")
                        .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                }
                Spacer(minLength: 6)
                if isCurrent {
                    StatusPill(text: statusText, dotColor: statusColor)
                }
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)
            }
            .padding(16)
            .frame(minHeight: 92)
            .background(RoundedRectangle(cornerRadius: theme.radiusCard, style: .continuous).fill(theme.surface).raisedShadow(theme))
            .overlay(RoundedRectangle(cornerRadius: theme.radiusCard, style: .continuous)
                .strokeBorder(isCurrent ? theme.accent : theme.hairline, lineWidth: isCurrent ? 1.5 : 1))
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            // 独立置顶星标: overlay 浮在卡片之上, 命中优先 → 点星标只切置顶, 不会误触发「选中并连接」。
            Button { store.togglePin(c.id) } label: {
                Image(systemName: c.isPinned ? "star.fill" : "star")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(c.isPinned ? theme.warning : theme.textTertiary.opacity(0.5))
                    .padding(9)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("pinToggle")
            .accessibilityLabel(c.isPinned ? String(localized: "取消置顶") : String(localized: "置顶到快捷条"))
        }
        .contextMenu {
            Button { store.togglePin(c.id) } label: {
                Label(c.isPinned ? "取消置顶" : "置顶到快捷条", systemImage: c.isPinned ? "star.slash" : "star")
            }
            Button { editing = c } label: { Label("编辑", systemImage: "pencil") }
            Button(role: .destructive) {
                store.deleteComputer(id: c.id); reconcileConnection()
            } label: { Label("删除", systemImage: "trash") }
        }
    }

    /// 失败原因 + 行动按钮。令牌/证书类把「重新扫码配对」作主操作, 网络类把「重试」作主操作。
    @ViewBuilder
    private func failureActions(_ kind: SidekeyClient.FailureKind, for c: Computer) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(kind.detail).font(.system(size: 13)).foregroundStyle(theme.textSecondary)
            HStack(spacing: 10) {
                if kind.needsRepair {
                    actionButton(String(localized: "重新扫码配对"), filled: true) { showScan = true }
                    actionButton(String(localized: "重试"), filled: false) { client.connect(to: c, force: true) }
                } else {
                    actionButton(String(localized: "重试"), filled: true) { client.connect(to: c, force: true) }
                    actionButton(String(localized: "重新扫码配对"), filled: false) { showScan = true }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: theme.radiusCard, style: .continuous).fill(theme.danger.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: theme.radiusCard, style: .continuous)
            .strokeBorder(theme.danger.opacity(0.3), lineWidth: 1))
    }

    private func actionButton(_ title: String, filled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 14, weight: .semibold))
                .foregroundStyle(filled ? .white : theme.accent)
                .frame(maxWidth: .infinity).frame(height: 40)
                .background(Capsule().fill(filled ? theme.accent : theme.surface))
                .overlay(Capsule().strokeBorder(filled ? Color.clear : theme.accent.opacity(0.5), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func discoveredCard(_ s: DiscoveredServer) -> some View {
        Button { prefillServer = s } label: {
            HStack(spacing: 14) {
                IconChip(icon: "sparkle.magnifyingglass", tint: theme.success, size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(displayName(s)).font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.textPrimary)
                    Text("\(s.host):\(String(s.port)) · \(String(localized: "未配对"))").font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                }
                Spacer(minLength: 6)
                Image(systemName: "qrcode.viewfinder").font(.system(size: 18, weight: .semibold)).foregroundStyle(theme.accent)
            }
            .padding(16)
            .frame(minHeight: 92)
            .background(RoundedRectangle(cornerRadius: theme.radiusCard, style: .continuous).fill(theme.surface).raisedShadow(theme))
            .overlay(RoundedRectangle(cornerRadius: theme.radiusCard, style: .continuous).strokeBorder(theme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 动作 (逻辑不变)
    private var newlyDiscovered: [DiscoveredServer] {
        let saved = Set(store.computers.map(\.host).filter { !$0.isEmpty })
        return discovery.servers.filter { !saved.contains($0.host) }
    }

    private func selectAndConnect(_ id: UUID) {
        store.selectComputer(id)
        reconcileConnection()
    }

    /// 连接协调器入口: 选/编辑/删除电脑后都调它, 按「当前电脑」对齐 socket。
    /// 没有可连电脑就断开; 否则交给 `client.connect(to:)` —— 它幂等: 目标/配置没变不打断,
    /// 换了电脑或同一台改了地址/令牌/指纹就重连 (修审计 H-1/H-2: 不再向旧 socket 发键)。
    private func reconcileConnection() {
        guard let c = store.currentComputer, !c.host.isEmpty else {
            client.disconnect(); return
        }
        client.connect(to: c)
    }

    private func handlePaired(_ payload: PairingPayload) {
        let host = payload.hosts.first ?? ""
        let id = store.upsertComputer(name: host, host: host, port: payload.port, token: payload.token, fingerprint: payload.fp ?? "")
        selectAndConnect(id)
    }

    private func displayName(_ s: DiscoveredServer) -> String {
        s.name.replacingOccurrences(of: "Sidekey-", with: "")
            .replacingOccurrences(of: "-local", with: "")
    }

    private var statusColor: Color {
        switch client.status {
        case .connected:    return theme.success
        case .connecting:   return theme.warning
        case .failed:       return theme.danger
        case .disconnected: return theme.textTertiary
        }
    }
    private var statusText: String {
        switch client.status {
        case .disconnected:      return String(localized: "未连接")
        case .connecting:        return String(localized: "连接中…")
        case .connected:         return String(localized: "已连接")
        case .failed(let kind):  return kind.shortTitle   // 显示具体原因, 不再统一「连接失败」(审计 H-3)
        }
    }
}
