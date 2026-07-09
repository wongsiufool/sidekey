import SwiftUI

// MARK: - 品牌锁定 (珊瑚 `>_` 小键帽 + 小写 sidekey, SF Pro Rounded)
struct BrandMark: View {
    @Environment(\.sidekeyTheme) private var theme
    var size: CGFloat = 28
    var body: some View {
        let cap = size * 1.04
        HStack(spacing: size * 0.30) {
            RoundedRectangle(cornerRadius: cap * 0.3, style: .continuous)
                .fill(theme.accentLight)
                .frame(width: cap, height: cap)
                .overlay(
                    PromptGlyph()
                        .stroke(theme.accent, style: StrokeStyle(lineWidth: max(1.6, cap * 0.085),
                                                                 lineCap: .round, lineJoin: .round))
                        .padding(cap * 0.28)
                )
                .overlay(RoundedRectangle(cornerRadius: cap * 0.3, style: .continuous)
                    .strokeBorder(theme.accent.opacity(0.45), lineWidth: 1))
            Text("sidekey")
                .font(.system(size: size, weight: .bold, design: .rounded))
                .kerning(-0.5)
                .foregroundStyle(theme.textPrimary)
        }
    }
}

/// 终端提示符 `>_` (品牌键帽内的自绘标记): 一个 chevron + 底部下划线。
struct PromptGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width, h = rect.height
        // chevron ">"
        p.move(to: CGPoint(x: rect.minX + w * 0.10, y: rect.minY + h * 0.12))
        p.addLine(to: CGPoint(x: rect.minX + w * 0.52, y: rect.minY + h * 0.50))
        p.addLine(to: CGPoint(x: rect.minX + w * 0.10, y: rect.minY + h * 0.88))
        // underscore "_"
        p.move(to: CGPoint(x: rect.minX + w * 0.60, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        return p
    }
}

/// 自绘 delete-left (Backspace) 线性图标: 左尖五边形主体 + 中心 X。
/// 全 App 统一用它, 不再用 Unicode ⌫ 或变形长六边形 (主页 / 第二页 / 任何 backspace 键一致)。
struct DeleteLeftShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width, h = rect.height
        let bodyLeft = rect.minX + w * 0.28
        // 主体: 右端方、左端尖的五边形 (圆角靠 lineJoin: .round 软化)
        p.move(to: CGPoint(x: bodyLeft, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: bodyLeft, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        p.closeSubpath()
        // 中心 X
        let cx = rect.minX + w * 0.60
        let ex = w * 0.12, ey = h * 0.20
        p.move(to: CGPoint(x: cx - ex, y: rect.midY - ey))
        p.addLine(to: CGPoint(x: cx + ex, y: rect.midY + ey))
        p.move(to: CGPoint(x: cx + ex, y: rect.midY - ey))
        p.addLine(to: CGPoint(x: cx - ex, y: rect.midY + ey))
        return p
    }
}

/// 自绘空格键标记 ⎵ (一条底线 + 两端短竖): 比任何 SF Symbol 都直白, 全 App 统一。
struct SpaceBarShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let drop = rect.height * 0.55
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY - drop))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - drop))
        return p
    }
}

// MARK: - 区块标题 (20 semibold)
struct SectionTitle: View {
    @Environment(\.sidekeyTheme) private var theme
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(theme.textPrimary)
    }
}

// MARK: - 柔光面板 (近白填充 + 1pt hairline + 双层柔影)
struct SoftPanel<Content: View>: View {
    @Environment(\.sidekeyTheme) private var theme
    var radius: CGFloat? = nil
    var padding: CGFloat = 16
    var fill: Color? = nil
    @ViewBuilder var content: Content

    var body: some View {
        let r = radius ?? theme.radiusPanel
        let shape = RoundedRectangle(cornerRadius: r, style: .continuous)
        content
            .padding(padding)
            .background(shape.fill(fill ?? theme.surface).raisedShadow(theme))
            .overlay(shape.strokeBorder(theme.hairline, lineWidth: 1))
    }
}

// MARK: - 珊瑚主按钮 (完整药丸)
struct CoralButton: View {
    @Environment(\.sidekeyTheme) private var theme
    let title: String
    var icon: String? = nil
    var height: CGFloat = 52
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon) }
                Text(title)
            }
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(Capsule().fill(theme.accent))
            .shadow(color: theme.accent.opacity(0.30), radius: 14, x: 0, y: 8)
            .shadow(color: theme.accent.opacity(0.16), radius: 3, x: 0, y: 1)
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.45)
        .disabled(!enabled)
    }
}

