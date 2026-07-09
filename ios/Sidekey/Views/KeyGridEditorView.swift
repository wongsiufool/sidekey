import SwiftUI

/// 网格编辑 (brief C2): 自绘分段表示页层; 珊瑚点阵画布; 选中键珊瑚描边 + 角落菜单; 浮动 pill 操作栏; 底部「新增按键」。
/// 清空 / 重置 / 列数 / 页序等放右上溢出菜单。位置 / 拖拽 / 缩放 / 碰撞沿用现有 Store。
struct KeyGridEditorView: View {
    @ObservedObject var store: LayoutStore
    @ObservedObject var client: SidekeyClient
    @Environment(\.dismiss) private var dismiss
    @Environment(\.sidekeyTheme) private var theme

    @State private var currentLayerID: String
    @State private var editingCap: KeyCap?
    @State private var selectedID: UUID?
    @State private var confirmingClear = false
    @State private var confirmingReset = false

    init(store: LayoutStore, client: SidekeyClient, initialPage: String = "base") {
        _store = ObservedObject(wrappedValue: store)
        _client = ObservedObject(wrappedValue: client)
        _currentLayerID = State(initialValue: initialPage)
    }

    private var pageIndex: Int { store.layers.firstIndex { $0.id == currentLayerID } ?? 0 }
    private var pageLabel: String { String(localized: "页 \(pageIndex + 1)") }
    private var layer: KeyLayer { store.layer(currentLayerID) ?? store.layers.first ?? DefaultLayout.base }

    var body: some View {
        VStack(spacing: 12) {
            header
            if store.layers.count > 1 { pageSwitcher }
            ZStack(alignment: .bottom) {
                GridEditorView(
                    layer: layer,
                    selectedID: $selectedID,
                    canPlace: { id, c, r, cs, rs in
                        store.canPlace(layerID: currentLayerID, capID: id, col: c, row: r, colSpan: cs, rowSpan: rs)
                    },
                    onMove: { id, c, r in _ = store.moveKey(layerID: currentLayerID, capID: id, toCol: c, toRow: r) },
                    onResize: { id, cs, rs in _ = store.resizeKey(layerID: currentLayerID, capID: id, colSpan: cs, rowSpan: rs) },
                    onEdit: { cap in if cap.kind != .trackpad { editingCap = cap } }   // 触控板没有可编辑属性, 不开属性表
                )
                if let sel = layer.keys.first(where: { $0.id == selectedID }) {
                    floatingToolbar(sel)
                        .padding(.bottom, 8)
                }
            }
            CoralButton(title: String(localized: "新增按键"), icon: "plus") {
                if let id = store.addKey(layerID: currentLayerID) { selectedID = id }
            }
        }
        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 16)
        .background(theme.bgGradient.ignoresSafeArea())
        .onChange(of: currentLayerID) { _ in selectedID = nil }
        .sheet(item: $editingCap) { cap in
            KeyEditorView(
                cap: cap,
                client: client,
                onSave: { store.updateKey(layerID: currentLayerID, cap: $0) },
                onDelete: { store.deleteKey(layerID: currentLayerID, capID: cap.id); selectedID = nil }
            )
        }
        .confirmationDialog("清空「\(pageLabel)」的所有按键?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("清空本页", role: .destructive) { store.clearLayer(id: currentLayerID); selectedID = nil }
            Button("取消", role: .cancel) {}
        } message: { Text("移除本页全部按键, 之后用「新增按键」从零添加。其它页与其它模式不受影响。") }
        .confirmationDialog("把「\(store.currentMode?.name ?? "")」重置为初始布局?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("重置本模式", role: .destructive) { store.resetCurrentModeLayout(); currentLayerID = "base"; selectedID = nil }
            Button("取消", role: .cancel) {}
        } message: { Text("会丢弃本模式当前所有页/键的编辑, 恢复成它的初始布局。其它模式不受影响。") }
        .onAppear(perform: applyDebugUI)
    }

    // MARK: - 顶栏
    private var header: some View {
        ZStack {
            // 标题本地化: 模式名显示时本地化(内置名→英文/自定义名原样), 「· 按键」后缀走 %@ 格式键。
            Text(store.currentMode.map { String(localized: "\(NSLocalizedString($0.name, comment: "")) · 按键") } ?? String(localized: "设置 · 按键"))
                .font(.system(size: 17, weight: .semibold)).foregroundStyle(theme.textPrimary)
                .lineLimit(1)
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(theme.textSecondary).frame(width: 40, height: 40)
                }.buttonStyle(.plain)
                Spacer()
                Menu {
                    Button { if let id = store.addPage() { currentLayerID = id; selectedID = nil } } label: { Label("添加页", systemImage: "plus.rectangle.on.rectangle") }
                    Button { if let id = store.addTrackpad(layerID: currentLayerID) { selectedID = id } } label: { Label("加触控板", systemImage: "hand.point.up.left") }
                    Button { if let id = store.addMouseButton(layerID: currentLayerID, code: "left") { selectedID = id } } label: { Label("加左键", systemImage: "cursorarrow.click") }
                    Button { if let id = store.addMouseButton(layerID: currentLayerID, code: "right") { selectedID = id } } label: { Label("加右键", systemImage: "cursorarrow.rays") }
                    Button { store.addColumn(layerID: currentLayerID) } label: { Label("网格列数 +1 (当前 \(layer.columns))", systemImage: "plus.square") }
                    Button { store.removeColumn(layerID: currentLayerID) } label: { Label("网格列数 −1", systemImage: "minus.square") }
                    if store.layers.count > 1 {
                        Button { _ = store.movePage(id: currentLayerID, by: -1) } label: { Label("本页前移", systemImage: "arrow.left") }
                        Button { _ = store.movePage(id: currentLayerID, by: 1) } label: { Label("本页后移", systemImage: "arrow.right") }
                    }
                    Divider()
                    Button(role: .destructive) { confirmingClear = true } label: { Label("清空本页", systemImage: "xmark.square") }
                    if currentLayerID != "base" {
                        Button(role: .destructive) { let id = currentLayerID; currentLayerID = "base"; store.deleteLayer(id: id) } label: { Label("删除本页", systemImage: "trash") }
                    }
                    Button(role: .destructive) { confirmingReset = true } label: { Label("重置本模式", systemImage: "arrow.counterclockwise") }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(theme.textSecondary).frame(width: 40, height: 40)
                        .background(Circle().fill(theme.surfaceMuted))
                }
            }
        }
        .frame(height: 44)
    }

    @ViewBuilder private var pageSwitcher: some View {
        let ls = store.layers
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
                            .foregroundStyle(sel ? theme.accent : theme.textSecondary)
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
            if cap.kind != .trackpad {   // 触控板: 没有可编辑属性, 也不复制(一页只放一个), 只留删除
                toolBtn("pencil", String(localized: "编辑")) { editingCap = cap }
                toolBtn("plus.square.on.square", String(localized: "复制")) {
                    if let id = store.duplicateKey(layerID: currentLayerID, capID: cap.id) { selectedID = id }
                }
            }
            toolBtn("trash", String(localized: "删除"), danger: true) {
                store.deleteKey(layerID: currentLayerID, capID: cap.id); selectedID = nil
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(Capsule().fill(theme.surface).raisedShadow(theme))
        .overlay(Capsule().strokeBorder(theme.hairline, lineWidth: 1))
    }

    private func toolBtn(_ icon: String, _ label: String, danger: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon).font(.system(size: 17, weight: .medium))
                Text(label).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(danger ? theme.danger : theme.textSecondary)
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
