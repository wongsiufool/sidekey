import CoreGraphics

/// 手机屏竖屏的外围尺寸 (§4.1.1): 沿用现在的界面, 不做整体同比缩放; 窄屏时只把左右留白收窄, 按钮尺寸不缩。
/// 命中区红线: 外围控件 ≥ 44 × 44 (§3.5); 键盘每格宽 ≥ 20 pt、行高 ≥ 40 pt。
struct PhoneMetrics: Equatable {
    var hPadding: CGFloat = 20       // 左右留白
    var topPadding: CGFloat = 12
    var bottomPadding: CGFloat = 12
    var blockSpacing: CGFloat = 16   // 顶栏 / 分页条 / 按键区 / 底栏之间
    var dockHeight: CGFloat = 72
    var micSize: CGFloat = 56
    var computerCircle: CGFloat = 40

    /// 可用宽度小于这个值就算「窄」: Duo 外屏 382 pt; 普通 iPhone ≥ 390。
    static let narrowWidth: CGFloat = 390
    static let narrowHPadding: CGFloat = 12

    /// 竖屏: 可用宽度小于 390 pt 时左右留白从 20 改成 12 (12 列网格每格宽 21.2 → 22.5 pt, 不比现在的 iPhone 窄)。
    static func portrait(width: CGFloat) -> PhoneMetrics {
        var m = PhoneMetrics()
        if width < narrowWidth { m.hPadding = narrowHPadding }
        return m
    }

    /// 12 列网格在这个左右留白下每格的宽度 (列间距 8)。
    func cellWidth(totalWidth: CGFloat, columns: Int, gap: CGFloat = 8) -> CGFloat {
        let w = totalWidth - 2 * hPadding
        return (w - gap * CGFloat(columns - 1)) / CGFloat(columns)
    }
}
