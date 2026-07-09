import SwiftUI

/// Claude Code Effort(思考力度)选择面板 (自绘卡片, 与权限面板同款)。
/// 选中后回调 onSelect(level): 调用方发 `/effort <级别>` 并持久化本地显示状态。
/// 说明: App 读不到 Claude Code 真实档位, 显示的是用户最后设定的级别。
struct EffortPaletteView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.sidekeyTheme) private var theme
    let current: EffortLevel
    let onSelect: (EffortLevel) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 14) {
                    SoftPanel(padding: 0) {
                        VStack(spacing: 0) {
                            ForEach(Array(EffortLevel.allCases.enumerated()), id: \.element) { i, level in
                                if i > 0 { RowDivider(inset: 16) }
                                row(level)
                            }
                        }
                    }
                    Text("发送 /effort <级别> 斜杠命令设置。App 读不到 Claude Code 真实档位, 显示的是「上次由本机设定」的级别; 若在电脑上另行改过可能错位, 重选一次即可校正。ultracode 仅当前会话有效。")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }
                .padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 20)
            }
        }
        .background(theme.bgGradient.ignoresSafeArea())
        .accessibilityIdentifier("effortPalette")
    }

    private var header: some View {
        VStack(spacing: 4) {
            HStack {
                Text("Effort 档位").font(.system(size: 20, weight: .semibold)).foregroundStyle(theme.textPrimary)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(theme.textSecondary).frame(width: 40, height: 40)
                        .background(Circle().fill(theme.surfaceMuted))
                }.buttonStyle(.plain)
            }
            HStack {
                Text("Claude Code · /effort 思考力度")
                    .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                Spacer()
            }
        }
        .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)
    }

    private func row(_ level: EffortLevel) -> some View {
        let selected = level == current
        return Button {
            onSelect(level)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(level.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                    Text(level.detail)
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if selected {
                    LastRequestedTag()   // 上次本机设定, 非电脑实时状态 (审计 M-8)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(selected ? theme.accentLight.opacity(0.55) : .clear)
                    .padding(.horizontal, 6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("effort_\(level.rawValue)")
    }
}
