import UIKit
import SwiftUI

/// 窗口所在的屏幕类型 (§3.1 判屏规则)。决定用原键位还是大屏键位。
enum ScreenKind: Equatable {
    case phone      // 手机屏 (Duo 外屏、普通 iPhone, 以及一切判断不了的情况) → 原键位
    case inner      // Duo 内屏 → 大屏键位
}

/// 判屏的输入: 屏幕尺寸 + 显示配置。nil = 读不到, 按手机屏处理。
/// 采集层 (`ScreenProbe.current`) 负责读取, 纯函数 `ScreenContext.classify` 负责判断, 便于单测。
struct ScreenProbe: Equatable {
    var osSupportsDuoAPI: Bool          // iOS ≥ 27.1
    var boundsWidth: Double?            // windowScene.screen.bounds, 点
    var boundsHeight: Double?
    var modelIdentifier: String?        // 如 "iPhone19,4"
    var isDefaultDisplayZoom: Bool?     // scale == nativeScale
    var isMirroredOrExternal: Bool?     // 镜像 / 外接显示器
}

enum ScreenContext {
    /// 内屏短边阈值 (§3.1): 内屏 669 与其他屏幕最大 466 之间取中。
    static let innerShortSideThreshold: Double = 600

    /// 已支持清单 (§3.1 第 4 条, v1.7): 只有清单里的显示配置才用短边阈值, 其余一律手机屏。
    /// 目前只有「iPhone Duo、默认显示缩放、非镜像非外接」。机型标识来自模拟器 profile (iPhone19,4);
    /// 真机的标识待真机验证后补进清单 (Q16)。
    static let supportedDuoModels: Set<String> = ["iPhone19,4"]

    static func classify(_ p: ScreenProbe) -> ScreenKind {
        guard p.osSupportsDuoAPI else { return .phone }
        guard let w = p.boundsWidth, let h = p.boundsHeight, w > 0, h > 0 else { return .phone }
        guard let model = p.modelIdentifier, supportedDuoModels.contains(model) else { return .phone }
        guard p.isDefaultDisplayZoom == true, p.isMirroredOrExternal == false else { return .phone }
        return min(w, h) >= innerShortSideThreshold ? .inner : .phone
    }
}

// MARK: - 采集层
extension ScreenProbe {
    /// 机型标识: 模拟器读环境变量, 真机读 uname。
    static var currentModelIdentifier: String? {
        if let m = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"], !m.isEmpty { return m }
        var sys = utsname()
        uname(&sys)
        let m = withUnsafePointer(to: &sys.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) { String(cString: $0) }
        }
        return m.isEmpty ? nil : m
    }

    /// 读当前窗口所在屏幕。拿不到 scene 时各项为 nil → 判成手机屏。不使用 UIScreen.main (Duo 上指代不明)。
    static func current(for scene: UIWindowScene?) -> ScreenProbe {
        var os = false
        if #available(iOS 27.1, *) { os = true }
        guard let scene else {
            return ScreenProbe(osSupportsDuoAPI: os, boundsWidth: nil, boundsHeight: nil, modelIdentifier: currentModelIdentifier,
                               isDefaultDisplayZoom: nil, isMirroredOrExternal: nil)
        }
        let screen = scene.screen
        // 注意不能用 UIScreen.screens.count > 1: iPhone Duo 本身就有内外两块屏 (M1 实测恒为 2)。
        // 外接显示器上的窗口角色不是 .windowApplication; 镜像时 screen.mirrored 非 nil。
        let external = scene.session.role != .windowApplication || screen.mirrored != nil
        return ScreenProbe(osSupportsDuoAPI: os,
                           boundsWidth: Double(screen.bounds.width), boundsHeight: Double(screen.bounds.height),
                           modelIdentifier: currentModelIdentifier,
                           isDefaultDisplayZoom: screen.scale == screen.nativeScale,
                           isMirroredOrExternal: external)
    }
}

// MARK: - 采集层: 窗口所在屏幕的判屏结果 (视图用)

/// 挂在根视图背景里, 读宿主窗口所在的屏幕并判屏; 结果变化时回调 (窗口挪到另一块屏、展开 / 合上、Split View 等)。
/// DEBUG 下 `--screen-inner` 强制按内屏处理 (模拟器的折叠 / 展开只能手动操作, 自动化验证用)。
struct ScreenKindReader: UIViewRepresentable {
    let onChange: (ScreenKind) -> Void

    func makeUIView(context: Context) -> ReaderView { ReaderView(onChange: onChange) }
    func updateUIView(_ v: ReaderView, context: Context) { v.onChange = onChange }

    final class ReaderView: UIView {
        var onChange: (ScreenKind) -> Void
        private var last: ScreenKind?
        init(onChange: @escaping (ScreenKind) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }
        required init?(coder: NSCoder) { fatalError() }
        override func didMoveToWindow() { super.didMoveToWindow(); report() }
        override func layoutSubviews() { super.layoutSubviews(); report() }

        private func report() {
            var kind = ScreenContext.classify(ScreenProbe.current(for: window?.windowScene))
            #if DEBUG
            if DebugArgs.has("--screen-inner") { kind = .inner }
            #endif
            guard kind != last else { return }
            last = kind
            let cb = onChange
            DispatchQueue.main.async { cb(kind) }          // 不在布局过程中改 SwiftUI 状态
        }
    }
}

private struct ScreenKindKey: EnvironmentKey { static let defaultValue: ScreenKind = .phone }
extension EnvironmentValues {
    /// 当前窗口所在屏幕 (根视图注入)。决定编辑器打开哪套键位 (§4.8: 内屏打开编辑大屏键位)。
    var screenKind: ScreenKind {
        get { self[ScreenKindKey.self] }
        set { self[ScreenKindKey.self] = newValue }
    }
}
