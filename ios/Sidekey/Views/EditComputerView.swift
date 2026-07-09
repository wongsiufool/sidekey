import SwiftUI

/// 新增 / 编辑一台电脑 (brief B3): 4 字段置于一个 SoftPanel(每行 58pt + 内部分隔线); 扫码软按钮; 帮助卡; 底部「保存并连接」。
struct EditComputerView: View {
    @ObservedObject var store: LayoutStore
    @ObservedObject var client: SidekeyClient
    let existing: Computer?
    var onSaved: (UUID) -> Void
    /// 删除这台电脑后回调 (让父层的连接协调器重新对齐 socket; 修审计 H-2)。
    var onDeleted: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @Environment(\.sidekeyTheme) private var theme

    @State private var name: String
    @State private var host: String
    @State private var port: String
    @State private var token: String
    @State private var fingerprint: String
    @State private var showScan = false

    init(store: LayoutStore, client: SidekeyClient, existing: Computer?,
         prefill: (name: String, host: String, port: Int)? = nil,
         onSaved: @escaping (UUID) -> Void = { _ in },
         onDeleted: @escaping () -> Void = {}) {
        _store = ObservedObject(wrappedValue: store)
        _client = ObservedObject(wrappedValue: client)
        self.existing = existing
        self.onSaved = onSaved
        self.onDeleted = onDeleted
        _name = State(initialValue: existing?.name ?? prefill?.name ?? "")
        _host = State(initialValue: existing?.host ?? prefill?.host ?? "")
        _port = State(initialValue: String(existing?.port ?? prefill?.port ?? 8765))
        _token = State(initialValue: existing?.token ?? "")
        _fingerprint = State(initialValue: existing?.fingerprint ?? "")
    }

    private var trimmedHost: String { host.trimmingCharacters(in: .whitespaces) }
    private var portValue: Int? {
        guard let p = Int(port.trimmingCharacters(in: .whitespaces)), (1...65535).contains(p) else { return nil }
        return p
    }
    /// 把指纹规整成纯十六进制小写(允许粘贴时带空格/冒号)。SHA-256 = 64 位十六进制。
    private var normalizedFP: String { fingerprint.lowercased().filter(\.isHexDigit) }
    private var fpValid: Bool { normalizedFP.isEmpty || normalizedFP.count == 64 }
    private var canSave: Bool { !trimmedHost.isEmpty && portValue != nil && fpValid }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(onBack: { dismiss() }, brandCenter: true)
                .padding(.horizontal, 20)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(existing == nil ? "添加电脑" : "编辑电脑")
                        .font(.system(size: 28, weight: .semibold)).foregroundStyle(theme.textPrimary)
                        .padding(.top, 4)

                    SoftPanel(padding: 0) {
                        VStack(spacing: 0) {
                            fieldRow(String(localized: "电脑名称"), text: $name, placeholder: String(localized: "例如 办公台式机"), id: "field.name")
                            RowDivider(inset: 16)
                            fieldRow(String(localized: "IP 地址"), text: $host, placeholder: String(localized: "例如 192.168.1.20"), id: "field.host", keyboard: .numbersAndPunctuation)
                            RowDivider(inset: 16)
                            fieldRow(String(localized: "端口"), text: $port, placeholder: "8765", id: "field.port", keyboard: .numberPad)
                            RowDivider(inset: 16)
                            fieldRow(String(localized: "配对令牌 (可选)"), text: $token, placeholder: String(localized: "例如 abcd-efgh-1234"))
                        }
                    }

