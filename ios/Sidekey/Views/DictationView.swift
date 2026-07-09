import SwiftUI
import UIKit

/// 语音输入 (brief D3): 148 软方麦克风 + 同心圆波纹 + 波形 + 识别预览卡 + 语言 + 底部「发送到电脑」。
/// 仍走系统键盘听写: 点麦克风聚焦输入框 → 按手机键盘 🎤 说话。录音/发送/关闭逻辑不变。
struct DictationView: View {
    @ObservedObject var client: SidekeyClient
    @Environment(\.dismiss) private var dismiss
    @Environment(\.sidekeyTheme) private var theme

    @State private var text = ""
    @FocusState private var focused: Bool
    @AppStorage("sidekey.dictation.autoEnter") private var autoEnter = false
    @State private var sending = false        // 正在等电脑端回执
    @State private var sendError: String?     // 失败原因 (审计 M-5: 失败不丢文字)
    @State private var copiedToPhone = false  // 已把文字复制到手机剪贴板

    private var connected: Bool { client.status == .connected }
    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: String(localized: "语音输入"), onClose: { dismiss() }).padding(.horizontal, 20)

            ScrollView {
                VStack(spacing: 18) {
                    micButton.padding(.top, 8)
                    Text("轻点开始说话").font(.system(size: 17, weight: .semibold)).foregroundStyle(theme.textPrimary)
                    Text("点麦克风 → 按手机键盘上的 🎤 说话 → 文字出来后发送到电脑。")
                        .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                        .multilineTextAlignment(.center).padding(.horizontal, 20)

                    waveform

                    VStack(alignment: .leading, spacing: 8) {
                        Text("识别预览").font(.system(size: 13, weight: .medium)).foregroundStyle(theme.textTertiary)
                        SoftPanel {
                            TextEditor(text: $text)
                                .scrollContentBackground(.hidden)
                                .font(.system(size: 17)).foregroundStyle(theme.textPrimary)
                                .frame(minHeight: 90)
                                .focused($focused)
                                .overlay(alignment: .topLeading) {
                                    if text.isEmpty {
                                        Text("说点什么, 比如「帮我总结这段代码」")
                                            .font(.system(size: 17)).foregroundStyle(theme.textTertiary)
                                            .padding(.top, 8).padding(.leading, 5).allowsHitTesting(false)
                                    }
                                }
                        }
                        HStack(spacing: 8) {
                            Image(systemName: "globe").font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                            Text("中文 (普通话)").font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                            Spacer()
                            Toggle(isOn: $autoEnter) { Text("发送后加回车").font(.system(size: 13)).foregroundStyle(theme.textSecondary) }
                                .tint(theme.accent).fixedSize()
                        }
                        .padding(.horizontal, 4)
                    }

                    if !connected {
                        Text("⚠️ 未连接电脑, 请先回主界面连接。")
                            .font(.system(size: 13)).foregroundStyle(theme.warning)
                    }

                    if let sendError {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 14)).foregroundStyle(theme.danger)
                                Text(sendError).font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                            }
                            Button {
                                UIPasteboard.general.string = trimmed
                                copiedToPhone = true
                            } label: {
                                Label(copiedToPhone ? "已复制到手机" : "复制到手机剪贴板",
                                      systemImage: copiedToPhone ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.accent)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 12).fill(theme.danger.opacity(0.10)))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.danger.opacity(0.3), lineWidth: 1))
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 16)
            }

            CoralButton(title: sending ? String(localized: "发送中…") : (sendError == nil ? String(localized: "发送到电脑") : String(localized: "重试发送")),
                        icon: "paperplane.fill",
                        enabled: !trimmed.isEmpty && connected && !sending) { send() }
                .padding(.horizontal, 20).padding(.top, 6).padding(.bottom, 12)
        }
        .background(theme.bgGradient.ignoresSafeArea())
        .onAppear { focused = true }
        .onChange(of: text) { _ in            // 编辑/重新听写后清掉旧错误与复制态
            if sendError != nil { sendError = nil; copiedToPhone = false }
        }
    }

    private var micButton: some View {
        Button { focused = true } label: {
            ZStack {
                ForEach(0..<2) { i in
                    Circle().stroke(theme.accent.opacity(0.18 - Double(i) * 0.07), lineWidth: 2)
                        .frame(width: 148 + CGFloat(i) * 34, height: 148 + CGFloat(i) * 34)
                }
                RoundedRectangle(cornerRadius: 36, style: .continuous)
                    .fill(theme.surface).raisedShadow(theme)
                    .frame(width: 148, height: 148)
                    .overlay(RoundedRectangle(cornerRadius: 36, style: .continuous).strokeBorder(theme.hairline, lineWidth: 1))
                    .overlay(Image(systemName: "mic.fill").font(.system(size: 58, weight: .medium)).foregroundStyle(theme.accent))
            }
            .frame(height: 182)
        }
        .buttonStyle(.plain)
    }

    private var waveform: some View {
        HStack(spacing: 4) {
            ForEach(0..<22, id: \.self) { i in
                Capsule().fill(theme.accent.opacity(0.55))
                    .frame(width: 3, height: barHeight(i))
            }
        }
        .frame(height: 30)
    }
    private func barHeight(_ i: Int) -> CGFloat {
        let p = [8.0,14,20,12,26,16,22,10,28,18,24,14,26,12,22,16,20,10,18,14,12,8]
        return CGFloat(p[i % p.count])
    }

    private func send() {
        guard !trimmed.isEmpty, !sending else { return }
        let payload = trimmed
        sending = true
        sendError = nil
        copiedToPhone = false
        // 等电脑端回执再决定: 打出来了才清空+关闭; 没打出来就保留文字 + 给原因 + 可重试/复制 (审计 M-5)。
        client.sendPasteTracked(payload) { ok, code in
            sending = false
            if ok {
                if autoEnter { client.sendKey(KeyCap(label: "Enter", code: "enter")) }
                text = ""
                dismiss()
            } else {
                sendError = Self.failMessage(code)
            }
        }
    }

    private static func failMessage(_ code: String?) -> String {
        switch code {
        case "ax":           return String(localized: "电脑还没授权「辅助功能」, 文字没打出去。先在 Mac 上授权, 再点重试。")
        case "clipboard":    return String(localized: "电脑剪贴板暂时不可用, 没能粘贴。可重试, 或先复制到手机备用。")
        case "timeout":      return String(localized: "电脑没有及时回应, 不确定是否打出。文字已保留, 可重试或复制到手机。")
        case "disconnected": return String(localized: "和电脑断开了, 没发出去。重连后重试, 文字已保留。")
        default:             return String(localized: "发送失败, 文字已保留。可重试, 或先复制到手机。")
        }
    }
}
