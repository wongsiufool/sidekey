import SwiftUI
import UIKit

/// 语音发送用到的连接能力 (SidekeyClient 实现; 单测里换成无网络的发送记录)。
@MainActor
protocol VoiceTransport: AnyObject {
    var isConnectedForVoice: Bool { get }
    var connectedComputerID: UUID? { get }
    func sendPasteTracked(_ text: String, timeout: TimeInterval, completion: @escaping (Bool, String?) -> Void)
    func sendKey(_ cap: KeyCap)
}

extension SidekeyClient: VoiceTransport {
    var isConnectedForVoice: Bool { status == .connected }
}

/// 窗口级的语音草稿 (§4.8、§5.1): 内屏三种形态和手机屏的 sheet **共用这一份**, 跨屏只换呈现方式, 文字不丢 (M3 审计 B7)。
/// 发送是一次「请求」, 发起时固定目标电脑、文字、回车设置和草稿版本; 回执只处理它自己那次请求 (M3 审计 B6):
/// - 等回执期间改了回车设置: 按发起时的设置决定要不要补 Enter;
/// - 等回执期间又编辑了文字: 成功回执不清掉新文字;
/// - 「清空」不能解除发送中的占用 (只清文字);
/// - 已经交给连接、之后断线 / 超时: 结果不确定 (可能已经打出来了), 不说「没发出去」。
@MainActor
final class VoiceDraft: ObservableObject {
    enum SendState: Equatable { case idle, sending, failed(String), uncertain(String) }
    @Published var text = "" { didSet { if text != oldValue { revision &+= 1; clearOutcome() } } }
    @Published private(set) var state: SendState = .idle
    /// 输入框的焦点意图和选区 (窗口级, 跨屏交接用, M3 审计 N-I3)。
    @Published var wantsFocus = false
    /// 成功次数: 手机 sheet 只在「这次请求成功」时关闭, 不能把「失败后清空文字」当成成功。
    @Published private(set) var successCount = 0
    var selection = NSRange(location: 0, length: 0)
    /// 当前负责编辑的那个输入框 (M3 审计 R-B1)。跨屏时新容器的输入框一建出来就接管;
    /// 旧的 (正在退场 / 已拆除) 输入框的回调一律不认, 不能改写草稿、选区和焦点意图。
    private(set) var editorToken: UUID?
    func claimEditor(_ t: UUID) { editorToken = t }
    func releaseEditor(_ t: UUID) { if editorToken == t { editorToken = nil } }

    private struct Request { let id: Int; let text: String; let autoEnter: Bool; let computer: UUID?; let revision: Int }
    private var request: Request?
    private var nextID = 0
    /// 每次文字变化 +1, 用来判断「发出之后有没有再编辑」。
    private(set) var revision = 0

    var isSending: Bool { state == .sending }

    /// 编辑或重新听写后, 去掉上一次的失败 / 不确定提示 (发送中的占用不受影响)。
    private func clearOutcome() {
        switch state { case .failed, .uncertain: state = .idle; default: break }
    }

    /// 「清空」: 只清文字; 发送中仍占用, 不能借清空重新开放发送。
    func clear() { text = "" }

    func send(via t: VoiceTransport, autoEnter: Bool) {
        let payload = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty, !isSending else { return }
        guard t.isConnectedForVoice else { state = .failed(Self.failMessage("disconnected")); return }   // 根本没交出去: 确定没发
        nextID &+= 1
        let r = Request(id: nextID, text: payload, autoEnter: autoEnter, computer: t.connectedComputerID, revision: revision)
        request = r
        state = .sending
        t.sendPasteTracked(payload, timeout: 4) { [weak self, weak t] ok, code in
            guard let self, self.request?.id == r.id else { return }          // 不是当前这次请求的回执: 不处理
            self.request = nil
            if ok {
                // 回车只发给发起时那台电脑, 并且按发起时的设置
                if r.autoEnter, let t, t.connectedComputerID == r.computer { t.sendKey(KeyCap(label: "Enter", code: "enter")) }
                if self.revision == r.revision { self.text = "" }            // 期间又编辑过: 保留新文字
                self.state = .idle
                self.successCount &+= 1
            } else if code == "timeout" || code == "lost" {
                self.state = .uncertain(String(localized: "可能没发出去：电脑没有回应，先看一眼再重试"))
            } else {
                self.state = .failed(Self.failMessage(code))
            }
        }
    }

