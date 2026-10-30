import SwiftUI

extension Color {
    /// 从 0xRRGGBB 创建颜色 (主题 token 用)。
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}

/// 三种可选视觉风格。默认 fresh = 「柔光珊瑚」(暖白 + 单珊瑚强调)。
/// apple = 「苹果风」(§4.10): 浅色 = 银白, 深色 = 暗夜; 明暗沿用「浅色 / 深色 / 跟随系统」, 不会出现「银白 + 深色」之类的组合。
enum SidekeyStyle: String, CaseIterable, Codable { case fresh, minimal, lively, apple }
/// 明暗外观。
enum SidekeyAppearance: String, CaseIterable, Codable { case light, dark, system }
/// Agent 状态灯朝向 (横条 / 竖排, 可选)。
enum LightOrientation: String, CaseIterable, Codable { case horizontal, vertical }

/// 一套主题 token (对齐 AGENT_IMPLEMENTATION_BRIEF)。组件只读这里, 不许各自硬编码颜色/阴影。
struct SidekeyTheme {
    var canvasTop, canvasBottom: Color      // 整页暖白 (顶→底 2~3% 过渡)
    var surface, surfaceMuted: Color         // 卡片/键帽 ; 内嵌区/未选分段/输入框
    var accent, accentLight: Color           // 主操作/选中 ; 选中填充/轻提示
    var textPrimary, textSecondary, textTertiary: Color
    var success, warning, danger: Color
    var keyFill, keyText, keyModFill, keyModText: Color
    var hairline: Color                      // 1pt 发丝描边
    var radiusKey, radiusCard, radiusPanel: CGFloat
    var raised: Bool                         // 是否有柔光抬升 (暗/极简扁平)
    var isDark: Bool
    var style: SidekeyStyle = .fresh

