import SwiftUI

/// 存档读不出来时的恢复页 (§6.4 第 5 条): 原始数据已另存备份且没有被覆盖; 用户可以导出, 或用全新数据继续。
/// `.main`: 主存档 `sidekey.app.v5`; `.large`: 大屏键位 `sidekey.large.v1` (主存档照常可用)。
struct RecoveryView: View {
    enum Which { case main, large }
    @ObservedObject var store: LayoutStore
    var which: Which = .main
    @Environment(\.sidekeyTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var exportURL: URL?
    @State private var confirmingDiscard = false

    private var rawData: Data? { which == .main ? store.recovery?.rawData : store.largeRecovery?.rawData }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40)).foregroundStyle(theme.warning)
            Text(which == .main ? LocalizedStringKey("存档无法读取") : LocalizedStringKey("大屏键位无法读取"))
                .font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(theme.textPrimary)
            Text(which == .main
                 ? LocalizedStringKey("原始数据已另外备份，没有被覆盖。你可以先导出它留作检查，或用全新数据继续使用（原来的电脑与键位需要重新配置）。")
                 : LocalizedStringKey("内屏使用的大屏键位读不出来。原始数据已另外备份，没有被覆盖；电脑、模式和手机屏的键位都正常。你可以先导出它留作检查，或者继续：大屏键位会在内屏打开各模式时按原键位重新生成。"))
                .font(.system(size: 15)).foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
            if let url = exportURL {
                ShareLink(item: url) {
                    Label("导出原始数据", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
            }
            CoralButton(title: which == .main ? String(localized: "使用全新数据继续") : String(localized: "丢弃并重新生成大屏键位")) {
                if which == .main { store.resolveRecoveryWithFreshData() } else { confirmingDiscard = true }
            }
            if which == .large {
                Button("稍后再说") { dismiss() }
                    .font(.system(size: 15, weight: .medium)).foregroundStyle(theme.textSecondary)
                    .frame(minHeight: 44)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.bgGradient.ignoresSafeArea())
        .onAppear {
            guard exportURL == nil, let raw = rawData else { return }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(which == .main ? "sidekey-store-v5-backup.json" : "sidekey-large-v1-backup.json")
            if (try? raw.write(to: url, options: .atomic)) != nil { exportURL = url }
        }
        .confirmationDialog("丢弃大屏键位的原始数据?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("丢弃并重新生成", role: .destructive) { store.resolveLargeRecoveryWithFreshData() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会丢弃全部大屏键位的原始数据（已另外备份），之后在内屏打开各模式时按原键位重新生成。原键位不受影响。")
        }
        .interactiveDismissDisabled(which == .main)         // 主存档读不出来时必须先处理; 大屏键位的可以先关掉 (手机屏照常用)
        .onChange(of: store.largeRecovery == nil) { resolved in if which == .large && resolved { dismiss() } }
    }
}
