import SwiftUI
import UIKit

/// 外观 (brief D2): 三风格卡横排(2×2 预览) + 自绘明暗分段 + 珊瑚开关。仅「柔光珊瑚」用本套 token; 另两张是现有主题缩略。
struct SettingsView: View {
    @ObservedObject var themeManager: ThemeManager
    @ObservedObject var store: LayoutStore
    @ObservedObject var client: SidekeyClient
    /// 键位编辑器的目标 (所在窗口按屏幕决定原键位 / 大屏键位, §4.8); nil = 当前模式的原键位。
    /// 可能生成并保存大屏键位: 只在点击「按键」时调用一次, 结果存进 keyEditorTarget。
    var editTarget: (() -> LayoutTarget)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.screenKind) private var screenKind
    @State private var keyEditorTarget: LayoutTarget?
    @AppStorage(InnerStatusBar.key) private var innerShowStatusBar = false

    private var keyEditor: some View {
        KeyGridEditorView(store: store, client: client, target: keyEditorTarget ?? store.currentTarget, initialPage: "base").unsavedBanner(store)
            .environment(\.screenKind, screenKind)   // 显式传所在窗口的屏幕上下文 (sheet 不一定继承)
            .statusBarHidden(screenKind == .inner && !innerShowStatusBar)
    }
    @Environment(\.colorScheme) private var systemScheme
    @State private var showKeyEditor = false
    @State private var showLargeRecovery = false
    @State private var showSetupGuide = false          // 设置页也能重开「连接电脑 · 装小助手」引导
    @State private var showAbout = false               // 关于页
    #if DEBUG
    @State private var showDuoProbe = false            // iPhone Duo M0 测量页 (仅 DEBUG)
    #endif
    /// 触控板顺滑度 (指针速度倍率)。TrackpadView 读同一个 key 实时生效。
    @AppStorage("sidekey.trackpad.speed") private var trackpadSpeed: Double = TrackpadTuning.defaultSpeed
    /// 滚动速度倍率。TrackpadView 读同一个 key 实时生效。
    @AppStorage("sidekey.scroll.speed") private var scrollSpeed: Double = TrackpadTuning.scrollDefaultSpeed

    private var theme: SidekeyTheme { themeManager.theme(system: systemScheme) }
    private var speedWord: String {
        switch trackpadSpeed {
        case ..<2.0:  return String(localized: "慢 · 精确")
        case ..<3.2:  return String(localized: "适中")
        case ..<4.2:  return String(localized: "快")
        default:      return String(localized: "很快")
        }
    }

    private var scrollSpeedWord: String {
        switch scrollSpeed {
        case ..<3.0:  return String(localized: "慢 · 精确")
        case ..<5.0:  return String(localized: "适中")
        case ..<7.0:  return String(localized: "快")
        default:      return String(localized: "很快")
        }
    }

    private let styles: [(style: SidekeyStyle, name: String)] = [
        (.fresh, String(localized: "柔光珊瑚")), (.minimal, String(localized: "云雾灰")), (.lively, String(localized: "午夜深蓝")),
        (.apple, String(localized: "苹果风")),
    ]

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(brandCenter: true, onClose: { dismiss() }).padding(.horizontal, 20)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("键盘").font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.textPrimary)
                        .padding(.top, 4)
                    SoftPanel(padding: 0) {
                        Button { keyEditorTarget = editTarget?() ?? store.currentTarget; showKeyEditor = true } label: {
                            HStack(spacing: 12) {
                                Text("编辑当前模式的按键").font(.system(size: 16)).foregroundStyle(theme.textPrimary)
                                Spacer(minLength: 8)
                                Text(NSLocalizedString(store.currentMode?.name ?? "", comment: ""))  // 内置模式名显示时本地化; 自定义名原样
                                    .font(.system(size: 14)).foregroundStyle(theme.textSecondary).lineLimit(1)
                                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(theme.hint)
                            }
                            .padding(.horizontal, 16).frame(minHeight: 56)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(store.currentMode?.kind == .laptopKeyboard)      // 笔记本键盘键位固定, 不进网格编辑器 (§4.9)
                        .opacity(store.currentMode?.kind == .laptopKeyboard ? 0.45 : 1)
                        .accessibilityIdentifier("editKeysRow")
                    }
                    if store.currentMode?.kind == .laptopKeyboard {
                        Text("笔记本键盘的键位是固定的，不能编辑。").font(.system(size: 12)).foregroundStyle(theme.hint)
                    }
                    if store.largeRecovery != nil {
                        // 大屏键位读不出来 (§6.4 第 5 条) 的处理入口: 导出原始数据, 或丢弃后重新生成
                        SoftPanel(padding: 0) {
                            Button { showLargeRecovery = true } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(theme.warning)
                                    Text("大屏键位读不出来").font(.system(size: 16)).foregroundStyle(theme.textPrimary)
                                    Spacer(minLength: 8)
                                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.hint)
                                }
                                .padding(.horizontal, 16).frame(minHeight: 56)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("largeRecoveryRow")
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        SectionTitle(text: String(localized: "外观"))
                        Text("让 Sidekey 更懂你 — 选一套风格与明暗。")
                            .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                    }

                    HStack(spacing: 12) {
                        ForEach(styles, id: \.style) { s in styleCard(s.style, name: s.name) }
                    }

                    // 明暗模式: 并入上面同一个「外观」区(去掉重复的「外观」标题)。风格=配色, 明暗=浅/深, 两者正交。
                    SoftSegmentedControl(
                        items: [(title: String(localized: "浅色"), tag: SidekeyAppearance.light),
                                (title: String(localized: "深色"), tag: SidekeyAppearance.dark),
                                (title: String(localized: "跟随系统"), tag: SidekeyAppearance.system)],
                        selection: $themeManager.appearance
                    )

                    // 内屏显示状态栏 (§4 开头): 只在 iPhone Duo 内屏上出现; 默认关 = 内屏隐藏系统状态栏
                    if screenKind == .inner {
                        SoftPanel(padding: 0) {
                            Toggle(isOn: $innerShowStatusBar) {
                                Text("内屏显示状态栏").font(.system(size: 16)).foregroundStyle(theme.textPrimary)
                            }
                            .tint(theme.accent)
                            .padding(.horizontal, 16).frame(height: 56)
                            .accessibilityIdentifier("innerStatusBarToggle")
                        }
                        Text("关(默认): 内屏上隐藏时间、电量这一栏, 把空间留给键盘和触控板。外屏不受影响。")
                            .font(.system(size: 12)).foregroundStyle(theme.hint)
                    }

                    Text("Agent 状态灯").font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.textPrimary)
                    SoftPanel(padding: 0) {
                        VStack(spacing: 0) {
                            Toggle(isOn: $themeManager.statusLightOn) {
                                Text("显示状态灯").font(.system(size: 16)).foregroundStyle(theme.textPrimary)
                            }
                            .tint(theme.accent)
                            .padding(.horizontal, 16).frame(height: 56)

                            if themeManager.statusLightOn {
                                RowDivider(inset: 16)
                                Toggle(isOn: $themeManager.statusDeep) {
                                    Text("深度检测 (识别卡住 / 出错)").font(.system(size: 16)).foregroundStyle(theme.textPrimary)
                                }
                                .tint(theme.accent)
                                .padding(.horizontal, 16).frame(minHeight: 56)
                            }
                        }
                    }
                    if themeManager.statusLightOn {
                        Text("关(默认): 只看会话文件的「改动时间」判断在忙/该你了, 不读对话内容。开: 额外读最近会话尾部, 识别「卡住/出错」+ 项目名 — 仅在电脑本机进行。")
                            .font(.system(size: 12)).foregroundStyle(theme.hint)
                    }

                    Text("触控板").font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.textPrimary)
                    SoftPanel(padding: 0) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("顺滑度").font(.system(size: 16)).foregroundStyle(theme.textPrimary)
                                Spacer()
                                Text(speedWord).font(.system(size: 13, weight: .medium)).foregroundStyle(theme.accentInk)
                            }
                            HStack(spacing: 12) {
                                Image(systemName: "tortoise.fill").font(.system(size: 13)).foregroundStyle(theme.textTertiary)
                                Slider(value: $trackpadSpeed, in: TrackpadTuning.minSpeed...TrackpadTuning.maxSpeed)
                                    .tint(theme.accent)
                                    .accessibilityIdentifier("trackpadSpeedSlider")
                                Image(systemName: "hare.fill").font(.system(size: 13)).foregroundStyle(theme.textTertiary)
                            }
                            Divider()
                            HStack {
                                Text("滚动速度").font(.system(size: 16)).foregroundStyle(theme.textPrimary)
                                Spacer()
                                Text(scrollSpeedWord).font(.system(size: 13, weight: .medium)).foregroundStyle(theme.accentInk)
                            }
                            HStack(spacing: 12) {
                                Image(systemName: "tortoise.fill").font(.system(size: 13)).foregroundStyle(theme.textTertiary)
                                Slider(value: $scrollSpeed, in: TrackpadTuning.scrollMinSpeed...TrackpadTuning.scrollMaxSpeed)
                                    .tint(theme.accent)
                                    .accessibilityIdentifier("scrollSpeedSlider")
                                Image(systemName: "hare.fill").font(.system(size: 13)).foregroundStyle(theme.textTertiary)
                            }
                        }
                        .padding(.horizontal, 16).padding(.vertical, 14)
                    }
                    Text("顺滑度 = 手指拖动→光标移动的速度; 滚动速度 = 两指/右侧边滑动→滚动的快慢。都内置轻微加速。")
                        .font(.system(size: 12)).foregroundStyle(theme.hint)

                    Text("帮助").font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.textPrimary)
                    SoftPanel(padding: 0) {
                        VStack(spacing: 0) {
                            helpRow(icon: "desktopcomputer", title: String(localized: "连接电脑 · 安装小助手"),
                                    id: "setupGuideRow") { showSetupGuide = true }
                            RowDivider(inset: 16)
                            helpRow(icon: "info.circle", title: String(localized: "关于 Sidekey"),
                                    id: "aboutRow") { showAbout = true }
                            #if DEBUG
                            RowDivider(inset: 16)
                            helpRow(icon: "ruler", title: "Duo 测量（调试）", id: "duoProbeRow") { showDuoProbe = true }
                            #endif
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 16)
            }
        }
        .background(theme.bgGradient.ignoresSafeArea())
        .environment(\.sidekeyTheme, theme)
        .onChange(of: store.discardGeneration) { _ in showKeyEditor = false }
        // 大屏编辑器全屏打开 (§4.8); 原键位照旧 sheet
        .sheet(isPresented: Binding(get: { showKeyEditor && keyEditorTarget?.set != .large }, set: { showKeyEditor = $0 })) { keyEditor }
        .fullScreenCover(isPresented: Binding(get: { showKeyEditor && keyEditorTarget?.set == .large }, set: { showKeyEditor = $0 })) { keyEditor }
        .sheet(isPresented: $showLargeRecovery) {
            RecoveryView(store: store, which: .large).environment(\.sidekeyTheme, theme)
        }
        .sheet(isPresented: $showSetupGuide) {
            // 参考型入口: 隐藏「现在扫码」(退回设置页无处扫码); 只留「获取小助手」+ 下载地址。
            SetupGuideView(showScanCTA: false)
        }
        .sheet(isPresented: $showAbout) {
            AboutView()
        }
        #if DEBUG
        // 全屏而不是 sheet: sheet 在内屏会变成居中表单, 量到的就不是窗口尺寸了。
        .fullScreenCover(isPresented: $showDuoProbe) {
            DuoProbeView(onClose: { showDuoProbe = false })
        }
        #endif
    }

    /// 帮助区通用行: 前置图标 + 标题 + chevron。
    private func helpRow(icon: String, title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 15)).foregroundStyle(theme.accentInk).frame(width: 22)
                Text(title).font(.system(size: 16)).foregroundStyle(theme.textPrimary)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.hint)
            }
            .padding(.horizontal, 16).frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    private func styleCard(_ style: SidekeyStyle, name: String) -> some View {
        let selected = themeManager.style == style
        let st = style == .lively ? SidekeyTheme.make(.lively, dark: true) : SidekeyTheme.make(style, dark: false)
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { themeManager.style = style }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            VStack(spacing: 10) {
                StyleMini(t: st)
                Text(name).font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.textPrimary)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18)).foregroundStyle(selected ? theme.accentInk : theme.hint)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: theme.radiusCard, style: .continuous)
                .fill(selected ? theme.accentLight.opacity(0.4) : theme.surface).raisedShadow(theme))
            .overlay(RoundedRectangle(cornerRadius: theme.radiusCard, style: .continuous)
                .strokeBorder(selected ? theme.accent : theme.hairline, lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("styleCard_\(style.rawValue)")
    }
}

/// 风格 2×2 预览 (含一个 accent 键), 颜色来自该风格 token。
private struct StyleMini: View {
    let t: SidekeyTheme
    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 5) { key(t.keyFill); accent() }
            HStack(spacing: 5) { key(t.keyModFill); key(t.keyFill) }
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(t.canvasBottom))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(t.hairline, lineWidth: 1))
    }
    private func key(_ c: Color) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(c)
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(t.hairline, lineWidth: 1))
            .frame(width: 26, height: 22)
    }
    private func accent() -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(t.accent).frame(width: 26, height: 22)
    }
}
