import SwiftUI
import UIKit

/// 关于页: 身份 + 一句话介绍 + 隐私一览 + 链接 + 版本信息(可复制) + 署名。
/// 入口: 设置 › 帮助 › 关于 Sidekey。链接托管在 GitHub Pages。版本号从 Bundle 动态读, 发版自动更新。
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.sidekeyTheme) private var theme
    @State private var copied = false
    @State private var showGuide = false

    private let siteURL = URL(string: "https://wongsiufool.github.io/sidekey/")!
    private let privacyURL = URL(string: "https://wongsiufool.github.io/sidekey/privacy.html")!

    /// "1.0.0 (4)" —— 从 Info.plist 读, 不硬编码。
    private var version: String {
        let d = Bundle.main.infoDictionary
        let v = d?["CFBundleShortVersionString"] as? String ?? "—"
        let b = d?["CFBundleVersion"] as? String ?? "—"
        return "\(v) (\(b))"
    }
    /// 一行诊断信息, 供反馈时复制。
    private var diagnostics: String {
        "Sidekey \(version) · iOS \(UIDevice.current.systemVersion) · \(deviceModel)"
    }
    private var deviceModel: String {
        var s = utsname(); uname(&s)
        let bytes = withUnsafeBytes(of: &s.machine) { Data($0) }
        return String(bytes: bytes.prefix(while: { $0 != 0 }), encoding: .utf8) ?? "—"
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: String(localized: "关于"), onClose: { dismiss() })
                .padding(.horizontal, 20)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    Text("Sidekey 把你的 iPhone 变成自己电脑的无线键盘、快捷键、触控板和麦克风, 全程走本地 Wi-Fi。它需要在你的电脑上运行一个免费的小助手。")
                        .font(.system(size: 14)).foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    privacyCard
                    linksCard
                    versionCard
                    footer
                }
                .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 28)
            }
        }
        .background(theme.bgGradient.ignoresSafeArea())
        .presentationDetents([.large])
        .sheet(isPresented: $showGuide) { SetupGuideView(showScanCTA: false) }   // 参考型入口: 隐藏「现在扫码」
    }

    // MARK: - 头部
    private var header: some View {
        VStack(spacing: 8) {
            BrandMark(size: 30)
            Text(verbatim: version)
                .font(.system(size: 13, weight: .medium)).foregroundStyle(theme.textTertiary)
            Text("你的电脑, 触手可及")
                .font(.system(size: 14)).foregroundStyle(theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    // MARK: - 隐私一览
    private var privacyCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: String(localized: "隐私"))
            SoftPanel {
                VStack(alignment: .leading, spacing: 12) {
                    privRow(String(localized: "无账号、无登录"))
                    privRow(String(localized: "不收集、不上传任何个人数据"))
                    privRow(String(localized: "无分析、无追踪、无第三方 SDK"))
                    privRow(String(localized: "按键只发给你自己配对的电脑, 不经过我们的服务器"))
                    Button { openURL(privacyURL) } label: {
                        HStack(spacing: 6) {
                            Text("查看完整隐私政策").font(.system(size: 14, weight: .medium))
                            Image(systemName: "arrow.up.right").font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(theme.accent)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
                .padding(4)
            }
        }
    }

    private func privRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark").font(.system(size: 13, weight: .bold))
                .foregroundStyle(theme.accent).padding(.top, 2)
            Text(text).font(.system(size: 14)).foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: - 链接
    private var linksCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: String(localized: "链接"))
            SoftPanel(padding: 0) {
                VStack(spacing: 0) {
                    linkRow(String(localized: "官网"), "globe") { openURL(siteURL) }
                    RowDivider(inset: 16)
                    linkRow(String(localized: "隐私政策"), "lock.shield") { openURL(privacyURL) }
                    RowDivider(inset: 16)
                    // 复用「电脑列表 / 设置」里同一个引导, 内嵌 sheet 打开。
                    linkRow(String(localized: "连接电脑 · 安装小助手"), "desktopcomputer",
                            external: false) { showGuide = true }
                }
            }
        }
    }

    private func linkRow(_ title: String, _ icon: String, external: Bool = true,
                         _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 15)).foregroundStyle(theme.accent).frame(width: 22)
                Text(title).font(.system(size: 16)).foregroundStyle(theme.textPrimary)
                Spacer(minLength: 8)
                Image(systemName: external ? "arrow.up.right" : "chevron.right")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.textTertiary)
            }
            .padding(.horizontal, 16).frame(minHeight: 54).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 版本信息(点按复制)
    private var versionCard: some View {
        SoftPanel(padding: 0) {
            Button {
                UIPasteboard.general.string = diagnostics
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation { copied = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { withAnimation { copied = false } }
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(copied ? String(localized: "已复制") : String(localized: "点按可复制版本信息"))
                            .font(.system(size: 12)).foregroundStyle(copied ? theme.accent : theme.textTertiary)
                        Text(verbatim: diagnostics)
                            .font(.system(size: 13, weight: .medium)).foregroundStyle(theme.textSecondary)
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                        .font(.system(size: 15)).foregroundStyle(copied ? theme.accent : theme.textTertiary)
                }
                .padding(.horizontal, 16).frame(minHeight: 56).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("copyDiagnostics")
        }
    }

    // MARK: - 署名
    private var footer: some View {
        VStack(spacing: 4) {
            Text("由 wongsiufool 独立开发")
                .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
            Text(verbatim: "© 2026 wongsiufool")
                .font(.system(size: 12)).foregroundStyle(theme.textTertiary)
            Text("谢谢你用 Sidekey ❤️")
                .font(.system(size: 13)).foregroundStyle(theme.textTertiary)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }
}