    static func failMessage(_ code: String?) -> String {
        switch code {
        case "ax":           return String(localized: "电脑还没授权「辅助功能」, 文字没打出去。先在 Mac 上授权, 再点重试。")
        case "clipboard":    return String(localized: "电脑剪贴板暂时不可用, 没能粘贴。可重试, 或先复制到手机备用。")
        case "disconnected": return String(localized: "和电脑断开了, 没发出去。重连后重试, 文字已保留。")
        default:             return String(localized: "发送失败, 文字已保留。可重试, 或先复制到手机。")
        }
    }
}

/// 内屏的语音面板 (§4.8): 非模态, 背景照常可以操作。
/// - docked: 系统键盘没弹起时, 停靠在键盘区底部, 宽度等于键盘区 (UI 稿 11A);
/// - compact: 系统键盘挡住输入区时收成紧凑条 (高 136), 贴在键盘上方 (UI 稿 11·V);
/// - page: 紧凑条放不下必需控件时, 盖住整个窗口的语音页 (模态)。
/// 输入框在三种形态里位置不变 (同一个视图), 换形态时焦点和文字都保留, 不会把系统键盘收掉。
struct InnerVoicePanel: View {
    enum Style: Equatable { case docked, compact, page }
    let style: Style
    @ObservedObject var draft: VoiceDraft
    @ObservedObject var client: SidekeyClient
    /// 发起时锁定的目标电脑名 (§7: 异步请求在发起时锁定目标)。
    let targetName: String
    let onClose: () -> Void
    @Environment(\.sidekeyTheme) private var theme
    @AppStorage("sidekey.dictation.autoEnter") private var autoEnter = false

