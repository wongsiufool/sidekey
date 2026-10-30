import SwiftUI

/// 「有修改未保存」状态条 (v1.8 §6.4 第 7 条): 存档写不进去 (超出读取上限等) 时, 修改保留在内存、界面照常按新数据工作,
/// 持续显示本条, **不能手动关掉**, 只有保存成功或「放弃修改」后才消失。
/// 顶部内缩 (safeAreaInset), 根视图和所有会改存档的弹窗 / 编辑器 / 嵌套弹窗各挂一份, 嵌套时只有最上层可见。
/// - 配色: 底用 `surface`、字用 `textPrimary`, 警告色只用在图标和下边线 (非文字)。
/// - 主题: 自己从 `ThemeManager` + 当前系统明暗解析 (不依赖外层注入的环境, 弹窗里也和所在界面同一套主题, 含苹果风暗夜)。
/// - 高度上限 (v1.8 补充): 状态条再高也要给输入区留出最低空间 (`minInputHeight`, 单区含鼠标键 160 × 144), 说明文字超出就收进可滚动区,
///   两个按钮始终可见、命中区 ≥ 44; 最大动态字号下同样成立 (按钮字号封顶, 说明文字滚动)。
private struct UnsavedBannerContent: ViewModifier {
    @ObservedObject var store: LayoutStore
    /// 根视图上的那一份: 把自己的高度报给 `UnsavedBannerLayout`, 让根视图按完整窗口判断方向。
    var isRoot = false
    @ObservedObject private var themeManager = AppEnvironment.shared.themeManager
    @ObservedObject private var layout = AppEnvironment.shared.bannerLayout
    @Environment(\.colorScheme) private var systemScheme
    @State private var containerHeight: CGFloat = .infinity
    @State private var textNaturalHeight: CGFloat = 0
    @State private var confirmingDiscard = false
    @State private var showingDetail = false
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var theme: SidekeyTheme { themeManager.theme(system: systemScheme) }

    /// 给输入区留的最低高度: 单区「触控板 80 + 鼠标键行 56 + 行距 8」= 144, 再加横屏主体上下各 8 的留白 = 160 (按真实输入区算, 不是只算 144)。
    static let minInputHeight: CGFloat = PhoneLandscape.minTrackpadHeight + PhoneLandscape.mouseRowHeight + PhoneLandscape.rowGap + 2 * ContentView.landscapeVPadding
    /// 状态条里除了说明文字之外固定占的高度 (上下内边距 + 按钮行 + 间距 + 下边线)。
    private static let chromeHeight: CGFloat = 8 + 8 + 44 + 4 + 3

    /// 给输入区留的最低高度: 横屏 = `minInputHeight`; 竖屏 = 当前布局真实的外围控件高度 (顶栏、分页条、底栏、内边距) + 键盘区最低高度。
    private var inputBudget: CGFloat {
        if let nonInput = layout.portraitNonInput { return nonInput + ContentView.portraitMinPagerHeight }
        return Self.minInputHeight
    }
    private var textMaxHeight: CGFloat {
        containerHeight - inputBudget - Self.chromeHeight
    }
    /// 窗口实在太小 (留给说明文字的高度不足一行): 收到最小, 只留标题一行 + 两个按钮; 仍给不出最低输入区时输入区自己显示「窗口太小」占位。
    /// 弹窗 / 编辑器里 (非根视图) 在竖向紧凑 (手机横屏) 时也收成一行: 弹窗内容 (编辑表单、键位网格) 比主界面更需要高度。
    private var compact: Bool { textMaxHeight < 40 || (!isRoot && verticalSizeClass == .compact) }