    var radiusPill: CGFloat { 999 }
    // 兼容旧引用
    var accentText: Color { .white }          // 主色填充上的文字 (onAccent)
    var bgTop: Color { canvasTop }
    var bgBottom: Color { canvasBottom }
    var keyStroke: Color { hairline }
    var cardRadius: CGFloat { radiusCard }   // 兼容尚未重做的页面
    var keyRadius: CGFloat { radiusKey }
    var keyShadow: Bool { raised }
    var accentA: Color { accent }
    var accentB: Color { accent }
    var accentGradient: LinearGradient {
        LinearGradient(colors: [accent, accent], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    var bgGradient: LinearGradient {
        LinearGradient(colors: [canvasTop, canvasBottom], startPoint: .top, endPoint: .bottom)
    }

    // MARK: 苹果风追加的 token (其他风格取与原来界面一致的值, 不改变现有外观)
    /// 浅底 (accentLight / 卡片) 上的主色文字与图标: 苹果风的填充色上深一档才够 4.5:1。
    var accentInk: Color {
        guard style == .apple else { return accent }
        return isDark ? Color(hex: 0x6CB4FF) : Color(hex: 0x0062CC)
    }
    /// 操作说明 / 菜单副标题: 用可读的文字色, 不用「禁用」那一档的浅灰 (§4.10)。
    var hint: Color {
        guard style == .apple else { return textTertiary }
        // 银白: 画布底部渐变到 #D8D9DD, 画布上的说明文字要比 UI 稿的 #636366 再深一点才够 4.5:1
        return isDark ? Color(hex: 0xA3A9B2) : Color(hex: 0x5C5C60)
    }
    /// 连接状态等语义文字色 (角标符号、状态文字): 按实际底色逐个满足对比度。
    var successInk: Color {
        if style == .apple { return isDark ? Color(hex: 0x30D158) : Color(hex: 0x1E7B34) }
        return isDark ? Color(hex: 0x4FD58E) : Color(hex: 0x3F9A62)
    }
    var cautionInk: Color {
        if style == .apple { return isDark ? Color(hex: 0xFFB86B) : Color(hex: 0x8F4400) }
        return isDark ? Color(hex: 0xF2A03D) : Color(hex: 0xB4532A)
    }
    /// 作为「文字」用的警告 / 危险色 (其他风格 = 原来的 warning / danger, 外观不变; 苹果风换成能过 4.5:1 的深 / 浅一档)。
    var warningText: Color { style == .apple ? cautionInk : warning }
    var dangerText: Color { style == .apple ? dangerInk : danger }
    /// 警告色填充 (如「重新检测」按钮) 上的文字: 苹果风用深色 (橙底白字只有 2:1), 其他风格保持白色。
    var onWarning: Color { style == .apple ? Color(hex: 0x1D1D1F) : .white }
    var dangerInk: Color {
        if style == .apple { return isDark ? Color(hex: 0xFF6961) : Color(hex: 0xAD0010) }
        return isDark ? Color(hex: 0xFF7378) : Color(hex: 0xD2433C)
    }

    // MARK: 柔光阴影 (shadowRaised / shadowPressed); 暗色/极简返回 .clear, 改用描边
    /// 外阴影 (柔软隆起)。苹果风银白 = 1 pt 下沿硬阴影 (像实体键); 暗夜不靠阴影靠描边。
    var raisedOuter: (color: Color, radius: CGFloat, y: CGFloat) {
        guard raised, !isDark else { return (.clear, 0, 0) }
        if style == .apple { return (Color.black.opacity(0.20), 0, 1) }
        return (Color(hex: 0xA08B7A).opacity(0.12), 14, 8)
    }
    /// 上沿白光 (微微高光)。苹果风银白改为淡投影。
    var raisedTop: (color: Color, radius: CGFloat, y: CGFloat) {
        guard raised, !isDark else { return (.clear, 0, 0) }
        if style == .apple { return (Color.black.opacity(0.16), 4, 3) }
        return (Color.white.opacity(0.85), 2, -1)
    }
    /// 按下 / 内嵌阴影。
    var pressedShadow: (color: Color, radius: CGFloat, y: CGFloat) {
        if style == .apple { return (Color.black.opacity(isDark ? 0.50 : 0.18), 5, 3) }
        return isDark ? (Color.black.opacity(0.40), 5, 3) : (Color(hex: 0xCDB8A8).opacity(0.13), 5, 3)
    }

    /// 语义色 (确认绿 / 回退红) → (填充, 文字)。各风格保留可辨识度。
    /// 确认绿 / 回退红 的 (填充, 文字) 色对。公开成 Color, 供对比度测试用实际的填充色计算。
    var successPair: (fill: Color, text: Color) {
        if style == .apple {
            return isDark ? (Color(hex: 0x17331F), Color(hex: 0x30D158)) : (Color(hex: 0xE3F6E8), Color(hex: 0x1E7B34))
        }
        return isDark ? (Color(hex: 0x17331E), Color(hex: 0x4FD58E)) : (Color(hex: 0xDDF1E3), Color(hex: 0x2E9D5E))
    }
    var dangerPair: (fill: Color, text: Color) {
        if style == .apple {
            return isDark ? (Color(hex: 0x3A1B1D), Color(hex: 0xFF6961)) : (Color(hex: 0xFFE5E3), Color(hex: 0xD70015))
        }
        return isDark ? (Color(hex: 0x371A1C), Color(hex: 0xFF7378)) : (Color(hex: 0xFBE1DF), Color(hex: 0xD2433C))
    }
    private var successStyle: (AnyShapeStyle, Color) { (AnyShapeStyle(successPair.fill), successPair.text) }
    private var dangerStyle: (AnyShapeStyle, Color) { (AnyShapeStyle(dangerPair.fill), dangerPair.text) }

    /// 功能分组色 → (填充, 文字)。
    /// 柔光珊瑚/极简 = 单强调, 装饰色(薄荷/天蓝/薰衣草/琥珀)收敛为中性白键, 仅珊瑚/语义色保留; 活泼 = 完整多彩。
    func tintStyle(_ t: KeyTint) -> (AnyShapeStyle, Color) {
        if t == .accent { return (AnyShapeStyle(accent), accentText) }  // 主操作键(Enter): 各风格都实心强调
        if style == .minimal { return (AnyShapeStyle(keyFill), keyText) }
        switch t {
        case .accent:   return (AnyShapeStyle(accent), accentText)      // (上面已提前返回, 这里保证 switch 穷尽)
        case .coral:    return (AnyShapeStyle(accentLight), accentInk)  // 柔珊瑚浅填 + 珊瑚字/符 (苹果风: 浅蓝填 + 蓝字)
        case .neutral:  return (AnyShapeStyle(keyModFill), keyModText)
        case .success:  return successStyle
        case .danger:   return dangerStyle
        case .mint, .sky, .lavender, .amber:
            guard style == .lively else { return (AnyShapeStyle(keyFill), keyText) }
            switch t {
            case .mint:     return isDark ? (AnyShapeStyle(Color(hex: 0x1C3A30)), Color(hex: 0x6FD9B0)) : (AnyShapeStyle(Color(hex: 0xD4F4E8)), Color(hex: 0x1AA079))
            case .sky:      return isDark ? (AnyShapeStyle(Color(hex: 0x1B2C44)), Color(hex: 0x77ABEC)) : (AnyShapeStyle(Color(hex: 0xDBEBFF)), Color(hex: 0x3B82D6))
            case .lavender: return isDark ? (AnyShapeStyle(Color(hex: 0x2A2540)), Color(hex: 0xB6A9E6)) : (AnyShapeStyle(Color(hex: 0xE9E3FF)), Color(hex: 0x7B6AD6))
            case .amber:    return isDark ? (AnyShapeStyle(Color(hex: 0x3A2E18)), Color(hex: 0xE6B968)) : (AnyShapeStyle(Color(hex: 0xFFEBC9)), Color(hex: 0xC0851A))
            default:        return (AnyShapeStyle(keyFill), keyText)
            }
        }
    }

    static func make(_ style: SidekeyStyle, dark: Bool) -> SidekeyTheme {
        var t = makeTokens(style, dark: dark)
        t.style = style
        return t
    }

    private static func makeTokens(_ style: SidekeyStyle, dark: Bool) -> SidekeyTheme {
        switch (style, dark) {
        // 柔光珊瑚 (默认, 严格对齐 brief)
        case (.fresh, false):
            return .init(canvasTop: Color(hex: 0xFBF7F2), canvasBottom: Color(hex: 0xF7F1EA),
                         surface: Color(hex: 0xFFFDF9), surfaceMuted: Color(hex: 0xF6EFE8),
                         accent: Color(hex: 0xFF7D62), accentLight: Color(hex: 0xFFD8CD),
                         textPrimary: Color(hex: 0x303841), textSecondary: Color(hex: 0x7A8085), textTertiary: Color(hex: 0xA9AAA8),
                         success: Color(hex: 0x55B978), warning: Color(hex: 0xF2A03D), danger: Color(hex: 0xEC5A53),
                         keyFill: Color(hex: 0xFFFDF9), keyText: Color(hex: 0x303841), keyModFill: Color(hex: 0xF6EFE8), keyModText: Color(hex: 0x7A8085),
                         hairline: Color(hex: 0xE9DFD7), radiusKey: 18, radiusCard: 20, radiusPanel: 24, raised: true, isDark: false)
        // 柔光珊瑚 · 深色 (午夜暖石)
        case (.fresh, true):
            return .init(canvasTop: Color(hex: 0x1A1714), canvasBottom: Color(hex: 0x131110),
                         surface: Color(hex: 0x241F1B), surfaceMuted: Color(hex: 0x1B1713),
                         accent: Color(hex: 0xFF8466), accentLight: Color(hex: 0x4A2C22),
                         textPrimary: Color(hex: 0xF0E9E2), textSecondary: Color(hex: 0xA89E94), textTertiary: Color(hex: 0x726860),
                         success: Color(hex: 0x4FD58E), warning: Color(hex: 0xF2A03D), danger: Color(hex: 0xFF6F66),
                         keyFill: Color(hex: 0x2A241F), keyText: Color(hex: 0xECE5DD), keyModFill: Color(hex: 0x1E1A16), keyModText: Color(hex: 0x8A8076),
                         hairline: Color(hex: 0x3A322B), radiusKey: 18, radiusCard: 20, radiusPanel: 24, raised: false, isDark: true)
        // 苹果风 · 银白 (银色 MacBook + 白色 Magic Keyboard, UI 稿画板 15)
        case (.apple, false):
            return .init(canvasTop: Color(hex: 0xE4E5E8), canvasBottom: Color(hex: 0xD8D9DD),
                         surface: Color(hex: 0xFFFFFF), surfaceMuted: Color(hex: 0xEEEEF1),
                         accent: Color(hex: 0x0071E3), accentLight: Color(hex: 0xD3E5FF),
                         textPrimary: Color(hex: 0x1D1D1F), textSecondary: Color(hex: 0x5C5C60), textTertiary: Color(hex: 0xA1A1A6),   // 次要文字比 UI 稿的 #636366 深一档: 画布渐变底部 #D8D9DD 上才有 4.5:1
                         success: Color(hex: 0x34C759), warning: Color(hex: 0xFF9F0A), danger: Color(hex: 0xFF3B30),
                         keyFill: Color(hex: 0xFFFFFF), keyText: Color(hex: 0x1D1D1F), keyModFill: Color(hex: 0xEEEEF1), keyModText: Color(hex: 0x636366),
                         hairline: Color(hex: 0xCFCFD4), radiusKey: 18, radiusCard: 20, radiusPanel: 24, raised: true, isDark: false)
        // 苹果风 · 暗夜 (MacBook Air 午夜色, 画板 16)
        case (.apple, true):
            return .init(canvasTop: Color(hex: 0x20242B), canvasBottom: Color(hex: 0x181B21),
                         surface: Color(hex: 0x2C313A), surfaceMuted: Color(hex: 0x252930),
                         accent: Color(hex: 0x0A6BDB), accentLight: Color(hex: 0x1A3A60),
                         textPrimary: Color(hex: 0xF2F3F5), textSecondary: Color(hex: 0xA3A9B2), textTertiary: Color(hex: 0x6C727B),
                         success: Color(hex: 0x30D158), warning: Color(hex: 0xFF9F0A), danger: Color(hex: 0xFF453A),
                         keyFill: Color(hex: 0x2C313A), keyText: Color(hex: 0xF2F3F5), keyModFill: Color(hex: 0x252930), keyModText: Color(hex: 0xA3A9B2),
                         hairline: Color(hex: 0x383E48), radiusKey: 18, radiusCard: 20, radiusPanel: 24, raised: false, isDark: true)
        // 云雾灰 (极简浅)
        case (.minimal, false):
            return .init(canvasTop: Color(hex: 0xF6F5F3), canvasBottom: Color(hex: 0xEFEEEC),
                         surface: Color(hex: 0xFFFFFF), surfaceMuted: Color(hex: 0xF0EFEC),
                         accent: Color(hex: 0x2A2A2C), accentLight: Color(hex: 0xE4E3E0),
                         textPrimary: Color(hex: 0x1C1C1E), textSecondary: Color(hex: 0x8A8A8E), textTertiary: Color(hex: 0xBEBEC2),
                         success: Color(hex: 0x34B37A), warning: Color(hex: 0xC99A2E), danger: Color(hex: 0xD9534F),
                         keyFill: Color(hex: 0xFAFAF9), keyText: Color(hex: 0x3A3A3C), keyModFill: Color(hex: 0xF0EFEC), keyModText: Color(hex: 0x9A9A9E),
                         hairline: Color(hex: 0xE6E4E0), radiusKey: 16, radiusCard: 18, radiusPanel: 22, raised: true, isDark: false)
        case (.minimal, true):
            return .init(canvasTop: Color(hex: 0x0B0B0C), canvasBottom: Color(hex: 0x0B0B0C),
                         surface: Color(hex: 0x161618), surfaceMuted: Color(hex: 0x121214),
                         accent: Color(hex: 0xE6E6E8), accentLight: Color(hex: 0x2A2A2C),
                         textPrimary: Color(hex: 0xF2F2F4), textSecondary: Color(hex: 0x9A9A9E), textTertiary: Color(hex: 0x5A5A5E),
                         success: Color(hex: 0x34B37A), warning: Color(hex: 0xC99A2E), danger: Color(hex: 0xD9534F),
                         keyFill: Color(hex: 0x19191B), keyText: Color(hex: 0xC8C8CC), keyModFill: Color(hex: 0x141416), keyModText: Color(hex: 0x7A7A7E),
                         hairline: Color(hex: 0x2A2A2C), radiusKey: 16, radiusCard: 18, radiusPanel: 22, raised: false, isDark: true)
        // 午夜深蓝 (活泼 = 深蓝多彩, 用作第三风格预览)
        case (.lively, false), (.lively, true):
            return .init(canvasTop: Color(hex: 0x1B2233), canvasBottom: Color(hex: 0x141A28),
                         surface: Color(hex: 0x232C40), surfaceMuted: Color(hex: 0x1B2233),
                         accent: Color(hex: 0xFF8466), accentLight: Color(hex: 0x3A3350),
                         textPrimary: Color(hex: 0xEAEEF6), textSecondary: Color(hex: 0x97A2B8), textTertiary: Color(hex: 0x66708A),
                         success: Color(hex: 0x4FD58E), warning: Color(hex: 0xF5B73C), danger: Color(hex: 0xFF6F76),
                         keyFill: Color(hex: 0x2A3346), keyText: Color(hex: 0xD8DEEC), keyModFill: Color(hex: 0x222B3D), keyModText: Color(hex: 0x9AA4BC),
                         hairline: Color(hex: 0x36405A), radiusKey: 18, radiusCard: 20, radiusPanel: 24, raised: false, isDark: true)
        }
    }
}

// MARK: - 柔光抬升阴影 (shadowRaised: 外暖影 + 上沿白光)
extension View {
    func raisedShadow(_ t: SidekeyTheme) -> some View {
        let o = t.raisedOuter, tp = t.raisedTop
        return self
            .shadow(color: o.color, radius: o.radius, x: 0, y: o.y)
            .shadow(color: tp.color, radius: tp.radius, x: 0, y: tp.y)
    }
}

// MARK: - Environment 注入
private struct SidekeyThemeKey: EnvironmentKey {
    static let defaultValue = SidekeyTheme.make(.fresh, dark: false)
}
extension EnvironmentValues {
    var sidekeyTheme: SidekeyTheme {
        get { self[SidekeyThemeKey.self] }
        set { self[SidekeyThemeKey.self] = newValue }
    }
}

/// 当前主题 (风格 + 明暗), 持久化到 UserDefaults。设置 › 外观 改这里, 全局即时生效。
@MainActor
final class ThemeManager: ObservableObject {
    @Published var style: SidekeyStyle { didSet { persist() } }
    @Published var appearance: SidekeyAppearance { didSet { persist() } }
    @Published var statusLightOn: Bool { didSet { persist() } }
    @Published var lightOrientation: LightOrientation { didSet { persist() } }
    @Published var statusDeep: Bool { didSet { persist() } }

    private let defaults: UserDefaults
    private static let styleKey = "sidekey.theme.style"
    private static let appearanceKey = "sidekey.theme.appearance"
    private static let statusLightOnKey = "sidekey.statuslight.on"
    private static let lightOrientationKey = "sidekey.statuslight.orientation"
    private static let statusDeepKey = "sidekey.statuslight.deep"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.style = defaults.string(forKey: Self.styleKey).flatMap(SidekeyStyle.init(rawValue:)) ?? .fresh
        self.appearance = defaults.string(forKey: Self.appearanceKey).flatMap(SidekeyAppearance.init(rawValue:)) ?? .light
        self.statusLightOn = defaults.object(forKey: Self.statusLightOnKey) == nil
            ? true : defaults.bool(forKey: Self.statusLightOnKey)
        self.lightOrientation = defaults.string(forKey: Self.lightOrientationKey)
            .flatMap(LightOrientation.init(rawValue:)) ?? .horizontal
        self.statusDeep = defaults.bool(forKey: Self.statusDeepKey)
    }

    private func persist() {
        defaults.set(style.rawValue, forKey: Self.styleKey)
        defaults.set(appearance.rawValue, forKey: Self.appearanceKey)
        defaults.set(statusLightOn, forKey: Self.statusLightOnKey)
        defaults.set(lightOrientation.rawValue, forKey: Self.lightOrientationKey)
        defaults.set(statusDeep, forKey: Self.statusDeepKey)
    }

    /// 结合系统明暗解析当前 token。活泼(午夜深蓝)自身即深色, 不受明暗开关影响。
    func theme(system: ColorScheme) -> SidekeyTheme {
        if style == .lively { return SidekeyTheme.make(.lively, dark: true) }
        let dark: Bool
        switch appearance {
        case .light:  dark = false
        case .dark:   dark = true
        case .system: dark = (system == .dark)
        }
        return SidekeyTheme.make(style, dark: dark)
    }

    var preferredColorScheme: ColorScheme? {
        if style == .lively { return .dark }
        switch appearance {
        case .light:  return .light
        case .dark:   return .dark
        case .system: return nil
        }
    }
}
