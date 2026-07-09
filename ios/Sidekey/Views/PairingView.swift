import SwiftUI
import VisionKit

/// 扫码配对 (brief B2): 272 扫描面板 + 珊瑚 L 形扫描角; 无相机时手动粘贴配对码。
struct PairingView: View {
    @ObservedObject var client: SidekeyClient
    var onPaired: ((PairingPayload) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.sidekeyTheme) private var theme

    @State private var manual = ""
    @State private var error: String?

    private var scannerAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: String(localized: "扫码配对"), onClose: { dismiss() })
                .padding(.horizontal, 20)

            ScrollView {
                VStack(spacing: 20) {
                    scanArea
                        .padding(.top, 8)

                    Text(scannerAvailable ? String(localized: "把摄像头对准电脑上显示的二维码。") : String(localized: "此设备无法用摄像头扫码, 请用下面的手动粘贴。"))
                        .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                        .multilineTextAlignment(.center)

                    HStack(spacing: 10) {
                        line; Text("或手动输入").font(.system(size: 12)).foregroundStyle(theme.textTertiary); line
                    }

                    SoftField(label: String(localized: "配对码"), text: $manual, placeholder: String(localized: "粘贴电脑终端里的配对码"))

                    if let error {
                        Text(error).font(.system(size: 13)).foregroundStyle(theme.danger)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Text("配对码只在你的本地网络内使用, 不会上传。")
                        .font(.system(size: 12)).foregroundStyle(theme.textTertiary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }

            CoralButton(title: String(localized: "继续"), enabled: !manual.isEmpty) { handle(manual) }
                .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 16)
        }
        .background(theme.bgGradient.ignoresSafeArea())
    }

    private var line: some View { Rectangle().fill(theme.hairline).frame(height: 1) }

    private var scanArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: theme.radiusPanel, style: .continuous)
                .fill(theme.surface).raisedShadow(theme)
            if scannerAvailable {
                QRScanner { handle($0) }
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(20)
            } else {
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: 72, weight: .light)).foregroundStyle(theme.textTertiary)
            }
            ScanCorners().stroke(theme.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .padding(14)
        }
        .frame(width: 272, height: 272)
    }

    private func handle(_ raw: String) {
        do {
            // 校验配对码语义(版本/地址/端口/指纹), 不合法给出具体原因, 不再存成连不上的电脑 (审计 M-2)。
            let payload = try PairingPayload.validated(raw)
            if let onPaired { onPaired(payload) } else { client.applyPairing(payload) }
            dismiss()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription
                ?? String(localized: "配对码无法识别, 请确认扫的是 Sidekey 的二维码。")
        }
    }
}

/// 四角 L 形扫描标记。
private struct ScanCorners: Shape {
    var len: CGFloat = 34
    func path(in r: CGRect) -> Path {
        var p = Path()
        let L = len
        // 左上
        p.move(to: CGPoint(x: r.minX, y: r.minY + L)); p.addLine(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.minX + L, y: r.minY))
        // 右上
        p.move(to: CGPoint(x: r.maxX - L, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY + L))
        // 右下
        p.move(to: CGPoint(x: r.maxX, y: r.maxY - L)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); p.addLine(to: CGPoint(x: r.maxX - L, y: r.maxY))
        // 左下
        p.move(to: CGPoint(x: r.minX + L, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY - L))
        return p
    }
}

/// 用 VisionKit 包一个二维码扫描器 (逻辑不变)。
struct QRScanner: UIViewControllerRepresentable {
    var onScan: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighlightingEnabled: true
        )
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {
        try? vc.startScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onScan: (String) -> Void
        private var fired = false
        init(onScan: @escaping (String) -> Void) { self.onScan = onScan }

        func dataScanner(_ scanner: DataScannerViewController,
                         didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            guard !fired else { return }
            for item in addedItems {
                if case .barcode(let bc) = item, let s = bc.payloadStringValue {
                    fired = true
                    onScan(s)
                    break
                }
            }
        }
    }
}
