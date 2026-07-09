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
enum SidekeyStyle: String, CaseIterable, Codable { case fresh, minimal, lively }
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
    var accentText: Color { .white }
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

    // MARK: 柔光阴影 (shadowRaised / shadowPressed); 暗色/极简返回 .clear, 改用描边
    /// 外阴影 (柔软隆起)。
    var raisedOuter: (color: Color, radius: CGFloat, y: CGFloat) {
        guard raised, !isDark else { return (.clear, 0, 0) }
        return (Color(hex: 0xA08B7A).opacity(0.12), 14, 8)
    }
    /// 上沿白光 (微微高光)。
    var raisedTop: (color: Color, radius: CGFloat, y: CGFloat) {
        guard raised, !isDark else { return (.clear, 0, 0) }
        return (Color.white.opacity(0.85), 2, -1)
    }
    /// 按下 / 内嵌阴影。
    var pressedShadow: (color: Color, radius: CGFloat, y: CGFloat) {
        isDark ? (Color.black.opacity(0.40), 5, 3) : (Color(hex: 0xCDB8A8).opacity(0.13), 5, 3)
    }

    /// 语义色 (确认绿 / 回退红) → (填充, 文字)。各风格保留可辨识度。
    private var successStyle: (AnyShapeStyle, Color) {
        isDark ? (AnyShapeStyle(Color(hex: 0x17331E)), Color(hex: 0x4FD58E))
               : (AnyShapeStyle(Color(hex: 0xDDF1E3)), Color(hex: 0x2E9D5E))
    }
    private var dangerStyle: (AnyShapeStyle, Color) {
        isDark ? (AnyShapeStyle(Color(hex: 0x371A1C)), Color(hex: 0xFF7378))
               : (AnyShapeStyle(Color(hex: 0xFBE1DF)), Color(hex: 0xD2433C))
    }

    /// 功能分组色 → (填充, 文字)。
    /// 柔光珊瑚/极简 = 单强调, 装饰色(薄荷/天蓝/薰衣草/琥珀)收敛为中性白键, 仅珊瑚/语义色保留; 活泼 = 完整多彩。
    func tintStyle(_ t: KeyTint) -> (AnyShapeStyle, Color) {
        if t == .accent { return (AnyShapeStyle(accent), accentText) }  // 主操作键(Enter): 各风格都实心强调
        if style == .minimal { return (AnyShapeStyle(keyFill), keyText) }
        switch t {
        case .accent:   return (AnyShapeStyle(accent), accentText)      // (上面已提前返回, 这里保证 switch 穷尽)
        case .coral:    return (AnyShapeStyle(accentLight), accent)     // 柔珊瑚浅填 + 珊瑚字/符
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
