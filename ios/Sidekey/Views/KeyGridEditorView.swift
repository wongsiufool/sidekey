import SwiftUI

/// 网格编辑 (brief C2): 自绘分段表示页层; 珊瑚点阵画布; 选中键珊瑚描边 + 角落菜单; 浮动 pill 操作栏; 底部「新增按键」。
/// 清空 / 重置 / 列数 / 页序等放右上溢出菜单。位置 / 拖拽 / 缩放 / 碰撞沿用现有 Store。
struct KeyGridEditorView: View {
    @ObservedObject var store: LayoutStore
    @ObservedObject var client: SidekeyClient
    @Environment(\.dismiss) private var dismiss
    @Environment(\.sidekeyTheme) private var theme
    @Environment(\.screenKind) private var screenKind

    @State private var currentLayerID: String
    @State private var editingCap: KeyCap?
    @State private var selectedID: UUID?
    @State private var confirmingClear = false
    @State private var confirmingReset = false
    @State private var confirmingRegenerate = false
    /// 编辑目标在打开时锁定 (§4.8): 之后窗口换屏也继续编辑这一套。@State 只取第一次的初值。
    @State private var target: LayoutTarget

    init(store: LayoutStore, client: SidekeyClient, target: LayoutTarget, initialPage: String = "base") {
        _store = ObservedObject(wrappedValue: store)
        _client = ObservedObject(wrappedValue: client)
        _target = State(initialValue: target)
        _currentLayerID = State(initialValue: initialPage)
    }

    private var isLarge: Bool { target.set == .large }
    /// 在内屏上编辑原键位时的说明: 只要是这种情况就一直显示 (目标打开时已锁定, 不会自动切换), 原因随当前状态更新。
    private var originalOnInnerNote: String? {
        guard screenKind == .inner, target.set == .original else { return nil }
        switch store.largeUnavailableReason(computer: target.computer, mode: target.mode) {
        case .recovering?: return String(localized: "正在编辑原键位（大屏键位恢复中）")
        case .outOfBounds?: return String(localized: "正在编辑原键位：这套键位有超出范围的按键，不能生成大屏键位")
        case .notGridMode?: return String(localized: "正在编辑原键位：这个模式不使用大屏键位")
        case nil: return String(localized: "正在编辑原键位（大屏键位现在可以用了，关闭后重新打开即可编辑大屏键位）")
        }
    }
    private var pages: [KeyLayer] { store.layers(in: target) }
    private var modeName: String { store.mode(computer: target.computer, mode: target.mode).map { NSLocalizedString($0.name, comment: "") } ?? "" }
    private var pageIndex: Int { pages.firstIndex { $0.id == currentLayerID } ?? 0 }
    private var pageLabel: String { String(localized: "页 \(pageIndex + 1)") }
    private var layer: KeyLayer { store.layer(currentLayerID, in: target) ?? pages.first ?? KeyLayer(id: currentLayerID, columns: DefaultLayout.columns, keys: []) }
    /// 大屏编辑器: 按标准半折 N = 4 预览子页切线 (§4.8, 只是预览, 窗口更小时实际切得更细)。
    private var cutRows: [Int] {
        guard isLarge else { return [] }
        return SubpageSplitter.split(keys: layer.keys, totalRows: layer.rowCount, maxRows: 4).dropFirst().map(\.rows.lowerBound)
    }

