#if DEBUG
import SwiftUI

/// M0 测量页里用到 iOS 27.1 新 API 的部分, 全部隔离在这个文件。
/// - 用 iOS 27.1 之前的 SDK(例如 Xcode 26.5)编译时, 整段跳过, `compiled == false`, 测量页照常能用(只是没有铰链和保留区)。
/// - 判断依据是 SwiftUI 模块版本: iOS 26.5 SDK 是 7.5.3, iOS 27.1 SDK(Xcode 27.1, 27A9275) 实测是 8.0.85.29。
///   如果装好 Xcode 27.1 后测量页仍显示「Duo API 已编译：否」, 先看实际版本号再调这里的门槛。
/// - API 名称和签名取自第三方示例(iPhone-Duo-by-Examples), 若与正式 SDK 不符, 只需改本文件。
enum DuoProbeAPI {
    #if canImport(SwiftUI, _version: 8.0.85)
    static let compiled = true

    static func regions(_ proxy: GeometryProxy) -> [DuoProbeRegion] {
        guard #available(iOS 27.1, *) else { return [] }
        let division = proxy.reservedRegions(kind: .division, options: .includeInactive)
            .map { DuoProbeRegion(kind: "division", frame: $0.frame, margins: String(describing: $0.margins), isActive: $0.isActive) }
        let occlusion = proxy.reservedRegions(kind: .occlusion, options: .includeInactive)
            .map { DuoProbeRegion(kind: "occlusion", frame: $0.frame, margins: String(describing: $0.margins), isActive: $0.isActive) }
        return division + occlusion
    }
    #else
    static let compiled = false

    static func regions(_ proxy: GeometryProxy) -> [DuoProbeRegion] { [] }
    #endif
}

extension View {
    /// 铰链状态和角度写进 binding; 没有铰链的设备 / 旧 SDK 下保持 nil。
    func duoProbeHinge(_ hinge: Binding<DuoProbeHinge?>) -> some View {
        #if canImport(SwiftUI, _version: 8.0.85)
        if #available(iOS 27.1, *) {
            return AnyView(modifier(DuoProbeHingeModifier(hinge: hinge)))
        }
        #endif
        return AnyView(self)
    }
}

#if canImport(SwiftUI, _version: 8.0.85)
@available(iOS 27.1, *)
private struct DuoProbeHingeModifier: ViewModifier {
    @Binding var hinge: DuoProbeHinge?

    func body(content: Content) -> some View {
        content.onHingeChange { _, newContext in
            hinge = newContext.hinge.map { DuoProbeHinge(status: String(describing: $0.status), angle: $0.angle.degrees) }
        }
    }
}
#endif
#endif