// MARK: - 描边 / 近白次按钮 (扫码配对等)
struct OutlineButton: View {
    @Environment(\.sidekeyTheme) private var theme
    let title: String
    var icon: String? = nil
    var height: CGFloat = 52
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon) }
                Text(title)
            }
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(theme.accent)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(Capsule().fill(theme.surface))
            .overlay(Capsule().strokeBorder(theme.accent.opacity(0.5), lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 圆形图标按钮 (40pt, header 右侧 / 齿轮)
struct CircleIconButton: View {
    @Environment(\.sidekeyTheme) private var theme
    let icon: String
    var filled: Bool = false           // true = 珊瑚实心 (如「+」)
    var diameter: CGFloat = 40
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: filled ? 18 : 17, weight: .semibold))
                .foregroundStyle(filled ? .white : theme.textSecondary)
                .frame(width: diameter, height: diameter)
                .background(
                    Circle().fill(filled ? theme.accent : theme.surface)
                        .raisedShadow(theme)
                )
                .overlay(Circle().strokeBorder(filled ? .clear : theme.hairline, lineWidth: 1))
                .shadow(color: filled ? theme.accent.opacity(0.3) : .clear, radius: 10, y: 5)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - App 图标式圆角方块 (Agent chip / 设备 / 模式图标)
struct IconChip: View {
    @Environment(\.sidekeyTheme) private var theme
    let icon: String
    var tint: Color? = nil             // nil = 珊瑚
    var size: CGFloat = 40
    var symbolScale: CGFloat = 0.46

    var body: some View {
        let c = tint ?? theme.accent
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(c.opacity(theme.isDark ? 0.22 : 0.16))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: icon)
                    .font(.system(size: size * symbolScale, weight: .semibold))
                    .foregroundStyle(c)
            )
            .overlay(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .strokeBorder(c.opacity(0.18), lineWidth: 1))
    }
}

// MARK: - 连接状态点
struct ConnDot: View {
    let color: Color
    var pulsing: Bool = false
    @State private var on = false
    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
            .scaleEffect(on ? 1.5 : 1).opacity(on ? 0.5 : 1)
            .animation(.easeInOut(duration: 0.3), value: color)
            .onAppear { apply(pulsing) }
            .onChange(of: pulsing) { apply($0) }
    }
    private func apply(_ p: Bool) {
        if p { withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { on = true } }
        else { withAnimation(.easeInOut(duration: 0.2)) { on = false } }
    }
}

// MARK: - 状态药丸 (浅底 + 文字 + 可选点)
struct StatusPill: View {
    @Environment(\.sidekeyTheme) private var theme
    let text: String
    var dotColor: Color? = nil
    var emphasized: Bool = false       // true = 珊瑚浅填 (当前/已选)
    var body: some View {
        HStack(spacing: 6) {
            if let dotColor { Circle().fill(dotColor).frame(width: 7, height: 7) }
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(emphasized ? theme.accent : theme.textSecondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(emphasized ? theme.accentLight : theme.surfaceMuted))
    }
}

/// 「上次请求」标签 (审计 M-8): 权限/Effort 面板里标当前选中行 —— 强调这是「上次由本机请求」的档位,
/// 不是 Claude Code 经核实的实时状态(App 读不到), 避免被误解成「电脑当前就是这个」。
struct LastRequestedTag: View {
    @Environment(\.sidekeyTheme) private var theme
    var body: some View {
        Text("上次请求")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(theme.accent)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(theme.accentLight.opacity(0.7)))
            .overlay(Capsule().strokeBorder(theme.accent.opacity(0.35), lineWidth: 1))
            .accessibilityLabel(String(localized: "上次请求的档位"))
    }
}

// MARK: - 自绘分段控件 (容器 surfaceMuted, 选中 surface + 珊瑚描边)
struct SoftSegmentedControl<T: Hashable>: View {
    @Environment(\.sidekeyTheme) private var theme
    let items: [(title: String, tag: T)]
    @Binding var selection: T
    var onChange: ((T) -> Void)? = nil

    var body: some View {
        HStack(spacing: 4) {
            ForEach(items, id: \.tag) { item in
                let sel = item.tag == selection
                Text(item.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(sel ? theme.accent : theme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(sel ? theme.surface : .clear)
                            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .strokeBorder(sel ? theme.accent.opacity(0.45) : .clear, lineWidth: 1))
                            .shadow(color: sel ? theme.pressedShadow.color : .clear, radius: 4, y: 2)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.18)) { selection = item.tag }
                        onChange?(item.tag)
                    }
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.surfaceMuted))
    }
}