    var body: some View {
        VStack(spacing: 12) {
            header
            if pages.count > 1 { pageSwitcher }
            ZStack(alignment: .bottom) {
                GridEditorView(
                    layer: layer,
                    selectedID: $selectedID,
                    canPlace: { id, c, r, cs, rs in
                        store.canPlace(layerID: currentLayerID, capID: id, col: c, row: r, colSpan: cs, rowSpan: rs, in: target)
                    },
                    onMove: { id, c, r in _ = store.moveKey(layerID: currentLayerID, capID: id, toCol: c, toRow: r, in: target) },
                    onResize: { id, cs, rs in _ = store.resizeKey(layerID: currentLayerID, capID: id, colSpan: cs, rowSpan: rs, in: target) },
                    onEdit: { cap in if cap.kind != .trackpad && cap.kind != .unknown { editingCap = cap } },   // 触控板没有可编辑属性, 不开属性表
                    cutRows: cutRows
                )
                if let sel = layer.keys.first(where: { $0.id == selectedID }) {
                    floatingToolbar(sel)
                        .padding(.bottom, 8)
                }
            }
            if isLarge { fixedZonePlaceholder }
            CoralButton(title: String(localized: "新增按键"), icon: "plus") {
                if let id = store.addKey(layerID: currentLayerID, in: target) { selectedID = id }
            }
        }
        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 16)
        .background(theme.bgGradient.ignoresSafeArea())
        .onChange(of: currentLayerID) { _ in selectedID = nil }
        .onChange(of: store.discardGeneration) { _ in editingCap = nil; dismiss() }     // 放弃未保存的修改: 编辑器还拿着被放弃的数据, 关掉 (不会把它重新应用)
        .sheet(item: $editingCap) { cap in
            KeyEditorView(
                cap: cap,
                client: client,
                onSave: { store.updateKey(layerID: currentLayerID, cap: $0, in: target) },
                onDelete: { store.deleteKey(layerID: currentLayerID, capID: cap.id, in: target); selectedID = nil }
            )
            .unsavedBanner(store)
        }
        .confirmationDialog("清空「\(pageLabel)」的所有按键?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("清空本页", role: .destructive) { store.clearLayer(id: currentLayerID, in: target); selectedID = nil }
            Button("取消", role: .cancel) {}
        } message: { Text(isLarge ? LocalizedStringKey("移除本页全部按键, 之后用「新增按键」从零添加。只影响大屏键位, 原键位不变。") : LocalizedStringKey("移除本页全部按键, 之后用「新增按键」从零添加。其它页与其它模式不受影响。")) }
        // §6.3: 重置二选一, 确认框写清楚影响范围
        .confirmationDialog("重置「\(modeName)」?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button(isLarge ? LocalizedStringKey("只重置大屏键位") : LocalizedStringKey("只重置原键位"), role: .destructive) { reset(.currentSet) }
            Button("两套都重置", role: .destructive) { reset(.both) }
            Button("取消", role: .cancel) {}
        } message: {
            Text(isLarge
                 ? LocalizedStringKey("只重置大屏键位: 按现在的原键位重新生成, 丢弃大屏键位上的编辑, 原键位不变。\n两套都重置: 原键位恢复初始布局, 大屏键位下次在内屏打开时按它重新生成。")
                 : LocalizedStringKey("只重置原键位: 原键位恢复初始布局, 大屏键位不变。\n两套都重置: 原键位恢复初始布局, 大屏键位下次在内屏打开时按它重新生成。"))
        }
        .confirmationDialog("从原键位重新生成大屏键位?", isPresented: $confirmingRegenerate, titleVisibility: .visible) {
            Button("重新生成", role: .destructive) { _ = store.regenerateLarge(computer: target.computer, mode: target.mode); currentLayerID = pages.first?.id ?? "base"; selectedID = nil }
            Button("取消", role: .cancel) {}
        } message: { Text("会用现在的原键位重新生成, 丢弃大屏键位上的所有编辑。原键位不变。") }
        .onAppear { fixCurrentPage(); applyDebugUI() }
        .onChange(of: pages.map(\.id)) { _ in fixCurrentPage() }   // 页被删 / 放弃修改 / 重新生成后, 当前页不在了就修正成实际存在的页
    }

    // MARK: - 顶栏
    private var header: some View {
        ZStack {
            // 标题本地化: 模式名显示时本地化(内置名→英文/自定义名原样), 「· 按键」后缀走 %@ 格式键。
            VStack(spacing: 1) {
                Text(modeName.isEmpty ? String(localized: "设置 · 按键") : String(localized: "\(modeName) · 按键"))
                    .font(.system(size: 17, weight: .semibold)).foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                if isLarge {
                    Text("正在编辑：大屏键位").font(.system(size: 12, weight: .medium)).foregroundStyle(theme.accentInk)
                        .accessibilityIdentifier("editingLargeLayout")
                } else if let note = originalOnInnerNote {
                    // 内屏上却在编辑原键位 (大屏键位恢复中 / 不能生成): 写清楚, 免得误以为在改大屏键位
                    Text(note).font(.system(size: 12, weight: .medium)).foregroundStyle(theme.warningText)
                        .multilineTextAlignment(.center).lineLimit(2)
                        .padding(.horizontal, 44)          // 让开左右两个按钮 (各 40 宽), 长说明换行而不是被盖住
                        .accessibilityIdentifier("editingOriginalOnInner")
                }
            }
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(theme.textSecondary).frame(width: 40, height: 40)
                }.buttonStyle(.plain).accessibilityIdentifier("editorBack")
                Spacer()
                Menu {
                    Button { if let id = store.addPage(in: target) { currentLayerID = id; selectedID = nil } } label: { Label("添加页", systemImage: "plus.rectangle.on.rectangle") }
                    if !isLarge {      // 大屏键位: 触控板和鼠标键在固定区域, 第一版不能在网格里加 (§4.8)
                        Button { if let id = store.addTrackpad(layerID: currentLayerID, in: target) { selectedID = id } } label: { Label("加触控板", systemImage: "hand.point.up.left") }
                        Button { if let id = store.addMouseButton(layerID: currentLayerID, code: "left", in: target) { selectedID = id } } label: { Label("加左键", systemImage: "cursorarrow.click") }
                        Button { if let id = store.addMouseButton(layerID: currentLayerID, code: "right", in: target) { selectedID = id } } label: { Label("加右键", systemImage: "cursorarrow.rays") }
                    }
                    Button { store.addColumn(layerID: currentLayerID, in: target) } label: { Label("网格列数 +1 (当前 \(layer.columns))", systemImage: "plus.square") }
                        .disabled(!store.canAddColumn(layerID: currentLayerID, in: target))   // 编辑器最多加到 16 列 (1.0 行为)
                    Button { store.removeColumn(layerID: currentLayerID, in: target) } label: { Label("网格列数 −1", systemImage: "minus.square") }
                    if pages.count > 1 {
                        Button { _ = store.movePage(id: currentLayerID, by: -1, in: target) } label: { Label("本页前移", systemImage: "arrow.left") }
                        Button { _ = store.movePage(id: currentLayerID, by: 1, in: target) } label: { Label("本页后移", systemImage: "arrow.right") }
                    }
                    Divider()
                    Button(role: .destructive) { confirmingClear = true } label: { Label("清空本页", systemImage: "xmark.square") }
                    if currentLayerID != "base" {
                        Button(role: .destructive) { let id = currentLayerID; currentLayerID = "base"; store.deleteLayer(id: id, in: target) } label: { Label("删除本页", systemImage: "trash") }
                    }
                    if isLarge {
                        Button(role: .destructive) { confirmingRegenerate = true } label: { Label("从原键位重新生成", systemImage: "arrow.triangle.2.circlepath") }
                    }
                    Button(role: .destructive) { confirmingReset = true } label: { Label("重置本模式", systemImage: "arrow.counterclockwise") }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(theme.textSecondary).frame(width: 40, height: 40)
                        .background(Circle().fill(theme.surfaceMuted))
                }.accessibilityIdentifier("editorMenu")
            }
        }
        .frame(height: 44)
    }

    @ViewBuilder private var pageSwitcher: some View {
        let ls = pages
        if ls.count == 2 {
            SoftSegmentedControl(
                items: [(title: String(localized: "主页 · 输入"), tag: ls[0].id), (title: String(localized: "第 2 页 · 快捷"), tag: ls[1].id)],
                selection: Binding(get: { ls.contains { $0.id == currentLayerID } ? currentLayerID : ls[0].id },
                                   set: { currentLayerID = $0; selectedID = nil })
            )
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(ls.enumerated()), id: \.element.id) { idx, l in
                        let sel = l.id == currentLayerID
                        Text("页 \(idx + 1)")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(sel ? theme.accentInk : theme.textSecondary)
                            .padding(.horizontal, 16).frame(height: 36)
                            .background(Capsule().fill(sel ? theme.accentLight : theme.surfaceMuted))
                            .onTapGesture { currentLayerID = l.id; selectedID = nil }
                    }
                }
            }
        }
    }

    /// 浮在画布底部的近白操作栏 (编辑 / 复制 / 删除)。
    private func floatingToolbar(_ cap: KeyCap) -> some View {
        HStack(spacing: 20) {
            if cap.kind != .trackpad && cap.kind != .unknown {   // 触控板: 没有可编辑属性, 也不复制(一页只放一个), 只留删除; 未知类型占位键同理
                toolBtn("pencil", String(localized: "编辑")) { editingCap = cap }
                toolBtn("plus.square.on.square", String(localized: "复制")) {
                    if let id = store.duplicateKey(layerID: currentLayerID, capID: cap.id, in: target) { selectedID = id }
                }
            }
            toolBtn("trash", String(localized: "删除"), danger: true) {
                store.deleteKey(layerID: currentLayerID, capID: cap.id, in: target); selectedID = nil
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(Capsule().fill(theme.surface).raisedShadow(theme))
        .overlay(Capsule().strokeBorder(theme.hairline, lineWidth: 1))
    }

    /// 大屏键位的固定区域 (§4.8): 触控板区和这个模式唯一的一组鼠标键, 灰色占位, 第一版不能拖动、改大小、增删或改属性。
    private var fixedZonePlaceholder: some View {
        let mice = store.largeLayout(computer: target.computer, mode: target.mode)?.mouseButtons ?? []
        return HStack(spacing: 8) {
            Label("触控板区", systemImage: "hand.point.up.left")
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(RoundedRectangle(cornerRadius: 10).fill(theme.surfaceMuted))
            ForEach(mice) { m in
                Text(NSLocalizedString(m.label, comment: ""))
                    .frame(width: 64, height: 36)
                    .background(RoundedRectangle(cornerRadius: 10).fill(theme.surfaceMuted))
            }
        }
        .font(.system(size: 13, weight: .medium)).foregroundStyle(theme.textSecondary)
        .overlay(alignment: .topTrailing) {
            Text("固定区域 · 不能编辑").font(.system(size: 10)).foregroundStyle(theme.hint).offset(y: -14)
        }
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("largeFixedZone")
    }

    /// 画布显示的页和操作的页必须是同一个: 当前页 id 在这套键位里不存在时 (例如从主界面带进来的页在大屏键位里没有), 修正成第一页。
    private func fixCurrentPage() {
        guard !pages.contains(where: { $0.id == currentLayerID }), let first = pages.first else { return }
        currentLayerID = first.id
        selectedID = nil
    }

    private func reset(_ scope: LayoutStore.ResetScope) {
        store.resetMode(target, scope: scope)
        currentLayerID = pages.first?.id ?? "base"
        selectedID = nil
        // 两套都重置后大屏键位回到「还没生成」: 这个编辑器编辑的那套已不存在, 关掉 (下次在内屏打开会重新生成)
        if isLarge && scope == .both { dismiss() }
    }

    private func toolBtn(_ icon: String, _ label: String, danger: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon).font(.system(size: 17, weight: .medium))
                Text(label).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(danger ? theme.dangerText : theme.textSecondary)
        }.buttonStyle(.plain)
    }

    private func applyDebugUI() {
        let args = DebugArgs.all
        if args.contains("--editkey") || args.contains("--codepicker") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { editingCap = layer.keys.first }
        }
        if args.contains("--selectkey") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { selectedID = layer.keys.first?.id }
        }
    }
}