    private var trimmed: String { draft.text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var connected: Bool { client.status == .connected }
    /// 紧凑条和模态语音页用同一套紧凑排法 (模态页只是背景盖住整个窗口, 面板排在键盘以上的可见区域)。
    private var compact: Bool { style != .docked }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 12) {
            header
            HStack(alignment: .center, spacing: 8) {
                editor
                if compact { sendButton(width: 88, height: 72) }
            }
            .frame(maxHeight: compact ? 72 : .infinity)
            if !compact {
                Text("用系统键盘上的 🎤 说话，说完点「发送到电脑」")
                    .font(.system(size: 12.5)).foregroundStyle(theme.hint)
                HStack(spacing: 10) {
                    Button { draft.clear() } label: {
                        Text("清空").font(.system(size: 15)).foregroundStyle(theme.textSecondary)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .overlay(Capsule().strokeBorder(theme.hairline, lineWidth: 1))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    sendButton(width: nil, height: 44)
                }
            }
        }
        .padding(compact ? EdgeInsets(top: 4, leading: 12, bottom: 12, trailing: 12) : EdgeInsets(top: 14, leading: 20, bottom: 16, trailing: 20))
        .background(RoundedRectangle(cornerRadius: theme.radiusCard, style: .continuous).fill(theme.surface).raisedShadow(theme))
        .overlay(RoundedRectangle(cornerRadius: theme.radiusCard, style: .continuous).strokeBorder(theme.hairline, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("innerVoicePanel")
    }

    // MARK: 顶行: 目标电脑 (可截断)、发送后回车开关、收起键盘、关闭 —— 后三个都是不压缩的 44 × 44
    private var header: some View {
        HStack(spacing: 6) {
            if !compact {
                Text("语音输入").font(.system(size: 16, weight: .bold)).foregroundStyle(theme.textPrimary)
            }
            Text(String(localized: "语音 → \(targetName)"))
                .font(.system(size: 12)).foregroundStyle(theme.accentInk)
                .lineLimit(1).truncationMode(.tail)
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 10).fill(theme.accentLight.opacity(0.5)))
                .layoutPriority(-1)
            Spacer(minLength: 0)
            Button { autoEnter.toggle() } label: {
                HStack(spacing: 4) {
                    Image(systemName: autoEnter ? "checkmark" : "return").font(.system(size: 12, weight: .bold))
                    Text(autoEnter ? String(localized: "回车：开") : String(localized: "回车：关")).font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(autoEnter ? theme.accentInk : theme.textSecondary)
                .padding(.horizontal, 9).frame(height: 28)
                .background(Capsule().fill(autoEnter ? theme.accentLight.opacity(0.5) : theme.surfaceMuted))
                .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .accessibilityLabel(String(localized: "发送后回车"))
            .accessibilityValue(autoEnter ? String(localized: "开") : String(localized: "关"))
            .accessibilityAddTraits(.isButton)                  // iOS 16 没有 .isToggle; 状态由 accessibilityValue 读出
            if compact {
                iconButton("keyboard.chevron.compact.down", label: String(localized: "收起键盘"), id: "voiceHideKeyboard") { draft.wantsFocus = false }
            }
            iconButton("xmark", label: String(localized: "关闭"), id: "voiceClose") { draft.wantsFocus = false; onClose() }
        }
        .frame(height: 44)
    }

    private func iconButton(_ icon: String, label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 17, weight: .medium)).foregroundStyle(theme.textSecondary)
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    // MARK: 文字框 (可滚动); 失败 / 不确定时在上方提示, 长按可复制
    private var editor: some View {
        VStack(alignment: .leading, spacing: 2) {
            switch draft.state {
            case .failed(let msg):
                Text(msg).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.dangerText).lineLimit(2)
            case .uncertain(let msg):
                Text(msg).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.warningText).lineLimit(2)
            default:
                EmptyView()
            }
            VoiceTextView(draft: draft, fontSize: compact ? 14 : 15, textColor: UIColor(theme.textPrimary), identifier: "voiceText")
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.surfaceMuted))
    }

    // MARK: 发送: 发送中不能再点; 没发出 → 「重试」; 超时不确定 → 「重试」并提示先看电脑
    private func sendButton(width: CGFloat?, height: CGFloat) -> some View {
        let sending = draft.state == .sending
        let retry: Bool = { if case .failed = draft.state { return true }; if case .uncertain = draft.state { return true }; return false }()
        return Button(action: send) {
            Group {
                if compact {
                    VStack(spacing: 4) {
                        if sending { ProgressView() } else { Image(systemName: "arrow.right").font(.system(size: 18, weight: .bold)) }
                        Text(sending ? String(localized: "发送中") : (retry ? String(localized: "重试") : String(localized: "发送"))).font(.system(size: 13, weight: .semibold))
                    }
                } else {
                    Text(sending ? String(localized: "发送中…") : (retry ? String(localized: "重试发送") : String(localized: "发送到电脑")))
                        .font(.system(size: 15, weight: .semibold))
                }
            }
            .foregroundStyle(sending ? theme.accentInk : theme.accentText)
            .frame(maxWidth: width ?? .infinity, minHeight: height, maxHeight: height)
            .frame(width: width)
            .background(RoundedRectangle(cornerRadius: compact ? 16 : height / 2).fill(sending ? theme.accentLight : theme.accent))
            .opacity(trimmed.isEmpty || !connected ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .disabled(trimmed.isEmpty || !connected || sending)
        .layoutPriority(1)
        .accessibilityIdentifier("voiceSend")
    }

    private func send() { draft.send(via: client, autoEnter: autoEnter) }
}

/// 系统键盘在**本窗口坐标**里的 frame (§3.8 第 2 条: 按和本窗口的交集避让; 收起后高 0)。
struct KeyboardFrameReader: UIViewRepresentable {
    let onChange: (CGRect) -> Void

    func makeUIView(context: Context) -> ReaderView { ReaderView(onChange: onChange) }
    func updateUIView(_ v: ReaderView, context: Context) { v.onChange = onChange }

    final class ReaderView: UIView {
        var onChange: (CGRect) -> Void
        init(onChange: @escaping (CGRect) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            let nc = NotificationCenter.default
            nc.addObserver(self, selector: #selector(changed(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
            nc.addObserver(self, selector: #selector(hidden(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
        }
        required init?(coder: NSCoder) { fatalError() }

        @objc private func changed(_ n: Notification) {
            guard let w = window, let end = n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            let inWindow = w.convert(end, from: w.screen.coordinateSpace)       // 屏幕坐标 → 窗口坐标
            let cb = onChange
            DispatchQueue.main.async { cb(inWindow) }
        }
        @objc private func hidden(_ n: Notification) {
            let cb = onChange
            DispatchQueue.main.async { cb(.zero) }
        }
    }
}

enum DuoVoicePanelMetrics {
    /// 停靠在键盘区底部时的高度 (UI 稿 11A: 307), 键盘区更矮时占满键盘区。
    static let dockedHeight: CGFloat = 307
}

/// 语音输入框 (内屏面板和手机 sheet 共用): 文字、**焦点和选区**都存在窗口级的 VoiceDraft 里 (M3 审计 N-I3)。
/// - 跨屏换容器时, 新输入框按草稿恢复选区; 原来键盘是收起的就不自动弹出;
/// - 用户自己收起键盘 (输入框还在窗口里时结束编辑) 才记成「不要焦点」; 容器被换掉时的结束编辑不算;
/// - 中文输入法还没上屏的拼音不保留。
struct VoiceTextView: UIViewRepresentable {
    @ObservedObject var draft: VoiceDraft
    var fontSize: CGFloat
    var textColor: UIColor
    var identifier: String

    /// 进 / 出窗口时通知协调器 (sheet 呈现动画中途 becomeFirstResponder 会失败, 进窗口后再申请一次)
    final class FocusTextView: UITextView {
        var onWindowChange: (() -> Void)?
        override func didMoveToWindow() { super.didMoveToWindow(); onWindowChange?() }
    }

    func makeUIView(context: Context) -> UITextView {
        let v = FocusTextView()
        v.backgroundColor = .clear
        v.accessibilityIdentifier = identifier
        let c = context.coordinator
        c.view = v
        v.onWindowChange = { [weak c] in c?.scheduleFocus() }
        c.applyStyle(v)
        c.applying { v.text = draft.text; v.selectedRange = c.clamped(draft.selection, in: v) }
        v.delegate = c                                                   // 恢复完文字和选区再接代理, 恢复本身不回写
        draft.claimEditor(c.token)                                       // 新容器的输入框接管编辑 (R-B1)
        c.scheduleFocus()                                                // 进窗口后再决定要不要焦点
        return v
    }

    func updateUIView(_ v: UITextView, context: Context) {
        let c = context.coordinator
        c.parent = self
        c.applyStyle(v)                                                  // 停靠 / 紧凑、明暗主题切换后同步字号和颜色 (R-I3)
        if c.isEditor, v.text != draft.text, v.markedTextRange == nil {
            c.applying { v.text = draft.text; v.selectedRange = c.clamped(draft.selection, in: v) }
        }
        if c.focusMismatch { c.scheduleFocus() }                         // 不在视图更新里同步改焦点
    }

    static func dismantleUIView(_ v: UITextView, coordinator: Coordinator) {
        coordinator.dismantled = true
        v.delegate = nil
        coordinator.parent.draft.releaseEditor(coordinator.token)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor final class Coordinator: NSObject, UITextViewDelegate {
        var parent: VoiceTextView
        weak var view: UITextView?
        var dismantled = false
        let token = UUID()
        private var focusScheduled = false
        private var focusRetries = 0
        private var programmatic = false
        init(_ p: VoiceTextView) { parent = p }

        /// 只有「当前负责编辑、还没拆除」的输入框才能动草稿。
        var isEditor: Bool { !dismantled && parent.draft.editorToken == token }
        var focusMismatch: Bool {
            guard isEditor, let v = view, v.window != nil else { return false }
            return parent.draft.wantsFocus != v.isFirstResponder
        }

        func applying(_ body: () -> Void) { programmatic = true; body(); programmatic = false }
        func clamped(_ r: NSRange, in v: UITextView) -> NSRange {
            let len = (v.text as NSString).length, loc = min(r.location, len)
            return NSRange(location: loc, length: max(0, min(r.length, len - loc)))
        }
        func applyStyle(_ v: UITextView) {
            if v.font?.pointSize != parent.fontSize { v.font = .systemFont(ofSize: parent.fontSize) }
            if v.textColor != parent.textColor { v.textColor = parent.textColor }
        }

        /// 焦点申请放到下一轮主循环, 多次申请合并成一次 (R-B1)。
        /// 呈现动画中途拿不到焦点时, 隔 0.15 秒再试, 最多 10 次 (不会无限重试)。
        func scheduleFocus(after delay: TimeInterval = 0) {
            guard !focusScheduled else { return }
            focusScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.focusScheduled = false
                guard self.isEditor, let v = self.view, v.window != nil else { return }
                if self.parent.draft.wantsFocus, !v.isFirstResponder {
                    if v.becomeFirstResponder() { self.focusRetries = 0 }
                    else if self.focusRetries < 10 { self.focusRetries += 1; self.scheduleFocus(after: 0.15) }
                }
                if !self.parent.draft.wantsFocus, v.isFirstResponder { v.resignFirstResponder() }
            }
        }

        // 代理回调: 先认身份; 程序同步引起的回调不回写; 值没变不写 (@Published 每次赋值都会触发刷新)
        func textViewDidChange(_ v: UITextView) {
            guard isEditor, !programmatic, v.window != nil, v.markedTextRange == nil, parent.draft.text != v.text else { return }
            parent.draft.text = v.text
        }
        func textViewDidChangeSelection(_ v: UITextView) {
            guard isEditor, !programmatic, v.window != nil, parent.draft.selection != v.selectedRange else { return }
            parent.draft.selection = v.selectedRange
        }
        func textViewDidBeginEditing(_ v: UITextView) {
            // 没有任何输入框在负责 (都已拆除) 时, 仍在场的这个开始编辑就重新接管
            // 接管前输入框里的文字可能是旧的 (没人负责期间 updateUIView 不同步, 草稿可能已被回执清空): 先对齐到草稿, 免得把已发送的文字带回来
            if !dismantled, parent.draft.editorToken == nil, v.window != nil {
                parent.draft.claimEditor(token)
                if v.text != parent.draft.text, v.markedTextRange == nil {
                    applying { v.text = parent.draft.text; v.selectedRange = clamped(parent.draft.selection, in: v) }
                }
            }
            guard isEditor, !parent.draft.wantsFocus else { return }
            parent.draft.wantsFocus = true
        }
        func textViewDidEndEditing(_ v: UITextView) {
            // 不在这里回写文字: 文字已在 textViewDidChange 里同步; 拆除 / 换容器时系统也会调这里,
            // 那时草稿可能已经被回执清空或改成新文字, 回写会把旧文字带回来 (R-B1)
            guard isEditor else { return }
            // 之后这个输入框仍负责编辑、还在窗口里、也没重新拿到焦点 = 用户收起了键盘; 被接管 / 移走 = 跨屏换容器, 保持原来的焦点意图
            DispatchQueue.main.async { [weak self, weak v] in
                guard let self, let v, self.isEditor, v.window != nil, !v.isFirstResponder, self.parent.draft.wantsFocus else { return }
                self.parent.draft.wantsFocus = false
            }
        }
    }
}
