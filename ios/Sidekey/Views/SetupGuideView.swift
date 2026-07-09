import SwiftUI

/// 首启引导 (1.0.1): 讲清 Sidekey 是「伴侣 App」——必须先在电脑上装一个免费小助手, 再扫码连。
/// 触发: 全新用户(还没配过任何电脑)首次进主界面弹一次; 之后可从「电脑列表」或「设置 › 帮助」里再打开。
/// onScan: 用户点「现在扫码」时回调(由调用方决定是否打开电脑列表/配对); 自身只负责 dismiss。
struct SetupGuideView: View {
    var onScan: () -> Void = {}
    /// 「我已装好, 现在扫码」CTA。参考型入口(设置 › 帮助 / 关于页)传 false 隐藏它——
    /// 那里退回后没有扫码入口, 留着会是死路; 首启/电脑列表处保持 true。
    var showScanCTA: Bool = true
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.sidekeyTheme) private var theme

    /// 电脑端小助手获取页(同时有 Mac/Windows 下载 + 上手说明)。
    /// 注意: 目前托管在 GitHub Pages, 中国大陆访问可能受限 —— 接入国内镜像后改这里(或按地区切换 URL)。
    private let helperPageURL = URL(string: "https://wongsiufool.github.io/sidekey/support.html")!

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: String(localized: "连接你的电脑"), onClose: { dismiss() })
                .padding(.horizontal, 20)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Sidekey 需要先在你的电脑上运行一个免费的小助手, 手机才能控制它。三步就能连上:")
                        .font(.system(size: 14)).foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)

                    stepRow(1, String(localized: "电脑上装小助手"),
                            String(localized: "在你的 Mac 或 Windows 上下载并打开免费的 Sidekey 小助手。"))
                    stepRow(2, String(localized: "它会显示二维码"),
                            String(localized: "小助手打开后, 屏幕上会出现一个配对二维码。"))
                    stepRow(3, String(localized: "回手机扫码即连"),
                            String(localized: "回到这里, 点「添加电脑」对准那个二维码, 就连上了。"))

                    VStack(spacing: 10) {
                        CoralButton(title: String(localized: "在电脑上获取小助手"), icon: "desktopcomputer") {
                            openURL(helperPageURL)
                        }
                        if showScanCTA {
                            OutlineButton(title: String(localized: "我已装好, 现在扫码"), icon: "qrcode.viewfinder") {
                                dismiss(); onScan()
                            }
                        }
                    }
                    .padding(.top, 6)

                    // 链接文本兜底: 按钮点不开(或换设备)时也能手抄地址。
                    VStack(alignment: .leading, spacing: 4) {
                        Text("电脑端下载地址:").font(.system(size: 12)).foregroundStyle(theme.textTertiary)
                        Text(verbatim: helperPageURL.absoluteString)
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(theme.accent)
                            .textSelection(.enabled)
                    }
                    .padding(.top, 2)

                    Text("提示: 之后也能在「电脑列表」里再打开这个说明。")
                        .font(.system(size: 12)).foregroundStyle(theme.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 8)
                }
                .padding(.horizontal, 20).padding(.bottom, 24)
            }
        }
        .background(theme.bgGradient.ignoresSafeArea())
        .presentationDetents([.large])
    }

    private func stepRow(_ n: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(n)")
                .font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Circle().fill(theme.accent))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.textPrimary)
                Text(detail).font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: theme.radiusCard, style: .continuous)
            .fill(theme.surface).raisedShadow(theme))
        .overlay(RoundedRectangle(cornerRadius: theme.radiusCard, style: .continuous)
            .strokeBorder(theme.hairline, lineWidth: 1))
    }
}