                    Button { showScan = true } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "qrcode.viewfinder")
                            Text("扫码填入地址 / 令牌").font(.system(size: 16, weight: .medium))
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.textTertiary)
                        }
                        .foregroundStyle(theme.accent)
                        .padding(.horizontal, 16).frame(height: 52)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.surfaceMuted))
                    }
                    .buttonStyle(.plain)

                    // 证书指纹 (可选): 填了就从第一次连接起严格校验电脑身份, 堵住手填首连的 TOFU 窗口 (审计 M-3)。
                    SoftPanel(padding: 0) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("证书指纹 (可选, 更安全)").font(.system(size: 15)).foregroundStyle(theme.textSecondary)
                                Spacer()
                                if !normalizedFP.isEmpty {
                                    Image(systemName: fpValid ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                                        .font(.system(size: 14)).foregroundStyle(fpValid ? theme.success : theme.warning)
                                }
                            }
                            TextField("粘贴电脑端的 64 位十六进制指纹", text: $fingerprint, axis: .vertical)
                                .font(.system(size: 14, design: .monospaced)).foregroundStyle(theme.textPrimary)
                                .autocorrectionDisabled().textInputAutocapitalization(.never)
                                .lineLimit(1...3)
                                .modifier(OptIdentifier(id: "field.fingerprint"))
                            if !normalizedFP.isEmpty && !fpValid {
                                Text("指纹应为 64 位十六进制 (当前 \(normalizedFP.count) 位)。")
                                    .font(.system(size: 12)).foregroundStyle(theme.warning)
                            }
                        }
                        .padding(.horizontal, 16).padding(.vertical, 14)
                    }
                    Text("填了指纹 = 从第一次连接就严格校验电脑身份(最安全)。留空则首连「信任并记住」对方证书, 之后才严格校验。指纹可在电脑端用 --show-pairing-code 看到, 或直接扫码自动带上。")
                        .font(.system(size: 12)).foregroundStyle(theme.textTertiary)
                        .padding(.horizontal, 4)

                    HStack(alignment: .top, spacing: 12) {
                        IconChip(icon: "questionmark", tint: theme.textSecondary, size: 36)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("如何获取连接信息?").font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.textPrimary)
                            Text("在电脑端打开 Sidekey, 点「添加设备」获取 IP、端口和令牌; 服务端用 --no-auth 时令牌留空即可。")
                                .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: theme.radiusCard, style: .continuous).fill(theme.surfaceMuted))

                    if existing != nil {
                        Button(role: .destructive) {
                            if let e = existing { store.deleteComputer(id: e.id); onDeleted() }
                            dismiss()
                        } label: {
                            Text("删除这台电脑").font(.system(size: 15, weight: .medium)).foregroundStyle(theme.danger)
                                .frame(maxWidth: .infinity).frame(height: 44)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }

            CoralButton(title: String(localized: "保存并连接"), enabled: canSave) { save() }
                .accessibilityIdentifier("保存")
                .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 16)
        }
        .background(theme.bgGradient.ignoresSafeArea())
        .sheet(isPresented: $showScan) {
            PairingView(client: client) { payload in
                if let h = payload.hosts.first { host = h }
                port = String(payload.port)
                token = payload.token
                fingerprint = payload.fp ?? ""
                if name.trimmingCharacters(in: .whitespaces).isEmpty {
                    name = payload.hosts.first ?? name
                }
            }
        }
    }

    private func fieldRow(_ label: String, text: Binding<String>, placeholder: String,
                          id: String? = nil, keyboard: UIKeyboardType = .default) -> some View {
        HStack(spacing: 12) {
            Text(label).font(.system(size: 15)).foregroundStyle(theme.textSecondary)
            Spacer(minLength: 8)
            TextField(placeholder, text: text)
                .font(.system(size: 16))
                .foregroundStyle(theme.textPrimary)
                .multilineTextAlignment(.trailing)
                .keyboardType(keyboard)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .modifier(OptIdentifier(id: id))
        }
        .padding(.horizontal, 16)
        .frame(height: 58)
    }

    private func save() {
        guard !trimmedHost.isEmpty, let p = portValue else { return }
        let nm = name.trimmingCharacters(in: .whitespaces)
        if let existing {
            store.renameComputer(id: existing.id, to: nm.isEmpty ? existing.name : nm)
            store.updateComputerConnection(id: existing.id, host: trimmedHost, port: p, token: token, fingerprint: normalizedFP)
            onSaved(existing.id)
        } else {
            let c = Computer.make(name: nm.isEmpty ? trimmedHost : nm, host: trimmedHost, port: p, token: token, fingerprint: normalizedFP)
            store.addComputer(c)
            onSaved(c.id)
        }
        dismiss()
    }
}