    /// 按钮: 字用 `textPrimary`, 描边 `accentInk`, 底 `surface`; 命中区 ≥ 44; 字号封顶 (按钮始终放得下)。
    private func bannerButton(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.subheadline.weight(.bold)).foregroundColor(theme.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.7)
                .padding(.horizontal, 14).frame(minHeight: 44)
                .background(Capsule().strokeBorder(theme.accentInk, lineWidth: 1.5))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var texts: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(theme.warningText)
                Text("有修改未保存：键位数据太大，写不进存档。App 被关闭后，这些修改会丢失。")
                    .font(.footnote.weight(.semibold))
                    .lineLimit(compact ? 1 : nil)
            }
            if !compact {
                Text("未保存期间新配对、改过连接信息或删掉的电脑也只在内存里，关闭后会恢复原样，新配对的电脑需要重新配对。")
                    .font(.caption)
            }
        }
        .foregroundColor(theme.textPrimary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                if store.hasUnsavedChanges && compact {
                    // 窗口实在太小 (例如横屏 + 系统键盘): 收成一行 —— 标题 (一行、字号封顶) + 两个按钮, 给下面的表单 / 输入区留出视口
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundColor(theme.warningText)
                        Text("有修改未保存：键位数据太大，写不进存档。App 被关闭后，这些修改会丢失。")
                            .font(.footnote.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        // 收起的说明文字: 点开看全文 (命中区 ≥ 44)
                        Button { showingDetail = true } label: {
                            Image(systemName: "info.circle").font(.system(size: 18)).foregroundColor(theme.textPrimary)
                                .frame(width: 44, height: 44).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("未保存说明"))
                        bannerButton("重试保存") { store.retryUnsavedSave() }
                        bannerButton("放弃修改") { confirmingDiscard = true }
                    }
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .foregroundColor(theme.textPrimary)
                    .padding(.horizontal, 12).padding(.vertical, 4)
                    .alert("有修改未保存", isPresented: $showingDetail) {
                        Button("好", role: .cancel) {}
                    } message: {
                        Text("键位数据太大，写不进存档。App 被关闭后，这些修改会丢失。未保存期间新配对、改过连接信息或删掉的电脑也只在内存里，关闭后会恢复原样，新配对的电脑需要重新配对。")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.surface)
                    .overlay(alignment: .bottom) { Rectangle().fill(theme.warning).frame(height: 3) }
                    .background(GeometryReader { g in
                        Color.clear
                            .onAppear { if isRoot { AppEnvironment.shared.bannerLayout.rootHeight = g.size.height } }
                            .onChange(of: g.size.height) { h in if isRoot { AppEnvironment.shared.bannerLayout.rootHeight = h } }
                    })
                    .onDisappear { if isRoot { AppEnvironment.shared.bannerLayout.rootHeight = 0 } }
                    .environment(\.sidekeyTheme, theme)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("unsavedBanner")
                    .confirmationDialog("放弃所有未保存的修改，恢复到上一次保存的内容？", isPresented: $confirmingDiscard, titleVisibility: .visible) {
                        Button("放弃修改", role: .destructive) { store.discardUnsavedChanges() }
                        Button("取消", role: .cancel) {}
                    }
                } else if store.hasUnsavedChanges {
                    VStack(alignment: .leading, spacing: 4) {
                        // 放得下就按内容高度显示 (量出说明文字的自然高度); 放不下 (最大字号 / 矮窗口) 就收进定高的可滚动区, 按钮不受影响
                        ScrollView(.vertical, showsIndicators: !compact && textNaturalHeight > textMaxHeight) {
                            texts.background(GeometryReader { g in
                                Color.clear.onAppear { textNaturalHeight = g.size.height }.onChange(of: g.size.height) { textNaturalHeight = $0 }
                            })
                        }
                        .frame(height: compact ? max(textNaturalHeight, 1) : min(max(textNaturalHeight, 1), textMaxHeight))
                        HStack(spacing: 8) {
                            bannerButton("重试保存") { store.retryUnsavedSave() }
                            bannerButton("放弃修改") { confirmingDiscard = true }
                        }
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.surface)
                    .overlay(alignment: .bottom) { Rectangle().fill(theme.warning).frame(height: 3) }
                    .background(GeometryReader { g in
                        Color.clear
                            .onAppear { if isRoot { AppEnvironment.shared.bannerLayout.rootHeight = g.size.height } }
                            .onChange(of: g.size.height) { h in if isRoot { AppEnvironment.shared.bannerLayout.rootHeight = h } }
                    })
                    .onDisappear { if isRoot { AppEnvironment.shared.bannerLayout.rootHeight = 0 } }
                    .environment(\.sidekeyTheme, theme)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("unsavedBanner")
                    .confirmationDialog("放弃所有未保存的修改，恢复到上一次保存的内容？", isPresented: $confirmingDiscard, titleVisibility: .visible) {
                        Button("放弃修改", role: .destructive) { store.discardUnsavedChanges() }
                        Button("取消", role: .cancel) {}
                    }
                }
            }
            // 测量整个容器 (含状态条) 的高度, 用来算状态条的上限
            .background(GeometryReader { g in Color.clear.onAppear { containerHeight = g.size.height }.onChange(of: g.size.height) { containerHeight = $0 } })
    }
}

extension View {
    /// 根视图用: 同时把状态条高度报给根视图 (按完整窗口判断方向)。
    func unsavedBanner(_ store: LayoutStore, isRoot: Bool = false) -> some View { modifier(UnsavedBannerContent(store: store, isRoot: isRoot)) }
    /// 嵌套弹窗用: 存储是 App 级单例, 直接取 (环境注入在嵌套 sheet 里拿不到, 真实挂载测试已验证)。
    /// 局限: 绑定单例, 不便于测试 / 预览 / 多 store 注入 (M1 只有一个 store, 延后)。
    func unsavedBanner() -> some View { modifier(UnsavedBannerContent(store: AppEnvironment.shared.store)) }
}
