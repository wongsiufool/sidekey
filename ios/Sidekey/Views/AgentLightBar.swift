import SwiftUI
import UIKit

/// Agent 状态卡 (brief A2): 72pt 全宽 SoftPanel — 左 40pt app chip、中间名称/状态、右侧深色小灯箱。
/// 点名字旁 ▾ 可在 Claude / Codex / Auto 间切换 (逻辑不变)。
struct AgentLightBar: View {
    let status: AgentStatus?
    let agent: String
    var auto: Bool = false
    let orientation: LightOrientation
    let connected: Bool
    var compact: Bool = false          // true = 左上角紧凑药丸 (状态点 + 名称 + ▾), 替代旧的全宽卡
    let onSelect: (String) -> Void

    @Environment(\.sidekeyTheme) private var theme

    static let known: [(id: String, name: String, icon: String, tint: KeyTint)] = [
        ("claude", "Claude Code", "sparkles", .amber),
        ("codex", "Codex", "chevron.left.forwardslash.chevron.right", .mint),
    ]
    private var meta: (id: String, name: String, icon: String, tint: KeyTint) {
        Self.known.first { $0.id == agent } ?? Self.known[0]
    }

    private var state: AgentState {
        guard connected else { return .offline }
        return status?.state ?? .offline
    }

    private var label: String {
        if !connected { return "Disconnected" }
        switch state {
        case .busy:    return "Working"
        case .ready:   return "Your turn"
        case .error:   return "Error"
        case .offline: return "Idle"
        }
    }

    private var litColor: Color? {
        switch state {
        case .busy:    return theme.warning
        case .ready:   return theme.success
        case .error:   return theme.danger
        case .offline: return nil
        }
    }

    private var lamps: [(color: Color, lit: Bool)] {
        [(theme.danger,  state == .error),
         (theme.warning, state == .busy),
         (theme.success, state == .ready)]
    }

    var body: some View {
        if compact { compactChip } else { fullPanel }
    }

    /// 左上角紧凑药丸: 状态点 + agent 名 + ▾ (点开切 Claude/Codex/Auto)。替代旧的全宽状态卡。
    private var compactChip: some View {
        Menu {
            agentMenuItems
        } label: {
            HStack(spacing: 7) {
                ConnDot(color: litColor ?? theme.textTertiary, pulsing: state == .busy)
                Text(meta.name)
                    .font(.system(size: 14, weight: .medium)).lineLimit(1)
                    .foregroundStyle(theme.textPrimary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.textTertiary)
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(Capsule().fill(theme.surface).raisedShadow(theme))
            .overlay(Capsule().strokeBorder(theme.hairline, lineWidth: 1))
        }
        .accessibilityIdentifier("agentLightSelector")
    }

    private var fullPanel: some View {
        HStack(spacing: 12) {
            agentMenu
            Spacer(minLength: 8)
            housing
        }
        .padding(.horizontal, 16)
        .frame(height: 72)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: theme.radiusPanel, style: .continuous).fill(theme.surface).raisedShadow(theme))
        .overlay(RoundedRectangle(cornerRadius: theme.radiusPanel, style: .continuous).strokeBorder(theme.hairline, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(meta.name) status \(label)")
        .accessibilityIdentifier("agentLightBar")
    }

    @ViewBuilder private var agentMenuItems: some View {
        Button {
            onSelect("__auto__")
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            if auto { Label("Auto", systemImage: "checkmark") } else { Text("Auto") }
        }
        Divider()
        ForEach(Self.known, id: \.id) { a in
            Button {
                onSelect(a.id)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } label: {
                if !auto && a.id == agent { Label(a.name, systemImage: "checkmark") }
                else { Text(a.name) }
            }
        }
    }

    private var agentMenu: some View {
        Menu {
            agentMenuItems
        } label: {
            HStack(spacing: 12) {
                IconChip(icon: meta.icon, tint: theme.accent, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(meta.name)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(theme.textPrimary)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.textTertiary)
                    }
                    Text(label)
                        .font(.system(size: 13))
                        .foregroundStyle(litColor ?? theme.textTertiary)
                }
            }
        }
        .accessibilityIdentifier("agentLightSelector")
    }

    @ViewBuilder private var housing: some View {
        let size: CGFloat = orientation == .horizontal ? 14 : 13
        let lampViews = ForEach(lamps.indices, id: \.self) { i in
            Lamp(color: lamps[i].color, lit: lamps[i].lit, size: size)
        }
        Group {
            if orientation == .horizontal {
                HStack(spacing: 9) { lampViews }
            } else {
                VStack(spacing: 7) { lampViews }
            }
        }
        .padding(.horizontal, orientation == .horizontal ? 12 : 9)
        .padding(.vertical, orientation == .horizontal ? 8 : 9)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color(hex: 0x2A2F38)))
    }
}

/// 单盏灯。亮: 实色 + 左上高光 + 发光 + 轻微呼吸; 暗: 同色低透明度。
private struct Lamp: View {
    let color: Color
    let lit: Bool
    let size: CGFloat
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(lit ? color : color.opacity(0.22))
            .frame(width: size, height: size)
            .overlay(highlight)
            .shadow(color: lit ? color.opacity(0.6) : .clear, radius: lit ? size * 0.5 : 0)
            .opacity(lit && pulse ? 0.82 : 1)
            .onAppear { restart() }
            .onChange(of: lit) { _ in restart() }
    }

    @ViewBuilder private var highlight: some View {
        if lit {
            Circle().fill(.white.opacity(0.22))
                .frame(width: size * 0.32, height: size * 0.32)
                .offset(x: -size * 0.16, y: -size * 0.16)
        }
    }

    private func restart() {
        pulse = false
        guard lit else { return }
        withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) { pulse = true }
    }
}
