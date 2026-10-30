import SwiftUI

/// 连接状态角标 (§4.10, 所有风格): 当前电脑圆圈右下角带符号的小角标, 连接状态不只靠环的颜色。
/// ✓ 已连接 · … 连接中 · ! 失败 · × 断开。角标 = 卡片底色 + 状态色描边, 符号用对应的状态文字色。
enum ConnectionBadgeState: Equatable {
    case ok, wait, fail, off

    var glyph: String {
        switch self { case .ok: return "✓"; case .wait: return "…"; case .fail: return "!"; case .off: return "×" }
    }
    var title: String {
        switch self {
        case .ok: return String(localized: "已连接")
        case .wait: return String(localized: "连接中")
        case .fail: return String(localized: "失败")
        case .off: return String(localized: "断开")
        }
    }
    func line(_ t: SidekeyTheme) -> Color {
        switch self { case .ok: return t.success; case .wait: return t.warning; case .fail: return t.danger; case .off: return t.textTertiary }
    }
    func ink(_ t: SidekeyTheme) -> Color {
        switch self { case .ok: return t.successInk; case .wait: return t.cautionInk; case .fail: return t.dangerInk; case .off: return t.textSecondary }
    }
}

struct ConnectionBadge: View {
    let state: ConnectionBadgeState
    @Environment(\.sidekeyTheme) private var theme

    var body: some View {
        Text(state.glyph)
            .font(.system(size: 10, weight: .heavy))
            .foregroundStyle(state.ink(theme))
            .frame(width: 16, height: 16)
            .background(Circle().fill(theme.surface))
            .overlay(Circle().strokeBorder(state.line(theme), lineWidth: 1.5))
            .accessibilityHidden(true)    // 状态文字由圆圈的 accessibilityValue 读出
    }
}
