import XCTest
import SwiftUI
@testable import Sidekey

/// T-TH-1 [M1]: 「苹果风」银白 / 暗夜两套 token 的对比度 (普通文字 ≥ 4.5:1, 图标和大字 ≥ 3:1), 按实际前景 / 背景逐个算。
final class ThemeContrastTests: XCTestCase {

    private func lum(_ c: Color) -> Double {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(c).getRed(&r, green: &g, blue: &b, alpha: &a)
        func lin(_ v: CGFloat) -> Double { let x = Double(v); return x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }
    private func ratio(_ a: Color, _ b: Color) -> Double {
        let (x, y) = (lum(a), lum(b)); return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// 按「实际组件」的前景 / 背景逐对计算 (审计 M1 阻断 6: 以前测了 hint, 组件却没用 hint; 成功 / 危险色键拿 surface 代替真实填充)。
    private func check(_ t: SidekeyTheme, _ name: String) {
        let success = t.successPair, danger = t.dangerPair
        let tintSuccess = t.tintStyle(.success).1, tintDanger = t.tintStyle(.danger).1
        let text: [(String, Color, Color)] = [
            // 画布 / 卡片 / 触控板上的文字
            ("正文/画布", t.textPrimary, t.canvasBottom),
            ("正文/卡片", t.textPrimary, t.surface),
            ("次要/卡片", t.textSecondary, t.surface),
            ("次要/内嵌", t.textSecondary, t.surfaceMuted),
            ("触控板标题 (次要/触控板底)", t.textSecondary, t.surfaceMuted),
            ("触控板操作说明 (hint/触控板底, 11 pt)", t.hint, t.surfaceMuted),
            ("操作说明 hint/画布", t.hint, t.canvasBottom),
            ("操作说明 hint/卡片", t.hint, t.surface),
            // 横屏侧栏 / 窄屏文字直接放在画布渐变底部上
            ("横屏侧栏文字 (textSecondary/画布渐变底部)", t.textSecondary, t.canvasBottom),
            ("横屏侧栏文字 (textSecondary/画布渐变顶部)", t.textSecondary, t.canvasTop),
            ("操作说明 hint/画布渐变顶部", t.hint, t.canvasTop),
            // 窗口键「未绑定」13 pt 标签 (在键帽上)
            ("窗口键未绑定标签 (hint/键帽)", t.hint, t.keyFill),
            // 键帽
            ("键帽文字", t.keyText, t.keyFill),
            ("功能键文字", t.keyModText, t.keyModFill),
            // 主色
            ("主色填充上的文字 (加粗)", t.accentText, t.accent),
            ("浅蓝底上的蓝字 (.coral 键 / 录音键)", t.accentInk, t.accentLight),
            ("卡片上的蓝字", t.accentInk, t.surface),
            // 语义色: 作为文字的颜色 vs 它实际所在的底
            ("辅助功能横幅标题 (warningText/画布)", t.warningText, t.canvasBottom),
            ("辅助功能横幅标题 (warningText/卡片)", t.warningText, t.surface),
            ("失败横幅 / 删除按钮 (dangerText/画布)", t.dangerText, t.canvasBottom),
            ("失败横幅 / 删除按钮 (dangerText/卡片)", t.dangerText, t.surface),
            ("「重新检测」按钮 (onWarning/警告色填充)", t.onWarning, t.warning),
            // 成功 / 危险色键: 文字对它自己的填充
            ("成功色键 文字/填充", success.text, success.fill),
            ("危险色键 文字/填充", danger.text, danger.fill),
            ("成功色键 tintStyle 文字/填充", tintSuccess, success.fill),
            ("危险色键 tintStyle 文字/填充", tintDanger, danger.fill),
            // 连接角标: 符号文字色 vs 角标底 (卡片底色)
            ("角标 ✓", t.successInk, t.surface),
            ("角标 …", t.cautionInk, t.surface),
            ("角标 !", t.dangerInk, t.surface),
            ("角标 ×", t.textSecondary, t.surface),
        ]
        for (n, fg, bg) in text { XCTAssertGreaterThanOrEqual(ratio(fg, bg), 4.5, "\(name) \(n) = \(ratio(fg, bg))") }
        // 图标和大字 ≥ 3:1
        let icons: [(String, Color, Color)] = [
            ("键帽图标", t.keyText, t.keyFill),
            ("激活按钮图标", t.accentInk, t.accentLight),
            ("成功色键图标", success.text, success.fill),
            ("危险色键图标", danger.text, danger.fill),
        ]
        for (n, fg, bg) in icons { XCTAssertGreaterThanOrEqual(ratio(fg, bg), 3.0, "\(name) \(n) = \(ratio(fg, bg))") }
    }

    /// 非苹果风: 新增的文字色 token 必须和原来界面用的颜色完全一致 (柔光珊瑚等外观不变)。
    func testOtherStylesKeepTheirOriginalLook() {
        for style in [SidekeyStyle.fresh, .minimal, .lively] {
            for dark in [false, true] {
                let t = SidekeyTheme.make(style, dark: dark)
                XCTAssertEqual(lum(t.accentInk), lum(t.accent), "\(style) accentInk")
                XCTAssertEqual(lum(t.hint), lum(t.textTertiary), "\(style) hint")
                XCTAssertEqual(lum(t.warningText), lum(t.warning), "\(style) warningText")
                XCTAssertEqual(lum(t.dangerText), lum(t.danger), "\(style) dangerText")
                XCTAssertEqual(lum(t.onWarning), lum(.white), "\(style) onWarning")
            }
        }
    }

    func testSilver() { check(SidekeyTheme.make(.apple, dark: false), "银白") }
    func testMidnight() { check(SidekeyTheme.make(.apple, dark: true), "暗夜") }

    // 明暗成对: 苹果风的浅色就是银白, 深色就是暗夜 (不会出现「银白 + 深色」)。
    @MainActor func testPairedWithAppearance() {
        let d = UserDefaults(suiteName: "theme-pair")!; d.removePersistentDomain(forName: "theme-pair")
        let m = ThemeManager(defaults: d)
        m.style = .apple
        m.appearance = .light
        XCTAssertFalse(m.theme(system: .dark).isDark)
        m.appearance = .dark
        XCTAssertTrue(m.theme(system: .light).isDark)
        m.appearance = .system
        XCTAssertTrue(m.theme(system: .dark).isDark)
        XCTAssertFalse(m.theme(system: .light).isDark)
    }
}
