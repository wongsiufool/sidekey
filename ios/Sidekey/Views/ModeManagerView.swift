import SwiftUI

/// 模式管理 (brief C1): 纵向模式卡 (图标 / 名称 / 状态 pill / ⋯菜单 / 2×2 预览 / 按键数); 右上珊瑚加号。
struct ModeManagerView: View {
    @ObservedObject var store: LayoutStore
    var onSelect: (UUID) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.sidekeyTheme) private var theme

    @State private var renamingID: UUID?
    @State private var renameText = ""
    @State private var addingMode = false
    @State private var newModeName = ""

    private let icons = ["cube.fill", "briefcase.fill", "display", "macwindow", "keyboard", "wand.and.stars"]
    private var modes: [Mode] { store.currentComputer?.modes ?? [] }
    private var otherComputers: [Computer] { store.computers.filter { $0.id != store.currentComputerID } }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(brandCenter: true, trailingIcon: "plus", trailingFilled: true,
                        trailingId: "addModeButton", onTrailing: { addingMode = true })
                .padding(.horizontal, 20)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SectionTitle(text: String(localized: "模式")).padding(.top, 4)
                    ForEach(Array(modes.enumerated()), id: \.element.id) { idx, m in
                        modeCard(m, idx: idx)
                    }
                    Text("在 ⚙️ 编辑里可改每个模式的按键。")
                        .font(.system(size: 12)).foregroundStyle(theme.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .center).padding(.top, 4)
                }
                .padding(.horizontal, 20).padding(.bottom, 16)
            }
        }
        .background(theme.bgGradient.ignoresSafeArea())
        .presentationDetents([.large])
        .alert("重命名模式", isPresented: renamingBinding) {
            TextField("模式名称", text: $renameText).autocorrectionDisabled()
            Button("保存") { if let id = renamingID { store.renameMode(id: id, to: renameText) }; renamingID = nil }
            Button("取消", role: .cancel) { renamingID = nil }
        }
        .alert("新建模式", isPresented: $addingMode) {
            TextField("模式名称, 如 工作", text: $newModeName).autocorrectionDisabled()
            Button("创建") {
                if let id = store.addMode(named: newModeName) { store.selectMode(id); onSelect(id) }
                newModeName = ""
            }
            Button("取消", role: .cancel) { newModeName = "" }
        } message: {
            Text("新模式会带一套默认按键, 之后在 ⚙️ 设置里改。")
        }
    }

    private func modeCard(_ m: Mode, idx: Int) -> some View {
        let isCurrent = m.id == store.currentModeID
        let keyCount = m.layers.reduce(0) { $0 + $1.keys.count }
        let preview = Array((m.layers.first?.keys ?? []).prefix(4))
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                IconChip(icon: icons[idx % icons.count], tint: isCurrent ? theme.accent : theme.textSecondary, size: 40)
                Text(NSLocalizedString(m.name, comment: "")).font(.system(size: 17, weight: .semibold)).foregroundStyle(theme.textPrimary)  // 内置模式名显示时本地化; 自定义名原样
                if isCurrent { StatusPill(text: String(localized: "当前使用"), emphasized: true) }
                Spacer(minLength: 4)
                Menu {
                    Button { renamingID = m.id; renameText = m.name } label: { Label("重命名", systemImage: "pencil") }
                    Button { store.duplicateMode(id: m.id) } label: { Label("复制", systemImage: "doc.on.doc") }
                    if !otherComputers.isEmpty {
                        Menu("复制到其它电脑") {
                            ForEach(otherComputers) { c in
                                Button(c.name) { store.duplicateMode(id: m.id, toComputer: c.id) }
                            }
                        }
                    }
                    if modes.count > 1 {
                        Button(role: .destructive) { store.deleteMode(id: m.id) } label: { Label("删除", systemImage: "trash") }
                    }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(theme.textTertiary).frame(width: 32, height: 32)
                }
            }
            HStack(spacing: 8) {
                ForEach(preview) { k in
                    // 显示时本地化 key label(和 KeyCapButton 的 loc()/编辑器一致); 否则英文设备会露中文「触控板/左键」等
                    SoftKeyChip(label: (k.icon == nil ? (k.label.isEmpty ? nil : NSLocalizedString(k.label, comment: "")) : nil),
                                icon: k.icon, fill: theme.surfaceMuted, width: 46, height: 34)
                }
                Spacer(minLength: 0)
            }
            HStack {
                Text("\(keyCount) 个快捷键").font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.textTertiary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: theme.radiusCard, style: .continuous)
            .fill(isCurrent ? theme.accentLight.opacity(0.45) : theme.surface).raisedShadow(theme))
        .overlay(RoundedRectangle(cornerRadius: theme.radiusCard, style: .continuous)
            .strokeBorder(isCurrent ? theme.accent : theme.hairline, lineWidth: isCurrent ? 1.5 : 1))
        .contentShape(Rectangle())
        .onTapGesture { store.selectMode(m.id); onSelect(m.id); dismiss() }
    }

    private var renamingBinding: Binding<Bool> {
        Binding(get: { renamingID != nil }, set: { if !$0 { renamingID = nil } })
    }
}
