import SwiftUI

/// Claude Code 权限模式选择面板 (自绘卡片, 不用系统 List/Form)。
/// 真实机制是 **Shift+Tab 循环**(default→acceptEdits→plan, 加 extras 后 …→bypass→auto)。
/// 选中后回调 onSelect(mode): 调用方据「上次档位 → 目标档位」算出要按几次 Shift+Tab 并下发, 同时持久化本地显示状态。
/// 核心 3 档始终可用; auto/bypass 仅在 Claude Code 会话启用后才进循环 —— 用 extras 开关纳入, 默认关 (安全 3 档)。
struct PermissionPaletteView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.sidekeyTheme) private var theme
    let current: PermissionMode
    @Binding var extras: Bool
    let onSelect: (PermissionMode) -> Void

    private func isActive(_ m: PermissionMode) -> Bool { m.isCore || extras }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 14) {
                    SoftPanel(padding: 0) {
                        VStack(spacing: 0) {
                            ForEach(Array(PermissionMode.allCases.enumerated()), id: \.element) { i, mode in
                                if i > 0 { RowDivider(inset: 16) }
                                row(mode)
                            }
                        }
                    }
                    extrasToggle
                    Text("切换用真实的 Shift+Tab 循环。App 读不到 Claude Code 真实当前模式, 显示的是「上次由本机设定」的档位; 若你也在电脑上按 Shift+Tab 可能错位, 重选一次即可校正。")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }
                .padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 20)
            }
        }
        .background(theme.bgGradient.ignoresSafeArea())
        .accessibilityIdentifier("permissionPalette")
    }

    private var header: some View {
        VStack(spacing: 4) {
            HStack {
                Text("权限模式").font(.system(size: 20, weight: .semibold)).foregroundStyle(theme.textPrimary)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(theme.textSecondary).frame(width: 40, height: 40)
                        .background(Circle().fill(theme.surfaceMuted))
                }.buttonStyle(.plain)
            }
            HStack {
                Text("Claude Code · Shift+Tab 循环切换")
                    .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                Spacer()
            }
        }
        .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)
    }

    @ViewBuilder private func row(_ mode: PermissionMode) -> some View {
        let active = isActive(mode)
        let selected = mode == current
        Button {
            guard active else { return }
            onSelect(mode)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(mode.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                    Text(active ? mode.detail : mode.setupNote)
                        .font(.system(size: 13))
                        .foregroundStyle(active ? theme.textSecondary : theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if selected && active {
                    // 不用「勾」(会被理解成「电脑当前就是这个」); App 读不到 Claude 真实状态, 只能说这是上次由本机请求的档位 (审计 M-8)。
                    LastRequestedTag()
                } else if !active {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textTertiary)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(selected && active ? theme.accentLight.opacity(0.55) : .clear)
                    .padding(.horizontal, 6)
            )
            .contentShape(Rectangle())
            .opacity(active ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .disabled(!active)
        .accessibilityIdentifier("permission_\(mode.rawValue)")
    }

    private var extrasToggle: some View {
        Toggle(isOn: $extras) {
            VStack(alignment: .leading, spacing: 2) {
                Text("我已在 Claude Code 启用 Auto / Bypass")
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(theme.textPrimary)
                Text("纳入 Shift+Tab 循环 (默认关 = 只切 3 档核心模式)")
                    .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
            }
        }
        .tint(theme.accent)
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(theme.surfaceMuted))
        .accessibilityIdentifier("permissionExtrasToggle")
    }
}