// MARK: - 独立输入框 (标签分层, surfaceMuted)
struct SoftField<Trailing: View>: View {
    @Environment(\.sidekeyTheme) private var theme
    let label: String
    @Binding var text: String
    var placeholder: String = ""
    var id: String? = nil
    var keyboard: UIKeyboardType = .default
    var autocaps: Bool = false
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary)
            HStack(spacing: 8) {
                TextField(placeholder, text: $text)
                    .font(.system(size: 16))
                    .foregroundStyle(theme.textPrimary)
                    .keyboardType(keyboard)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(autocaps ? .sentences : .never)
                    .modifier(OptIdentifier(id: id))
                trailing
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .frame(minHeight: 52)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.surfaceMuted))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(theme.hairline, lineWidth: 1))
    }
}
extension SoftField where Trailing == EmptyView {
    init(label: String, text: Binding<String>, placeholder: String = "", id: String? = nil,
         keyboard: UIKeyboardType = .default, autocaps: Bool = false) {
        self.init(label: label, text: text, placeholder: placeholder, id: id,
                  keyboard: keyboard, autocaps: autocaps) { EmptyView() }
    }
}

/// 有条件地加 accessibilityIdentifier。
struct OptIdentifier: ViewModifier {
    let id: String?
    func body(content: Content) -> some View {
        if let id { content.accessibilityIdentifier(id) } else { content }
    }
}

// MARK: - 面板内的一行 (标签左 + 自定义右 + 高度 + 可点)
struct PanelRow<Trailing: View>: View {
    @Environment(\.sidekeyTheme) private var theme
    let label: String
    var labelColor: Color? = nil
    var height: CGFloat = 56
    var chevron: Bool = false
    var onTap: (() -> Void)? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            Text(label).font(.system(size: 16)).foregroundStyle(labelColor ?? theme.textPrimary)
            Spacer(minLength: 8)
            trailing
            if chevron {
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .frame(minHeight: height)
        .contentShape(Rectangle())
        .modifier(OptTap(onTap: onTap))
    }
}
struct OptTap: ViewModifier {
    let onTap: (() -> Void)?
    func body(content: Content) -> some View {
        if let onTap { content.onTapGesture(perform: onTap) } else { content }
    }
}

/// 面板内分隔线 (hairline, 左缩进)。
struct RowDivider: View {
    @Environment(\.sidekeyTheme) private var theme
    var inset: CGFloat = 0
    var body: some View {
        Rectangle().fill(theme.hairline).frame(height: 1).padding(.leading, inset)
    }
}

// MARK: - 静态微键帽 (模式卡 / 键码 / 风格预览的小键)
struct SoftKeyChip: View {
    @Environment(\.sidekeyTheme) private var theme
    var label: String? = nil
    var icon: String? = nil
    var tint: Color? = nil
    var fill: Color? = nil
    var width: CGFloat = 44
    var height: CGFloat = 34
    var radius: CGFloat = 10
    var fontSize: CGFloat = 14

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        shape.fill(fill ?? theme.keyFill)
            .frame(width: width, height: height)
            .overlay(content)
            .overlay(shape.strokeBorder(theme.hairline, lineWidth: 1))
            .raisedShadow(theme)
    }
    @ViewBuilder private var content: some View {
        let c = tint ?? theme.textSecondary
        HStack(spacing: 3) {
            if let icon { Image(systemName: icon).font(.system(size: fontSize, weight: .semibold)) }
            if let label { Text(label).font(.system(size: fontSize, weight: .semibold)) }
        }
        .foregroundStyle(c)
        .lineLimit(1).minimumScaleFactor(0.5)
        .padding(.horizontal, 4)
    }
}

// MARK: - sheet 顶栏 (返回/品牌 · 标题 · 关闭/图标)
struct SheetHeader: View {
    @Environment(\.sidekeyTheme) private var theme
    var onBack: (() -> Void)? = nil
    var title: String? = nil
    var brandCenter: Bool = false
    var onClose: (() -> Void)? = nil
    var trailingIcon: String? = nil
    var trailingFilled: Bool = false
    var trailingId: String? = nil
    var onTrailing: (() -> Void)? = nil

    var body: some View {
        ZStack {
            if brandCenter { BrandMark(size: 20) }
            else if let title { Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(theme.textPrimary) }
            HStack {
                if let onBack {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left").font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(theme.textSecondary).frame(width: 40, height: 40)
                    }.buttonStyle(.plain)
                }
                Spacer()
                if let onTrailing, let trailingIcon {
                    CircleIconButton(icon: trailingIcon, filled: trailingFilled, action: onTrailing)
                        .modifier(OptIdentifier(id: trailingId))
                } else if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark").font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(theme.textSecondary).frame(width: 40, height: 40)
                            .background(Circle().fill(theme.surfaceMuted))
                    }.buttonStyle(.plain)
                }
            }
        }
        .frame(height: 44)
    }
}
